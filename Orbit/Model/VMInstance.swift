import AppKit
import Observation
import Virtualization

/// One virtual machine in the library: its configuration, live state and engine.
@Observable
@MainActor
final class VMInstance: Identifiable {
    let bundle: VMBundle
    var config: VMConfiguration {
        didSet {
            guard config != oldValue else { return }
            scheduleSave()
            (backend as? AppleBackend)?.update(config: config)
            (backend as? QEMUBackend)?.update(config: config)
        }
    }

    private(set) var state: VMState = .stopped
    private(set) var startedAt: Date?
    private(set) var isDisposableRun = false
    private(set) var hasSavedState = false
    private(set) var snapshots: [VMSnapshot] = []
    private(set) var diskUsageBytes: Int64 = 0
    var screenshot: NSImage?
    var installProgress: Double?
    var installStatus: String?
    var activeDownload: DownloadTask?
    /// Display overlays hide while this is set.
    private(set) var isCapturingScreenshot = false
    /// Shown as an alert by whichever window is frontmost.
    var lastError: String?

    @ObservationIgnored private(set) var backend: VMBackend?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var screenshotTimer: Timer?
    @ObservationIgnored private var healthTimer: Timer?

    nonisolated let id: UUID

    var template: OSTemplate? { OSTemplate.template(id: config.templateID) }
    var appleBackend: AppleBackend? { backend as? AppleBackend }
    var canSuspend: Bool { backend?.supportsSuspend ?? (config.engine == .apple) }
    var hasEmbeddedDisplay: Bool { config.engine == .apple }

    init(bundle: VMBundle, config: VMConfiguration) {
        self.bundle = bundle
        self.config = config
        self.id = config.id
        refreshFileState()
        if let image = NSImage(contentsOf: bundle.screenshotURL) {
            screenshot = image
        }
    }

    // MARK: - Lifecycle

    func start(options: StartOptions = []) async {
        await perform {
            guard state == .stopped else { return }
            try ResourceGuard.checkCanStart(self, library: VMLibrary.shared)
            let backend = makeBackendIfNeeded()
            isDisposableRun = options.contains(.disposable)
            try await backend.start(options: options)
            config.lastRunAt = Date()
            startedAt = Date()
            refreshFileState()
            startScreenshotTimer()
            startHealthTimer()
        }
    }

    func requestStop() async {
        await perform { try await backend?.requestStop() }
    }

    func forceStop() async {
        await perform {
            await captureScreenshot()
            try await backend?.forceStop()
        }
    }

    func pause() async {
        await perform {
            await captureScreenshot()
            try await backend?.pause()
        }
    }

    func resume() async {
        await perform { try await backend?.resume() }
    }

    func restart() async {
        await perform { try await backend?.restart() }
    }

    func suspend() async {
        await perform {
            await captureScreenshot()
            try await backend?.suspend()
            refreshFileState()
        }
    }

