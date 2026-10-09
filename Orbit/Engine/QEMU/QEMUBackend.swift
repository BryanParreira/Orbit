import AppKit

/// Runs a guest in a QEMU subprocess controlled over QMP.
///
/// Apple Silicon guests use HVF (Hypervisor.framework) for near-native speed; other
/// architectures fall back to multi-threaded TCG emulation.
@MainActor
final class QEMUBackend: VMBackend {
    private let bundle: VMBundle
    private var config: VMConfiguration

    private var process: Process?
    private var logHandle: FileHandle?
    private var tpmProcess: Process?
    private var qmp: QMPClient?
    private var overlayDirectory: URL?
    private var socketDirectory: URL?
    private var isStopping = false

    private(set) var state: VMState = .stopped {
        didSet { if oldValue != state { onStateChange?(state, nil) } }
    }
    var onStateChange: ((VMState, Error?) -> Void)?
    var supportsSuspend: Bool { false }
    var hasEmbeddedDisplay: Bool { false }

    init(config: VMConfiguration, bundle: VMBundle) {
        self.config = config
        self.bundle = bundle
    }

    func update(config: VMConfiguration) {
        self.config = config
    }

    func start(options: StartOptions) async throws {
        guard state == .stopped else { return }
        guard let binary = HostInfo.qemuBinary(for: config.architecture), let dataDirectory = HostInfo.qemuDataDirectory() else {
            throw VMError.qemuNotInstalled
        }
        state = .starting
        isStopping = false
        var launched: Process?
        do {
            // control sockets live in this user's private temp folder, readable by nobody else
            // (sun_path is limited to 104 bytes, so the name stays short)
            let sockets = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-\(config.id.uuidString.prefix(8))", isDirectory: true)
            try? FileManager.default.removeItem(at: sockets)
            try FileManager.default.createDirectory(at: sockets, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard sockets.path.utf8.count < 90 else {
                throw VMError.invalidConfiguration("The temporary folder path is too long for QEMU's control socket.")
            }
            socketDirectory = sockets
            let qmpPath = sockets.appendingPathComponent("qmp").path

            var builder = QEMUArgumentBuilder(config: config, bundle: bundle, qmpSocket: qmpPath, dataDirectory: dataDirectory)
            try prepareFirmware(builder)
            if options.contains(.disposable) {
                let overlay = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-disposable-\(UUID().uuidString)")
                var files = bundle.stateFiles(for: config)
                files.append(builder.efiVariablesURL)
                overlayDirectory = overlay
                try await FileCloner.cloneInBackground(files.filter { FileManager.default.fileExists(atPath: $0.path) }, into: overlay)
                builder.overlayDirectory = overlay
            }
            if config.qemu.tpm {
                builder.tpmSocket = try startTPM(socketDirectory: sockets)
            }

            let process = Process()
            process.executableURL = binary
            process.arguments = builder.build()
            FileManager.default.createFile(atPath: bundle.logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: bundle.logURL)
            logHandle = log
            process.standardOutput = log
            process.standardError = log
            process.terminationHandler = { [weak self] process in
                let status = process.terminationStatus
                Task { @MainActor in self?.processDidExit(status: status) }
            }
            try process.run()
            launched = process
            self.process = process

            let qmp = QMPClient(path: qmpPath)
            qmp.onEvent = { [weak self] event in
                Task { @MainActor in self?.handle(event: event) }
            }
            // give up as soon as QEMU exits (bad arguments, locked disk…) instead of waiting out the timeout
            try await qmp.connect(while: { process.isRunning })
            self.qmp = qmp
            state = .running
        } catch {
            let exited = launched.map { !$0.isRunning } ?? false
            launched?.terminate()
            let reason = exited ? qemuErrorSummary() : nil
            cleanUp()
            state = .stopped
            if let reason {
                throw VMError.invalidConfiguration("QEMU couldn't start this machine:\n\(reason)")
            }
            throw error
        }
    }

    func requestStop() async throws {
        guard let qmp, state == .running || state == .paused else { return }
        if state == .paused { try await resume() }
        try await qmp.execute("system_powerdown")
    }

    func forceStop() async throws {
        guard let process else { return }
        isStopping = true
        state = .stopping
        // don't await: a hung QEMU never answers
        if let qmp {
            Task { _ = try? await qmp.execute("quit") }
        }
        for step in 0..<30 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
            if step == 15 { process.terminate() }
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    func pause() async throws {
        guard let qmp, state == .running else { return }
        state = .pausing
        do {
            try await qmp.execute("stop")
            state = .paused
        } catch {
            state = .running
            throw error
        }
    }

    func resume() async throws {
        guard let qmp, state == .paused else { return }
        state = .resuming
        do {
            try await qmp.execute("cont")
            state = .running
        } catch {
            state = .paused
            throw error
        }
    }

    func restart() async throws {
        guard let qmp else { throw VMError.notRunning }
        try await qmp.execute("system_reset")
    }

    func suspend() async throws {
        throw VMError.unsupported("Suspending to disk")
    }

    /// QEMU draws in its own Cocoa window; bring that process forward.
    func bringToFront() {
        guard let pid = process?.processIdentifier else { return }
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    // MARK: - Private

    private func prepareFirmware(_ builder: QEMUArgumentBuilder) throws {
        guard FileManager.default.fileExists(atPath: builder.firmwareCodeURL().path) else {
            throw VMError.missingFile(builder.firmwareCodeURL().lastPathComponent)
        }
        if !FileManager.default.fileExists(atPath: builder.efiVariablesURL.path) {
            let template = builder.firmwareVarsTemplateURL()
            if FileManager.default.fileExists(atPath: template.path) {
                try FileManager.default.copyItem(at: template, to: builder.efiVariablesURL)
            } else {
                // pflash unit 1 must match the code image size
                let size = (try? FileManager.default.attributesOfItem(atPath: builder.firmwareCodeURL().path)[.size] as? Int64) ?? 67_108_864
                try DiskImageService.createSparseRaw(at: builder.efiVariablesURL, bytes: size)
            }
        }
    }

    private func startTPM(socketDirectory: URL) throws -> String {
        let swtpm = HostInfo.qemuSearchPaths.map { URL(fileURLWithPath: $0).appendingPathComponent("swtpm") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard let swtpm else {
            throw VMError.invalidConfiguration("TPM needs swtpm. Install it with: brew install swtpm")
        }
        let stateDir = bundle.url.appendingPathComponent("TPM")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let socket = socketDirectory.appendingPathComponent("tpm").path
        let process = Process()
        process.executableURL = swtpm
        process.arguments = ["socket", "--tpm2", "--tpmstate", "dir=\(stateDir.path)", "--ctrl", "type=unixio,path=\(socket)", "--terminate"]
        try process.run()
        tpmProcess = process
        // swtpm creates the socket almost immediately
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: socket) {
            usleep(20_000)
        }
        return socket
    }

    private func handle(event: String) {
        switch event {
        case "STOP" where state == .running: state = .paused
        case "RESUME" where state == .paused: state = .running
        case "SHUTDOWN": state = .stopping
        default: break
        }
    }

    private func processDidExit(status: Int32) {
        // a failed start reports its own error; after cleanup there is nothing left to do
        guard process != nil, state != .starting else { return }
        let failed = status != 0 && !isStopping && state == .running
        let reason = failed ? qemuErrorSummary() : nil
        cleanUp()
        state = .stopped
        if failed {
            onStateChange?(.stopped, VMError.invalidConfiguration("QEMU stopped unexpectedly (status \(status)).\n\(reason ?? "")"))
        }
    }

    /// The last lines QEMU printed, which name the actual problem.
    private func qemuErrorSummary() -> String? {
        try? logHandle?.synchronize()
        guard let text = try? String(contentsOf: bundle.logURL, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").map { $0.replacingOccurrences(of: "qemu-system-aarch64: ", with: "").replacingOccurrences(of: "qemu-system-x86_64: ", with: "") }
        let summary = lines.suffix(3).joined(separator: "\n")
        return summary.isEmpty ? nil : summary
    }

    private func cleanUp() {
        qmp?.close()
        qmp = nil
        process = nil
        try? logHandle?.close()
        logHandle = nil
        tpmProcess?.terminate()
        tpmProcess = nil
        if let overlayDirectory { try? FileManager.default.removeItem(at: overlayDirectory) }
        overlayDirectory = nil
        if let socketDirectory { try? FileManager.default.removeItem(at: socketDirectory) }
        socketDirectory = nil
    }
}
