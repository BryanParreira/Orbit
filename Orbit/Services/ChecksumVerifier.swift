import CryptoKit
import Foundation

/// Verifies downloads against the SHA-256 lists distributions publish next to their images.
///
/// Fails closed: an image that doesn't match is deleted, and an image whose checksum can't be
/// fetched isn't used. A verified image is remembered with a small marker file so a cached copy
/// isn't re-hashed every time a VM is created.
enum ChecksumVerifier {
    enum Failure: LocalizedError {
        case mismatch(String)
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .mismatch(let name):
                "“\(name)” didn't match its published checksum, so it was deleted. The download was damaged or altered. Try again."
            case .unavailable(let name):
                "Couldn't fetch the checksum for “\(name)”, so it can't be verified. Check your connection and try again, or choose an image you downloaded yourself."
            }
        }
    }

    static func verify(_ file: URL, against checksumURL: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let name = file.lastPathComponent
        let expected: String
        do {
            expected = try await expectedHash(for: name, from: checksumURL)
        } catch {
            throw Failure.unavailable(name)
        }
        let marker = markerURL(for: file)
        if let recorded = try? String(contentsOf: marker, encoding: .utf8), recorded == expected {
            return
        }
        let actual = try await sha256(of: file, progress: progress)
        guard actual == expected else {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: marker)
            throw Failure.mismatch(name)
        }
        try? expected.write(to: marker, atomically: true, encoding: .utf8)
    }

    /// The hash listed for `fileName`, in either "hash  name" (GNU) or "SHA256 (name) = hash" (BSD) form.
    static func expectedHash(for fileName: String, from url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        return try expectedHash(for: fileName, in: String(decoding: data, as: UTF8.self))
    }

    static func expectedHash(for fileName: String, in text: String) throws -> String {
        var allHashes: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let line = String(line)
            if let m = line.firstMatch(of: /^SHA256 \((.+)\) = ([0-9a-fA-F]{64})\s*$/) {
                allHashes.append(String(m.output.2))
                if String(m.output.1) == fileName { return String(m.output.2).lowercased() }
            } else if let m = line.firstMatch(of: /^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$/) {
                allHashes.append(String(m.output.1))
                if (String(m.output.2) as NSString).lastPathComponent == fileName { return String(m.output.1).lowercased() }
            }
        }
        // a file that lists exactly one image (openSUSE's "Current" alias) applies to it
        if allHashes.count == 1 { return allHashes[0].lowercased() }
        throw URLError(.resourceUnavailable)
    }

    /// Streams the file in 8 MB chunks off the main thread, reporting the fraction read so far.
    static func sha256(of file: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let total = max(1, (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1)
            var read = 0
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
                read += chunk.count
                progress?(min(1, Double(read) / Double(total)))
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    private static func markerURL(for file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).verified")
    }
}
