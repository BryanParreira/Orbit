import Foundation
import Observation

/// Installs QEMU through Homebrew without leaving Orbit.
@Observable
@MainActor
final class QEMUInstaller {
    static let shared = QEMUInstaller()

    private(set) var isRunning = false
    private(set) var lastLine = ""
    private(set) var failed = false

    var brewURL: URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func install() {
        guard !isRunning, let brew = brewURL else { return }
        isRunning = true
        failed = false
        lastLine = "Starting Homebrew…"
        let process = Process()
        process.executableURL = brew
        process.arguments = ["install", "qemu"]
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let line = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            Task { @MainActor in if !line.isEmpty { self?.lastLine = line } }
        }
        process.terminationHandler = { [weak self] process in
            pipe.fileHandleForReading.readabilityHandler = nil
            let ok = process.terminationStatus == 0
            Task { @MainActor in
                self?.isRunning = false
                self?.failed = !ok
                self?.lastLine = ok ? "QEMU installed." : "Homebrew failed. Try in Terminal: brew install qemu"
            }
        }
        do {
            try process.run()
        } catch {
            isRunning = false
            failed = true
            lastLine = error.localizedDescription
        }
    }
}