    /// Quit path: suspend when possible, otherwise ask the guest to shut down and wait briefly.
    func stopForQuit() async {
        guard state.isActive else { return }
        if state == .installing {
            // an interrupted install can't be resumed; cancel it cleanly
            appleBackend?.cancelInstallation()
            for _ in 0..<50 where state.isActive {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return
        }
        if config.suspendOnQuit && canSuspend && !isDisposableRun && (state == .running || state == .paused) {
            await suspend()
            if !state.isActive { return }
        }
        await requestStop()
        // Windows in particular can take a while to shut down cleanly
        for _ in 0..<150 where state.isActive {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if state.isActive {
            await forceStop()
        }
    }

    func discardSavedState() {
        try? FileManager.default.removeItem(at: bundle.savedStateURL)
        refreshFileState()
    }

    // MARK: - macOS install

    func cancelInstallation() {
        activeDownload?.cancel()
        appleBackend?.cancelInstallation()
    }

    func installMacOS(from ipsw: URL) async {
        do {
            try ResourceGuard.checkCanStart(self, library: VMLibrary.shared)
        } catch {
            report(error)
            return
        }
        guard let backend = makeBackendIfNeeded() as? AppleBackend else { return }
        installProgress = 0
        installStatus = "Installing macOS…"
        await perform {
            try await backend.installMacOS(from: ipsw) { [weak self] fraction in
                self?.installProgress = fraction
            }
            config.bootFromInstaller = false
        }
        installProgress = nil
        installStatus = nil
        refreshFileState()
    }

    // MARK: - Media

    func ejectInstaller() {
        config.disks.removeAll { $0.isRemovable }
        config.bootFromInstaller = false
    }

    func attachInstaller(_ url: URL) {
        config.disks.removeAll { $0.isRemovable }
        config.disks.append(DiskConfiguration(path: url.path, sizeGiB: 0, isReadOnly: true, interface: .usb, isRemovable: true))
        config.bootFromInstaller = true
    }

    /// Validate and attach an installer image picked by the user.
    func attachInstallerChecked(_ url: URL) {
        switch FileInspector.inspect(url) {
        case .ipsw where config.guestOS == .macOS:
            lastError = "macOS VMs are installed when they are created. To reinstall, create a new macOS VM with this restore image."
        case .iso, .diskImage(.raw):
            attachInstaller(url)
        case .unsupported(let reason):
            lastError = reason
        default:
            lastError = "“\(url.lastPathComponent)” is not an installer image. Choose an .iso file."
        }
    }

    /// Add a disk image made elsewhere as an extra drive (converted if needed).
    func importDisk(_ url: URL) async {
        guard case .diskImage(let format) = FileInspector.inspect(url) else {
            if case .unsupported(let reason) = FileInspector.inspect(url) { lastError = reason } else {
                lastError = "“\(url.lastPathComponent)” is not a disk image."
            }
            return
        }
        guard !state.isActive else {
            lastError = "Shut down the machine before adding a disk."
            return
        }
        installStatus = format.isNative(to: config.engine) ? "Importing disk…" : "Converting \(format.displayName) disk…"
        defer { installStatus = nil }
        await perform {
            let id = UUID()
            let size = await FileInspector.virtualSizeGiB(of: url, format: format)
            let name = try await DiskImporter.importDisk(url, format: format, into: bundle.url, id: id, engine: config.engine)
            config.disks.append(DiskConfiguration(id: id, path: name, sizeGiB: size, interface: config.guestOS == .windows ? .nvme : .virtio))
            saveNow()
        }
        refreshFileState()
    }

    /// Remove a drive from the configuration and delete its file from the package.
    func removeDisk(_ disk: DiskConfiguration) {
        guard !state.isActive, !disk.isRemovable else { return }
        config.disks.removeAll { $0.id == disk.id }
        if !disk.isExternal {
            try? FileManager.default.trashItem(at: bundle.diskURL(for: disk), resultingItemURL: nil)
        }
        saveNow()
        refreshFileState()
    }

    // MARK: - Snapshots

    func takeSnapshot(named name: String) async {
        await perform {
            let wasRunning = state == .running || state == .paused
            if wasRunning {
                guard canSuspend else {
                    throw VMError.unsupported("Live snapshots for this engine. Shut down the VM first")
                }
                await captureScreenshot()
                try await backend?.suspend()
            }
            do {
                try await SnapshotStore.create(named: name, for: self)
            } catch {
                // the machine was suspended for the snapshot: bring it back before reporting
                if wasRunning { try? await backend?.start(options: []) }
                refreshFileState()
                throw error
            }
            if wasRunning {
                // resumes from the state that was just captured
                try await backend?.start(options: [])
                startedAt = Date()
            }
            refreshFileState()
        }
    }

    func restore(_ snapshot: VMSnapshot) async {
        await perform {
            if state.isActive {
                try await backend?.forceStop()
            }
            try await SnapshotStore.restore(snapshot, for: self)
            if let image = NSImage(contentsOf: bundle.screenshotURL) { screenshot = image }
            refreshFileState()
        }
    }

    func delete(_ snapshot: VMSnapshot) {
        do {
            try SnapshotStore.delete(snapshot, for: self)
        } catch {
            report(error)
        }
        refreshFileState()
    }

    // MARK: - Screenshots

    func captureScreenshot() async {
        guard state == .running, appleBackend?.displayView?.window != nil else { return }
        // hide Orbit's own overlays so only the guest's pixels are captured
        isCapturingScreenshot = true
        defer { isCapturingScreenshot = false }
        try? await Task.sleep(for: .milliseconds(80))
        guard let image = await appleBackend?.screenshot() else { return }
        // a frame grabbed before the guest redraws (just after resume) is solid black
        if screenshot != nil && image.isNearlyBlack { return }
        screenshot = image
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: bundle.screenshotURL, options: .atomic)
        }
    }

    /// Pauses the machine before the host disk fills up, which would hurt macOS and could corrupt
    /// the guest's disk.
    private func startHealthTimer() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .running, let free = ResourceGuard.lowDiskSpace(for: self) else { return }
                await self.pause()
                self.lastError = "“\(self.config.name)” was paused because only \(free.formattedBytes) is left on its disk. Free up space, then resume it."
            }
        }
    }

    private func startScreenshotTimer() {
        screenshotTimer?.invalidate()
        guard hasEmbeddedDisplay else { return }
        screenshotTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .running else { return }
                await self.captureScreenshot()
            }
        }
    }

    // MARK: - Persistence

    func saveNow() {
        saveTask?.cancel()
        do {
            try bundle.save(config)
        } catch {
            lastError = "Couldn't save settings: \(ErrorMessages.message(for: error) ?? error.localizedDescription)"
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func refreshFileState() {
        hasSavedState = FileManager.default.fileExists(atPath: bundle.savedStateURL.path)
        snapshots = SnapshotStore.list(for: bundle)
        let disks = config.disks.filter { !$0.isRemovable && !$0.isExternal }.map(bundle.diskURL(for:))
        diskUsageBytes = disks.reduce(0) { $0 + DiskImageService.allocatedBytes(at: $1) }
    }

    // MARK: - Private

    private func makeBackendIfNeeded() -> VMBackend {
        if let backend { return backend }
        let backend: VMBackend = switch config.engine {
        case .apple: AppleBackend(config: config, bundle: bundle)
        case .qemu: QEMUBackend(config: config, bundle: bundle)
        }
        backend.onStateChange = { [weak self] state, error in
            guard let self else { return }
            self.state = state
            if state == .stopped {
                self.startedAt = nil
                self.isDisposableRun = false
                self.screenshotTimer?.invalidate()
                self.healthTimer?.invalidate()
                self.refreshFileState()
            }
            if let error {
                self.report(error)
            }
        }
        self.backend = backend
        return backend
    }

    private func perform(_ body: () async throws -> Void) async {
        do {
            try await body()
        } catch {
            report(error)
        }
    }

    /// Show an error to the user, unless it was a cancellation.
    func report(_ error: Error) {
        if let message = ErrorMessages.message(for: error) {
            lastError = message
        }
    }
}

extension VMInstance: Hashable {
    nonisolated static func == (lhs: VMInstance, rhs: VMInstance) -> Bool { lhs.id == rhs.id }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private extension NSImage {
    /// True when a coarse sample of the image has no visible content.
    var isNearlyBlack: Bool {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return true }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        return stride(from: 0, to: pixels.count, by: 4).allSatisfy { max(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) < 6 }
    }
}
