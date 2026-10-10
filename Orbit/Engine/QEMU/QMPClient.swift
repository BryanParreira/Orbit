import Foundation

/// Minimal QEMU Machine Protocol client over a Unix socket.
final class QMPClient: @unchecked Sendable {
    private let path: String
    private var fd: Int32 = -1
    private var handle: FileHandle?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "orbit.qmp")
    /// Commands waiting for QEMU's reply, by the `id` QEMU echoes back. Matching by id (not order)
    /// means a reply that arrives after its command timed out can't be handed to the next one.
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextID = 1

    /// QMP events such as SHUTDOWN, STOP, RESUME, RESET.
    var onEvent: ((String) -> Void)?
    var onDisconnect: (() -> Void)?

    init(path: String) {
        self.path = path
    }

    /// Connect, retrying while QEMU creates the socket and `alive` stays true.
    func connect(timeout: TimeInterval = 15, while alive: () -> Bool = { true }) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if try openSocket() { break }
            if !alive() { throw VMError.notRunning }
            if Date() > deadline { throw VMError.invalidConfiguration("QEMU didn't respond in time. Check Console.log in the machine's package for details.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        self.handle = handle
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self else { return }
            self.queue.async {
                if data.isEmpty {
                    h.readabilityHandler = nil
                    self.failAll(VMError.notRunning)
                    self.onDisconnect?()
                } else {
                    self.consume(data)
                }
            }
        }
        _ = try await execute("qmp_capabilities")
    }

    /// Send a command and wait for its reply, at most `timeout` seconds: a busy or wedged QEMU
    /// must never leave a caller (shut down, pause, snapshot) waiting forever.
    @discardableResult
    func execute(_ command: String, arguments: [String: Any]? = nil, timeout: TimeInterval = 20) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let handle = self.handle else {
                    continuation.resume(throwing: VMError.notRunning)
                    return
                }
                let id = self.nextID
                self.nextID += 1
                var message: [String: Any] = ["execute": command, "id": id]
                if let arguments { message["arguments"] = arguments }
                guard let data = try? JSONSerialization.data(withJSONObject: message) else {
                    continuation.resume(throwing: VMError.invalidConfiguration("Invalid QEMU command."))
                    return
                }
                self.pending[id] = continuation
                do {
                    try handle.write(contentsOf: data + Data("\n".utf8))
                } catch {
                    self.pending[id] = nil
                    continuation.resume(throwing: error)
                    return
                }
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.pending.removeValue(forKey: id)?
                        .resume(throwing: VMError.invalidConfiguration("QEMU didn't answer “\(command)” in time."))
                }
            }
        }
    }

    func close() {
        queue.async {
            self.handle?.readabilityHandler = nil
            try? self.handle?.close()
            self.handle = nil
            self.failAll(VMError.notRunning)
        }
    }

    private func openSocket() throws -> Bool {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLength else {
            Darwin.close(s)
            throw VMError.invalidConfiguration("QMP socket path is too long.")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 {
            fd = s
            return true
        }
        Darwin.close(s)
        return false
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let event = object["event"] as? String {
                onEvent?(event)
            } else if object["QMP"] != nil {
                continue // greeting
            } else if let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
                if let error = object["error"] as? [String: Any] {
                    continuation.resume(throwing: VMError.invalidConfiguration(error["desc"] as? String ?? "QEMU command failed."))
                } else {
                    continuation.resume(returning: object["return"] as? [String: Any] ?? [:])
                }
            }
        }
    }

    private func failAll(_ error: Error) {
        let waiting = pending.values
        pending.removeAll()
        waiting.forEach { $0.resume(throwing: error) }
    }
}
