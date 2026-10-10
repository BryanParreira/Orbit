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
        // staged beside the destination (same volume) by the download thread, so finishing is an
        // instant rename on the main thread even when the library is on another drive
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString.prefix(8)).download")
        let delegate = Delegate(staging: staging)
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
        let temp = try await downloadResuming(session: session, delegate: delegate)
        // never leave a multi-gigabyte partial download behind
        defer { try? FileManager.default.removeItem(at: temp) }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
        isFinished = true
        return destination
    }

    func cancel() {
        isCancelled = true
        session?.invalidateAndCancel()
    }

    @ObservationIgnored private var isCancelled = false

    static let maximumRetries = 5

    /// Mirrors drop long downloads now and then, and Wi-Fi blips. Pick up where the download
    /// stopped (or start over when the server can't resume) instead of failing a 5 GB download at 90%.
    private func downloadResuming(session: URLSession, delegate: Delegate) async throws -> URL {
        var resumeData: Data?
        while true {
            // a cancelled session can't make new tasks (creating one raises an exception)
            guard !isCancelled else { throw URLError(.cancelled) }
            do {
                return try await withCheckedThrowingContinuation { continuation in
                    delegate.onFinish = { result in continuation.resume(with: result) }
                    let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: source)
                    task.resume()
                }
            } catch let error as URLError where Self.isTransient(error) && retries < Self.maximumRetries {
                retries += 1
                resumeData = error.downloadTaskResumeData
                if resumeData == nil { receivedBytes = 0 }
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

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        var onProgress: ((Int64, Int64) -> Void)?
        var onFinish: ((Result<URL, Error>) -> Void)?
        let staging: URL

        init(staging: URL) {
            self.staging = staging
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                onFinish?(.failure(URLError(.badServerResponse)))
                onFinish = nil
                return
            }
            // the system deletes `location` when this returns; move it onto the destination volume now,
            // off the main thread (a copy across drives can take a while for multi-gigabyte images)
            do {
                try? FileManager.default.removeItem(at: staging)
                try FileManager.default.moveItem(at: location, to: staging)
                onFinish?(.success(staging))
            } catch {
                try? FileManager.default.removeItem(at: staging)
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
