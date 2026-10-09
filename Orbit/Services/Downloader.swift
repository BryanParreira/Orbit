import Foundation
import Observation

/// A cancellable download with live progress and throughput for the UI.
@Observable
@MainActor
final class DownloadTask {
    let source: URL
    let destination: URL
    private(set) var receivedBytes: Int64 = 0
    private(set) var expectedBytes: Int64 = 0
    private(set) var bytesPerSecond: Double = 0
    private(set) var isFinished = false

    var fraction: Double {
        expectedBytes > 0 ? Double(receivedBytes) / Double(expectedBytes) : 0
    }

    var etaSeconds: Double? {
        guard bytesPerSecond > 0, expectedBytes > 0 else { return nil }
        return Double(expectedBytes - receivedBytes) / bytesPerSecond
    }

    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var delegate: Delegate?

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
        let delegate = Delegate()
        self.delegate = delegate
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
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
                    let instant = Double(received - lastSample.bytes) / elapsed
                    self.bytesPerSecond = self.bytesPerSecond == 0 ? instant : self.bytesPerSecond * 0.7 + instant * 0.3
                    lastSample = (now, received)
                }
            }
        }
        let temp: URL = try await withCheckedThrowingContinuation { continuation in
            delegate.onFinish = { result in continuation.resume(with: result) }
            session.downloadTask(with: source).resume()
        }
        // never leave a multi-gigabyte download behind in the temp folder
        defer { try? FileManager.default.removeItem(at: temp) }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
        isFinished = true
        return destination
    }

    func cancel() {
        session?.invalidateAndCancel()
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        var onProgress: ((Int64, Int64) -> Void)?
        var onFinish: ((Result<URL, Error>) -> Void)?

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                onFinish?(.failure(URLError(.badServerResponse)))
                onFinish = nil
                return
            }
            // the system deletes `location` when this returns, keep it alive
            let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.moveItem(at: location, to: keep)
                onFinish?(.success(keep))
            } catch {
                onFinish?(.failure(error))
            }
            onFinish = nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                onFinish?(.failure(error))
                onFinish = nil
            }
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
