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
            // once Windows is on the disk, start from it: its own setup restarts expect that, and a
            // still-attached installer would otherwise wait at "Press any key" on every start
            builder.bootsFromInstaller = config.bootFromInstaller && !(config.guestOS == .windows && !hasBlankDisks)
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
            if config.guestOS == .windows, config.bootFromInstaller, config.installerMedia != nil, hasBlankDisks {
                answerBootPrompt()
            }
            #if DEBUG
            startRemoteControl()
            #endif
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

    /// The guest's screen, for previews in the library. QEMU draws in its own window, so it's
    /// asked for a copy (written to this machine's private temp folder and read back).
    func screenshot() async -> NSImage? {
        guard state == .running, let qmp, let socketDirectory else { return nil }
        let file = socketDirectory.appendingPathComponent("screen.png")
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? await qmp.execute("screendump", arguments: ["filename": file.path, "format": "png"], timeout: 10)) != nil else { return nil }
        return NSImage(contentsOf: file)
    }

    #if DEBUG
    /// The guest's screen as a PNG, without any window (self-tests run QEMU headless).
    func screendump(to url: URL) async throws {
        _ = try await qmp?.execute("screendump", arguments: ["filename": url.path, "format": "png"], timeout: 10)
    }
    #endif

    #if DEBUG
    /// Self-tests drive headless guests through a folder (`-OrbitQEMUControlDir`): the screen is
    /// saved to `screen.png` every few seconds, and each line of `keys.txt` is typed and the file
    /// removed. Lines: QEMU key names joined by "+" ("ret", "tab", "shift+tab", "alt+n"), or
    /// "text:hello" to type letters and digits.
    private func startRemoteControl() {
        guard let path = UserDefaults.standard.string(forKey: "OrbitQEMUControlDir") else { return }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { [weak self] in
            var tick = 0
            while let self, self.state == .running || self.state == .paused, let qmp = self.qmp {
                let keys = dir.appendingPathComponent("keys.txt")
                if let text = try? String(contentsOf: keys, encoding: .utf8) {
                    try? FileManager.default.removeItem(at: keys)
                    for line in text.split(whereSeparator: \.isNewline).map(String.init) {
                        for combo in Self.keyCombos(line) {
                            _ = try? await qmp.execute("send-key", arguments: ["keys": combo.map { ["type": "qcode", "data": $0] }])
                            try? await Task.sleep(for: .milliseconds(120))
                        }
                    }
                }
                if tick % 5 == 0 {
                    _ = try? await qmp.execute("screendump", arguments: ["filename": dir.appendingPathComponent("screen.png").path, "format": "png"], timeout: 10)
                }
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static func keyCombos(_ line: String) -> [[String]] {
        if line.hasPrefix("text:") {
            return line.dropFirst(5).map { c -> [String] in
                switch c {
                case " ": ["spc"]
                case "-": ["minus"]
                case ".": ["dot"]
                case _ where c.isUppercase: ["shift", c.lowercased()]
                default: [String(c)]
                }
            }
        }
        return [line.split(separator: "+").map(String.init)]
    }
    #endif

    /// No guest has written to any disk yet: a first boot.
    private var hasBlankDisks: Bool {
        let disks = config.disks.filter { !$0.isRemovable }
        return !disks.isEmpty && disks.allSatisfy { DiskImageService.allocatedBytes(at: bundle.diskURL(for: $0)) < 32 << 20 }
    }

    /// The Windows installer disc waits a few seconds for "Press any key to boot from CD or DVD"
    /// and gives up otherwise. With nothing on the disk yet, answer it. Only on that first boot:
    /// during setup's own restarts the disk is no longer blank, and a key would start setup over.
    private func answerBootPrompt() {
        Task { [weak self] in
            for _ in 0..<24 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.state == .running, let qmp = self.qmp else { return }
                _ = try? await qmp.execute("send-key", arguments: ["keys": [["type": "qcode", "data": "ret"]]])
            }
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
        guard let swtpm = HostInfo.swtpm else {
            throw VMError.invalidConfiguration("This machine has a TPM chip, which needs swtpm. Install it with: brew install swtpm. Or turn the TPM off in Settings → Advanced, if Windows isn't installed yet.")
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
