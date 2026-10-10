import Foundation
import Network

/// Forwards ports on this Mac to a guest on shared (NAT) networking, for Apple-engine machines.
///
/// Apple's NAT gives each guest an address on a private network only the Mac can reach. This
/// listens on the Mac's port (on every interface, so other devices on the local network can
/// connect too) and relays each connection to the same port's counterpart inside the guest,
/// whose current address it looks up by the guest's network card.
@MainActor
final class PortForwarder {
    private let forwards: [PortForward]
    private let macAddress: String
    private var listeners: [NWListener] = []
    private let queue = DispatchQueue(label: "orbit.portforward")

    init(forwards: [PortForward], macAddress: String) {
        self.forwards = forwards
        self.macAddress = macAddress
    }

    /// Start listening. Ports that can't be opened (another app uses them) are reported.
    func start() -> [String] {
        var problems: [String] = []
        for forward in forwards {
            guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: forward.hostPort)), forward.guestPort > 0 else { continue }
            do {
                let listener = try NWListener(using: forward.isUDP ? .udp : .tcp, on: port)
                let guestPort = UInt16(clamping: forward.guestPort)
                let mac = macAddress
                let queue = queue
                listener.newConnectionHandler = { inbound in
                    Self.relay(inbound, toGuestPort: guestPort, macAddress: mac, udp: forward.isUDP, queue: queue)
                }
                listener.start(queue: queue)
                listeners.append(listener)
            } catch {
                problems.append("Port \(forward.hostPort) couldn't be opened: \(error.localizedDescription)")
            }
        }
        return problems
    }

    func stop() {
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
    }

    nonisolated private static func relay(_ inbound: NWConnection, toGuestPort port: UInt16, macAddress: String, udp: Bool, queue: DispatchQueue) {
        guard let address = DHCPLeases.address(forMAC: macAddress), let guestPort = NWEndpoint.Port(rawValue: port) else {
            // the guest hasn't asked for an address yet (still booting)
            inbound.cancel()
            return
        }
        let outbound = NWConnection(host: NWEndpoint.Host(address), port: guestPort, using: udp ? .udp : .tcp)
        let close = { inbound.cancel(); outbound.cancel() }
        for connection in [inbound, outbound] {
            connection.stateUpdateHandler = { state in
                switch state {
                case .failed, .cancelled: close()
                default: break
                }
            }
        }
        inbound.start(queue: queue)
        outbound.start(queue: queue)
        pump(from: inbound, to: outbound, udp: udp, close: close)
        pump(from: outbound, to: inbound, udp: udp, close: close)
    }

    nonisolated private static func pump(from source: NWConnection, to destination: NWConnection, udp: Bool, close: @escaping @Sendable () -> Void) {
        let forward: @Sendable (Data?, Bool, NWError?) -> Void = { data, isComplete, error in
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { error in
                    if error != nil { close() }
                })
            }
            if error != nil || (isComplete && !udp) {
                // the other side finished: pass that on, then let both close
                destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                if error != nil { close() }
                return
            }
            pump(from: source, to: destination, udp: udp, close: close)
        }
        if udp {
            source.receiveMessage { data, _, isComplete, error in forward(data, isComplete, error) }
        } else {
            source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in forward(data, isComplete, error) }
        }
    }
}

/// The addresses macOS's DHCP server gave guests on shared (NAT) networking.
enum DHCPLeases {
    /// Where macOS keeps them (a test can point elsewhere).
    nonisolated(unsafe) static var file = URL(fileURLWithPath: "/var/db/dhcpd_leases")

    /// The guest address leased to the network card with `mac`, newest lease first.
    static func address(forMAC mac: String, leases: String? = nil) -> String? {
        guard let text = leases ?? (try? String(contentsOf: file, encoding: .utf8)) else { return nil }
        let wanted = normalized(mac)
        var best: (address: String, lease: UInt64)?
        for block in text.components(separatedBy: "}") {
            var address: String?, hardware: String?, lease: UInt64 = 0
            for line in block.split(whereSeparator: \.isNewline) {
                let parts = line.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "ip_address": address = parts[1]
                case "hw_address": hardware = parts[1].split(separator: ",", maxSplits: 1).last.map(String.init)
                case "lease": lease = UInt64(parts[1].replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0
                default: break
                }
            }
            if let address, let hardware, normalized(hardware) == wanted, lease >= (best?.lease ?? 0) {
                best = (address, lease)
            }
        }
        return best?.address
    }

    /// The leases file writes octets without leading zeros ("a:49:3a"); compare in that form.
    static func normalized(_ mac: String) -> String {
        mac.lowercased().split(separator: ":").map { octet in
            let trimmed = octet.drop { $0 == "0" }
            return trimmed.isEmpty ? "0" : String(trimmed)
        }.joined(separator: ":")
    }
}
