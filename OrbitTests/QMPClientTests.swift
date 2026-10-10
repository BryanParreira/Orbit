import Foundation
import Network
import Testing
@testable import Orbit

/// QMP replies are matched by id, and a command QEMU never answers times out instead of hanging.
@Suite(.serialized)
struct QMPClientTests {
    /// A fake QEMU: greets, then answers commands as `reply` decides (nil = never answer).
    private final class FakeQEMU: @unchecked Sendable {
        let path: String
        private let listener: Int32
        private var held: [[String: Any]] = []

        init(reply: @escaping @Sendable (_ command: String, _ id: Any) -> [String: Any]?) throws {
            path = FileManager.default.temporaryDirectory.appendingPathComponent("qmp-\(UUID().uuidString.prefix(6))").path
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                raw.copyBytes(from: path.utf8)
                raw[path.utf8.count] = 0
            }
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, listen(listener, 1) == 0 else { throw POSIXError(.EADDRINUSE) }
            let listener = listener
            Thread.detachNewThread {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                func send(_ object: [String: Any]) {
                    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
                    let line = data + Data("\n".utf8)
                    _ = line.withUnsafeBytes { write(client, $0.baseAddress, line.count) }
                }
                send(["QMP": ["version": [:]]])
                var buffer = Data()
                var chunk = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(client, &chunk, chunk.count)
                    if n <= 0 { break }
                    buffer.append(contentsOf: chunk[0..<n])
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = buffer[buffer.startIndex..<newline]
                        buffer.removeSubrange(buffer.startIndex...newline)
                        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                              let command = message["execute"] as? String else { continue }
                        // an event in between, as QEMU sends them at any time
                        send(["event": "RTC_CHANGE", "data": [:]])
                        if let answer = reply(command, message["id"] ?? NSNull()) { send(answer) }
                    }
                }
                close(client)
            }
        }

        deinit {
            close(listener)
            unlink(path)
        }
    }

    @Test func repliesAreMatchedByID() async throws {
        let qemu = try FakeQEMU { command, id in
            switch command {
            case "qmp_capabilities": ["return": [:], "id": id]
            case "query-status": ["return": ["status": "running"], "id": id]
            case "screendump": nil // never answers
            default: ["error": ["desc": "unknown command \(command)"], "id": id]
            }
        }
        let client = QMPClient(path: qemu.path)
        try await client.connect()
        defer { client.close() }

        // a command QEMU never answers times out instead of hanging
        let started = Date()
        await #expect(throws: VMError.self) { try await client.execute("screendump", timeout: 1) }
        #expect(Date().timeIntervalSince(started) < 5)

        // and the next command still gets its own reply
        let status = try await client.execute("query-status")
        #expect(status["status"] as? String == "running")
        await #expect(throws: VMError.self) { try await client.execute("bogus") }
    }
}

/// Port forwarding finds a guest's NAT address in macOS's DHCP leases by its network card.
struct DHCPLeaseTests {
    let leases = """
    {
    \tname=kali
    \tip_address=192.168.64.6
    \thw_address=1,5e:97:1f:3c:e:7b
    \tidentifier=1,5e:97:1f:3c:e:7b
    \tlease=0x6ac91dd9
    }
    {
    \tip_address=192.168.64.3
    \thw_address=1,a:49:3a:70:9:f4
    \tidentifier=1,a:49:3a:70:9:f4
    \tlease=0x69c571be
    }
    {
    \tip_address=192.168.64.9
    \thw_address=1,a:49:3a:70:9:f4
    \tidentifier=1,a:49:3a:70:9:f4
    \tlease=0x69c571ff
    }
    """

