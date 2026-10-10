import Foundation
import Network
import Testing
@testable import Orbit

/// Downloads stream to the destination, resume after a dropped connection, and never leave
/// partial files behind. A small HTTP server on 127.0.0.1 plays the mirror.
@Suite(.serialized)
@MainActor
final class DownloaderTests {
    private var folders: [URL] = []

    deinit {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-dl-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    /// A mirror serving `body`. `dropFirstAt` closes the first connection after that many bytes;
    /// `honorsRange` false answers every request with the whole file.
    private final class Mirror: @unchecked Sendable {
        let body: Data
        let listener: NWListener
        var port: UInt16 { listener.port?.rawValue ?? 0 }
        private let dropFirstAt: Int?
        private let honorsRange: Bool
        private let missing: Bool
        private let lock = NSLock()
        private var requests: [String] = []
        var rangeHeaders: [String] { lock.lock(); defer { lock.unlock() }; return requests }

        init(size: Int, dropFirstAt: Int? = nil, honorsRange: Bool = true, missing: Bool = false) throws {
            body = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
            self.dropFirstAt = dropFirstAt
            self.honorsRange = honorsRange
            self.missing = missing
            listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [unowned self] connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, _ in
                    self.answer(String(decoding: data ?? Data(), as: UTF8.self), on: connection)
                }
            }
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            listener.start(queue: .global())
            _ = ready.wait(timeout: .now() + 5)
        }

        private func answer(_ request: String, on connection: NWConnection) {
            let range = request.split(separator: "\r\n").first { $0.lowercased().hasPrefix("range:") }
                .flatMap { $0.split(separator: "=").last }.flatMap { Int($0.dropLast()) }
            lock.lock(); requests.append(range.map { "bytes=\($0)-" } ?? "none"); let first = requests.count == 1; lock.unlock()
            if missing {
                connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let start = honorsRange ? (range ?? 0) : 0
            let part = body[start...]
            var head = start > 0 ? "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(start)-\(body.count - 1)/\(body.count)\r\n" : "HTTP/1.1 200 OK\r\n"
            head += "Content-Length: \(part.count)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
            var payload = Data(head.utf8) + part
            if first, let drop = dropFirstAt {
                payload = Data(head.utf8) + body.prefix(drop)
            }
            connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
        }

        deinit { listener.cancel() }
    }

    private func leftovers(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".download") }
    }

    @Test func streamsToTheDestination() async throws {
        let mirror = try Mirror(size: 3 << 20)
        let folder = try makeFolder()
        let task = DownloadTask(source: URL(string: "http://127.0.0.1:\(mirror.port)/image.iso")!, destination: folder.appendingPathComponent("image.iso"))
        let file = try await task.run()
        #expect(try Data(contentsOf: file) == mirror.body)
        #expect(try leftovers(in: folder).isEmpty)
        #expect(task.fraction == 1)
    }

    @Test func resumesWhereTheConnectionDropped() async throws {
        let mirror = try Mirror(size: 4 << 20, dropFirstAt: 1 << 20)
        let folder = try makeFolder()
        let task = DownloadTask(source: URL(string: "http://127.0.0.1:\(mirror.port)/image.iso")!, destination: folder.appendingPathComponent("image.iso"))
        let file = try await task.run()
        #expect(try Data(contentsOf: file) == mirror.body, "complete and in order")
        #expect(task.retries == 1)
        #expect(mirror.rangeHeaders.count == 2)
        #expect(mirror.rangeHeaders.last?.hasPrefix("bytes=") == true && mirror.rangeHeaders.last != "bytes=0-", "asked only for the rest")
        #expect(try leftovers(in: folder).isEmpty)
    }

    @Test func startsOverWhenTheServerCantResume() async throws {
        let mirror = try Mirror(size: 2 << 20, dropFirstAt: 512 << 10, honorsRange: false)
        let folder = try makeFolder()
        let task = DownloadTask(source: URL(string: "http://127.0.0.1:\(mirror.port)/image.iso")!, destination: folder.appendingPathComponent("image.iso"))
        let file = try await task.run()
        #expect(try Data(contentsOf: file) == mirror.body, "the partial bytes were discarded, not duplicated")
        #expect(try leftovers(in: folder).isEmpty)
    }

    @Test func failsCleanlyWhenTheFileIsMissing() async throws {
        let mirror = try Mirror(size: 1024, missing: true)
        let folder = try makeFolder()
        let task = DownloadTask(source: URL(string: "http://127.0.0.1:\(mirror.port)/gone.iso")!, destination: folder.appendingPathComponent("gone.iso"))
        await #expect(throws: (any Error).self) { try await task.run() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, "no partial file, no destination")
    }
}
