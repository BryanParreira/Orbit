import Foundation
import Observation

/// A cancellable download with live progress and throughput for the UI.
///
/// Bytes are written straight into a hidden file beside `destination` as they arrive: nothing
/// passes through the system's temporary folder, so a 9 GB image needs no room on the Mac's own
/// disk when the machine lives on another drive, and finishing is an instant rename instead of
/// a long copy that looks like a stalled download. A dropped connection resumes from the bytes
/// already on disk.
@Observable
@MainActor
final class DownloadTask {
    let source: URL
    let destination: URL
    private(set) var receivedBytes: Int64 = 0
    private(set) var expectedBytes: Int64 = 0
    private(set) var bytesPerSecond: Double = 0
    private(set) var isFinished = false
    /// Times the connection dropped and the download picked up where it stopped.
    private(set) var retries = 0
    /// Waiting to retry after the connection dropped.
    private(set) var isReconnecting = false

    var fraction: Double {
        expectedBytes > 0 ? Double(receivedBytes) / Double(expectedBytes) : 0
    }

    var etaSeconds: Double? {
        guard bytesPerSecond > 0, expectedBytes > 0 else { return nil }
        return Double(expectedBytes - receivedBytes) / bytesPerSecond
    }

    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var isCancelled = false

    init(source: URL, destination: URL) {
        self.source = source
        self.destination = destination
    }

    /// Download unless a complete file already sits at `destination`.
    func run() async throws -> URL {
        if FileManager.default.fileExists(atPath: destination.path) {
            isFinished = true
            return destination
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString.prefix(8)).download")
        let file = try StagingFile(url: staging)
        // never leave a multi-gigabyte partial download behind
        var finished = false
        defer {
            file.close()
            if !finished { try? FileManager.default.removeItem(at: staging) }
        }

        let delegate = Delegate(file: file)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        self.session = session
        defer { session.finishTasksAndInvalidate() }

        var lastSample = (date: Date(), bytes: Int64(0))
        delegate.onProgress = { [weak self] received, expected in
            Task { @MainActor in
                guard let self else { return }
                self.receivedBytes = received
                self.expectedBytes = expected
                let now = Date()
                let elapsed = now.timeIntervalSince(lastSample.date)
                if elapsed >= 0.5 {
                    let instant = Double(max(0, received - lastSample.bytes)) / elapsed
                    self.bytesPerSecond = self.bytesPerSecond == 0 ? instant : self.bytesPerSecond * 0.7 + instant * 0.3
                    lastSample = (now, received)
                }
            }
        }
        try await downloadResuming(session: session, delegate: delegate, file: file)
        file.close()
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staging, to: destination)
        finished = true
        isFinished = true
        return destination
    }

    func cancel() {
        isCancelled = true
        session?.invalidateAndCancel()
    }

    static let maximumRetries = 5

    /// Mirrors drop long downloads now and then, and Wi-Fi blips. Ask for the rest of the file
    /// (or start over when the server can't resume) instead of failing a 9 GB download at 90%.
    private func downloadResuming(session: URLSession, delegate: Delegate, file: StagingFile) async throws {
        while true {
            // a cancelled session can't make new tasks (creating one raises an exception)
            guard !isCancelled else { throw URLError(.cancelled) }
            var request = URLRequest(url: source)
            let offset = file.size
            if offset > 0 {
                request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            }
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    delegate.onFinish = { result in continuation.resume(with: result) }
                    session.dataTask(with: request).resume()
                }
                return
            } catch let error as URLError where Self.isTransient(error) && retries < Self.maximumRetries {
                retries += 1
                bytesPerSecond = 0
                // 4, 8, 16, 30, 30 seconds: long enough for Wi-Fi to come back
                isReconnecting = true
                defer { isReconnecting = false }
                try await Task.sleep(for: .seconds(min(30, 2 << retries)))
            }
        }
    }

    nonisolated static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost:
            true
        default:
            false
        }
    }

    /// The partial file on the destination's drive. Used only from the session's serial queue
    /// (and by `run` before and after it).
    private final class StagingFile: @unchecked Sendable {
        let url: URL
        private var handle: FileHandle?
        private(set) var size: Int64 = 0

        init(url: URL) throws {
            self.url = url
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
            }
            handle = try FileHandle(forWritingTo: url)
        }

        func write(_ data: Data) throws {
            try handle?.write(contentsOf: data)
            size += Int64(data.count)
        }

        /// The server sent the whole file again: drop what's there.
        func restart() throws {
            try handle?.truncate(atOffset: 0)
            size = 0
        }

        func close() {
            try? handle?.close()
            handle = nil
        }
    }

    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        var onProgress: ((Int64, Int64) -> Void)?
        var onFinish: ((Result<Void, Error>) -> Void)?
        private let file: StagingFile
        private var expected: Int64 = 0
        private var writeError: Error?
        private var lastReport = Date.distantPast

        init(file: StagingFile) {
            self.file = file
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            writeError = nil
            guard let http = response as? HTTPURLResponse else { completionHandler(.allow); return }
            switch http.statusCode {
            case 206:
                // the rest of the file, after what's on disk
                expected = file.size + max(0, response.expectedContentLength)
            case 200..<300:
                // the whole file: from the start, even if a resume was asked for
                do { try file.restart() } catch { writeError = error; completionHandler(.cancel); return }
                expected = max(0, response.expectedContentLength)
            default:
                writeError = URLError(http.statusCode == 404 ? .fileDoesNotExist : .badServerResponse)
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            do {
                try file.write(data)
            } catch {
                writeError = error
                dataTask.cancel()
                return
            }
            let now = Date()
            if now.timeIntervalSince(lastReport) >= 0.1 {
                lastReport = now
                onProgress?(file.size, max(expected, file.size))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            onProgress?(file.size, max(expected, file.size))
            if let writeError {
                onFinish?(.failure(writeError))
            } else if let error {
                onFinish?(.failure(error))
            } else if expected > 0 && file.size < expected {
                // the server closed early without an error: treat it as a dropped connection
                onFinish?(.failure(URLError(.networkConnectionLost)))
            } else {
                onFinish?(.success(()))
            }
            onFinish = nil
        }
    }
}

extension Int64 {
    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

extension Double {
    var formattedDuration: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = self > 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: self) ?? ""
    }
}