    @Test func findsTheGuestByItsMACAddress() {
        // Orbit writes leading zeros, the leases file doesn't
        #expect(DHCPLeases.address(forMAC: "5e:97:1f:3c:0e:7b", leases: leases) == "192.168.64.6")
        // the newest lease wins when a card got a new address
        #expect(DHCPLeases.address(forMAC: "0a:49:3a:70:09:f4", leases: leases) == "192.168.64.9")
        #expect(DHCPLeases.address(forMAC: "02:00:00:00:00:01", leases: leases) == nil)
    }
}

/// The forwarder relays real connections: a local echo server stands in for the guest.
@Suite(.serialized)
@MainActor
struct PortForwarderTests {
    /// An echo server on 127.0.0.1, standing in for a service inside the guest.
    private func echoServer(udp: Bool) throws -> (listener: NWListener, port: UInt16) {
        let listener = try NWListener(using: udp ? .udp : .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            func echo() {
                let handle: @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void = { data, _, _, error in
                    if let data, !data.isEmpty { connection.send(content: data, completion: .idempotent) }
                    if error == nil { echo() }
                }
                if udp { connection.receiveMessage(completion: handle) } else { connection.receive(minimumIncompleteLength: 1, maximumLength: 65536, completion: handle) }
            }
            echo()
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
        return (listener, listener.port?.rawValue ?? 0)
    }

    private func roundTrip(port: UInt16, udp: Bool, message: String) async -> String? {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: udp ? .udp : .tcp)
        connection.start(queue: .global())
        defer { connection.cancel() }
        return await withCheckedContinuation { continuation in
            let once = OnceFlag()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if once.claim() { continuation.resume(returning: nil) } }
            connection.send(content: Data(message.utf8), completion: .contentProcessed { _ in
                let handle: @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void = { data, _, _, _ in
                    if once.claim() { continuation.resume(returning: data.map { String(decoding: $0, as: UTF8.self) }) }
                }
                if udp { connection.receiveMessage(completion: handle) } else { connection.receive(minimumIncompleteLength: 1, maximumLength: 65536, completion: handle) }
            })
        }
    }

    @Test(arguments: [false, true])
    func relaysToTheGuest(udp: Bool) async throws {
        let mac = "0a:49:3a:70:09:f4"
        let leases = FileManager.default.temporaryDirectory.appendingPathComponent("leases-\(UUID().uuidString.prefix(6))")
        try "{\n\tip_address=127.0.0.1\n\thw_address=1,a:49:3a:70:9:f4\n\tlease=0x1\n}\n".write(to: leases, atomically: true, encoding: .utf8)
        let original = DHCPLeases.file
        DHCPLeases.file = leases
        defer { DHCPLeases.file = original; try? FileManager.default.removeItem(at: leases) }

        let guest = try echoServer(udp: udp)
        defer { guest.listener.cancel() }
        let hostPort = Int.random(in: 42000...48000)
        let forwarder = PortForwarder(forwards: [PortForward(isUDP: udp, hostPort: hostPort, guestPort: Int(guest.port))], macAddress: mac)
        #expect(forwarder.start().isEmpty)
        defer { forwarder.stop() }
        try await Task.sleep(for: .milliseconds(300))

        let reply = await roundTrip(port: UInt16(hostPort), udp: udp, message: "hello guest")
        #expect(reply == "hello guest", "\(udp ? "UDP" : "TCP") relay")
    }

    @Test func refusesWhenTheGuestHasNoAddressYet() async throws {
        let original = DHCPLeases.file
        DHCPLeases.file = URL(fileURLWithPath: "/nonexistent-\(UUID())")
        defer { DHCPLeases.file = original }
        let hostPort = Int.random(in: 48001...52000)
        let forwarder = PortForwarder(forwards: [PortForward(hostPort: hostPort, guestPort: 22)], macAddress: "02:00:00:00:00:01")
        #expect(forwarder.start().isEmpty)
        defer { forwarder.stop() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await roundTrip(port: UInt16(hostPort), udp: false, message: "hi") == nil)
    }
}

/// Resumes a continuation once, whichever of two callbacks comes first.
private final class OnceFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
