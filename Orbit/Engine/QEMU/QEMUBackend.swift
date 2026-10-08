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
        do {
            // sun_path is limited to 104 bytes, so sockets live in a short temp directory
            let sockets = URL(fileURLWithPath: "/tmp/orbit-\(config.id.uuidString.prefix(8))")
            try? FileManager.default.removeItem(at: sockets)
            try FileManager.default.createDirectory(at: sockets, withIntermediateDirectories: true)
            socketDirectory = sockets
            let qmpPath = sockets.appendingPathComponent("qmp").path

            var builder = QEMUArgumentBuilder(config: config, bundle: bundle, qmpSocket: qmpPath, dataDirectory: dataDirectory)
            try prepareFirmware(builder)
            if options.contains(.disposable) {
                let overlay = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-disposable-\(UUID().uuidString)")
                var files = bundle.stateFiles(for: config)
                files.append(builder.efiVariablesURL)
                try FileCloner.clone(files.filter { FileManager.default.fileExists(atPath: $0.path) }, into: overlay)
                overlayDirectory = overlay
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
            process.standardOutput = log
            process.standardError = log
            process.terminationHandler = { [weak self] process in
                let status = process.terminationStatus
                Task { @MainActor in self?.processDidExit(status: status) }
            }
            try process.run()
            self.process = process

            let qmp = QMPClient(path: qmpPath)
            qmp.onEvent = { [weak self] event in
                Task { @MainActor in self?.handle(event: event) }
            }
            try await qmp.connect()
            self.qmp = qmp
            state = .running
        } catch {
            process?.terminate()
            cleanUp()
            state = .stopped
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
        if let qmp {
            _ = try? await qmp.execute("quit")
        }
        try await Task.sleep(for: .milliseconds(500))
        if process.isRunning {
            process.terminate()
        }
    }

    func pause() async throws {
        guard let qmp, state == .running else { return }
        state = .pausing
        try await qmp.execute("stop")
        state = .paused
    }

    func resume() async throws {
        guard let qmp, state == .paused else { return }
        state = .resuming
        try await qmp.execute("cont")
        state = .running
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
        let failed = status != 0 && !isStopping && state == .running
        cleanUp()
        state = .stopped
        if failed {
            let log = (try? String(contentsOf: bundle.logURL, encoding: .utf8))?.split(separator: "\n").suffix(3).joined(separator: "\n") ?? ""
            onStateChange?(.stopped, VMError.invalidConfiguration("QEMU exited with status \(status).\n\(log)"))
        }
    }

    private func cleanUp() {
        qmp?.close()
        qmp = nil
        process = nil
        tpmProcess?.terminate()
        tpmProcess = nil
        if let overlayDirectory { try? FileManager.default.removeItem(at: overlayDirectory) }
        overlayDirectory = nil
        if let socketDirectory { try? FileManager.default.removeItem(at: socketDirectory) }
        socketDirectory = nil
    }
}
