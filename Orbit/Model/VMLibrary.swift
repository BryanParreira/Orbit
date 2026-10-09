import AppKit
import Observation

/// All virtual machines Orbit knows about, stored as `.orbitvm` packages in one folder.
@Observable
@MainActor
final class VMLibrary {
    static let shared = VMLibrary()

    private(set) var vms: [VMInstance] = []
    private(set) var rootURL: URL
    /// Set when the library folder can't be reached (e.g. its external drive is unplugged).
    private(set) var isRootUnavailable = false

    var installersURL: URL { rootURL.appendingPathComponent("Installers", isDirectory: true) }
    var runningCount: Int { vms.filter { $0.state.isActive }.count }

    static var defaultRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orbit/Virtual Machines", isDirectory: true)
    }

    private init() {
        if let path = UserDefaults.standard.string(forKey: PreferenceKey.libraryPath), !path.isEmpty {
            rootURL = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            rootURL = Self.defaultRootURL
        }
        AppleBackend.removeStaleOverlays()
        reload()
        // a library on an external drive comes back when the drive is reconnected
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { VMLibrary.shared.reload() }
            }
        }
    }

    func vm(with id: UUID) -> VMInstance? {
        vms.first { $0.id == id }
    }

    func reload() {
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var isDirectory: ObjCBool = false
        isRootUnavailable = !(FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: rootURL.path))
        let urls = (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        var loaded: [VMInstance] = []
        for url in urls where url.pathExtension == VMBundle.fileExtension {
            if let existing = vms.first(where: { $0.bundle.url == url }) {
                loaded.append(existing)
                continue
            }
            let bundle = VMBundle(url: url)
            guard let config = try? bundle.loadConfiguration() else { continue }
            loaded.append(VMInstance(bundle: bundle, config: config))
        }
        // keep running VMs even if their package disappeared
        loaded += vms.filter { vm in vm.state.isActive && !loaded.contains(vm) }
        vms = loaded.sorted { $0.config.createdAt < $1.config.createdAt }
    }

    func moveLibrary(to url: URL) {
        UserDefaults.standard.set(url.path, forKey: PreferenceKey.libraryPath)
        rootURL = url
        vms = vms.filter { $0.state.isActive }
        reload()
    }

    // MARK: - Creating

    /// A fresh, uniquely named package directory.
    func makeBundle(named name: String) throws -> VMBundle {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var url = rootURL.appendingPathComponent(safe).appendingPathExtension(VMBundle.fileExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = rootURL.appendingPathComponent("\(safe) \(n)").appendingPathExtension(VMBundle.fileExtension)
            n += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return VMBundle(url: url)
    }

    @discardableResult
    func register(bundle: VMBundle, config: VMConfiguration) throws -> VMInstance {
        try bundle.save(config)
        let vm = VMInstance(bundle: bundle, config: config)
        vms.append(vm)
        return vm
    }

    func uniqueName(_ base: String) -> String {
        let names = Set(vms.map(\.config.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: - Managing

    /// What deleting a machine removes, so the user can see it before confirming.
    struct DeletionPlan {
        /// Disks, snapshots, saved memory, firmware, screenshots: the whole package.
        let packageBytes: Int64
        /// An installer Orbit downloaded for this machine that no other machine uses.
        let installer: URL?
        let installerBytes: Int64

        var totalBytes: Int64 { packageBytes + installerBytes }
    }

    func deletionPlan(for vm: VMInstance) async -> DeletionPlan {
        let package = await Self.allocatedSize(of: vm.bundle.url)
        var installer: URL?
        var installerBytes: Int64 = 0
        // only installers Orbit itself downloaded; an image the user brought is theirs to keep
        if let path = vm.config.installerMedia?.path {
            let url = URL(fileURLWithPath: path)
            let usedElsewhere = vms.contains { $0 != vm && $0.config.installerMedia?.path == path }
            if url.deletingLastPathComponent().standardizedFileURL.path == installersURL.standardizedFileURL.path, !usedElsewhere,
               FileManager.default.fileExists(atPath: url.path) {
                installer = url
                installerBytes = DiskImageService.allocatedBytes(at: url)
            }
        }
        return DeletionPlan(packageBytes: package, installer: installer, installerBytes: installerBytes)
    }

    /// Remove a machine and everything it left on this Mac.
    /// - Parameters:
    ///   - permanently: Free the space now; otherwise the package goes to the Trash, which keeps using space until emptied.
    ///   - removeInstaller: Also delete the downloaded installer the plan found.
    func delete(_ vm: VMInstance, permanently: Bool = true, removeInstaller: Bool = true) async throws {
        let plan = await deletionPlan(for: vm)
        vm.activeDownload?.cancel()
        if vm.state.isActive {
            await vm.forceStop()
        }
        if permanently {
            try FileManager.default.removeItem(at: vm.bundle.url)
        } else {
            try FileManager.default.trashItem(at: vm.bundle.url, resultingItemURL: nil)
        }
        if removeInstaller, let installer = plan.installer {
            try? FileManager.default.removeItem(at: installer)
            try? FileManager.default.removeItem(at: Self.verificationMarker(for: installer))
        }
        removeTemporaryFiles(of: vm)
        vms.removeAll { $0 == vm }
    }

    /// Per-machine temporary files: QEMU's control folder, and throwaway clones once nothing runs.
    private func removeTemporaryFiles(of vm: VMInstance) {
        let temp = FileManager.default.temporaryDirectory
        try? FileManager.default.removeItem(at: temp.appendingPathComponent("orbit-\(vm.id.uuidString.prefix(8))"))
        if !vms.contains(where: { $0 != vm && $0.state.isActive }) {
            AppleBackend.removeStaleOverlays()
        }
    }

    nonisolated static func verificationMarker(for installer: URL) -> URL {
        installer.deletingLastPathComponent().appendingPathComponent(".\(installer.lastPathComponent).verified")
    }

    // MARK: - Leftovers

    struct Leftover: Identifiable {
        let id = UUID()
        let url: URL
        let bytes: Int64
        /// Plain-language explanation of what it is.
        let reason: String
    }

    /// Files in Orbit's folders that belong to no machine: crashed runs, half-finished imports,
    /// unused downloads. Never anything outside Orbit's own folders, never a working machine.
    func leftovers() async -> [Leftover] {
        let fm = FileManager.default
        var found: [Leftover] = []
        let known = Set(vms.map { $0.bundle.url.standardizedFileURL.path })
        for item in (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? [] {
            let name = item.lastPathComponent
            if name == "Installers" || name.hasPrefix(".") || known.contains(item.standardizedFileURL.path) { continue }
            if item.pathExtension == VMBundle.fileExtension, fm.fileExists(atPath: item.appendingPathComponent("config.json").path) { continue }
            let reason = item.pathExtension == VMBundle.fileExtension
                ? "An unfinished machine (it has no settings file), for example from an interrupted import."
                : "A file that isn't part of any machine."
            found.append(Leftover(url: item, bytes: await Self.allocatedSize(of: item), reason: reason))
        }
        for installer in unusedInstallers() {
            found.append(Leftover(url: installer, bytes: DiskImageService.allocatedBytes(at: installer),
                                  reason: "A downloaded installer no machine uses. It downloads again if you need it."))
        }
        for marker in (try? fm.contentsOfDirectory(at: installersURL, includingPropertiesForKeys: nil)) ?? []
        where marker.lastPathComponent.hasPrefix(".") && marker.pathExtension == "verified" {
            let image = installersURL.appendingPathComponent(String(marker.deletingPathExtension().lastPathComponent.dropFirst()))
            if !fm.fileExists(atPath: image.path) {
                found.append(Leftover(url: marker, bytes: DiskImageService.allocatedBytes(at: marker), reason: "A checksum record for a download that's gone."))
            }
        }
        if !vms.contains(where: { $0.state.isActive }) {
            let temp = fm.temporaryDirectory
            // only Orbit's own patterns: throwaway clones and per-machine control folders
            for item in (try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)) ?? []
            where Self.isOrbitTemporary(item.lastPathComponent) {
                found.append(Leftover(url: item, bytes: await Self.allocatedSize(of: item),
                                      reason: "Temporary files from a machine that didn't stop cleanly."))
            }
        }
        return found
    }

    nonisolated static func isOrbitTemporary(_ name: String) -> Bool {
        name.hasPrefix("orbit-disposable-")
            || name.wholeMatch(of: /orbit-[0-9A-F]{8}/) != nil
    }

    func remove(_ leftovers: [Leftover]) {
        for item in leftovers {
            try? FileManager.default.removeItem(at: item.url)
        }
    }

    /// APFS clone of the whole package with a fresh identity: instant, and free until either copy changes.
    @discardableResult
    func duplicate(_ vm: VMInstance) async throws -> VMInstance {
        vm.saveNow()
        var config = vm.config
        config.id = UUID()
        config.name = uniqueName("\(vm.config.name) Copy")
        config.network.macAddress = NetworkConfiguration.randomMACAddress()
        config.createdAt = Date()
        config.lastRunAt = nil
        let bundle = try makeBundle(named: config.name)
        do {
            let skip: Set<String> = ["config.json", "Snapshots", VMBundle(url: vm.bundle.url).savedStateURL.lastPathComponent]
            for item in try FileManager.default.contentsOfDirectory(atPath: vm.bundle.url.path) where !skip.contains(item) {
                try await FileCloner.cloneInBackground(vm.bundle.url.appendingPathComponent(item), to: bundle.url.appendingPathComponent(item))
            }
            try PlatformProvisioner.regenerateIdentity(bundle: bundle, guestOS: config.guestOS)
            return try register(bundle: bundle, config: config)
        } catch {
            // a half-made copy is worse than none
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
        }
    }

    /// Import an `.orbitvm` or a UTM `.utm` package (cloned, original untouched).
    @discardableResult
    func importPackage(at url: URL) async throws -> VMInstance {
        switch url.pathExtension.lowercased() {
        case VMBundle.fileExtension:
            var config = try VMBundle(url: url).loadConfiguration()
            PackageValidator.sanitize(&config, imported: true)
            if vms.contains(where: { $0.id == config.id }) {
                config.id = UUID()
            }
            config.name = uniqueName(config.name)
            let bundle = try makeBundle(named: config.name)
            do {
                try FileManager.default.removeItem(at: bundle.url)
                try await FileCloner.cloneInBackground(url, to: bundle.url)
                return try register(bundle: bundle, config: config)
            } catch {
                try? FileManager.default.removeItem(at: bundle.url)
                throw error
            }
        case "utm":
            return try await UTMImporter.importPackage(at: url, into: self)
        default:
            throw VMError.invalidConfiguration("\(url.lastPathComponent) is not a virtual machine package.")
        }
    }

    // MARK: - Storage

    /// Bytes actually used on disk under `url` (sparse-aware), computed off the main thread.
    nonisolated static func allocatedSize(of url: URL) async -> Int64 {
        await Task.detached(priority: .utility) { allocatedSizeNow(of: url) }.value
    }

    nonisolated private static func allocatedSizeNow(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in items {
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    /// Installer images no machine has attached.
    func unusedInstallers() -> [URL] {
        let attached = Set(vms.compactMap { $0.config.installerMedia?.path })
        let files = (try? FileManager.default.contentsOfDirectory(at: installersURL, includingPropertiesForKeys: nil)) ?? []
        return files.filter { !$0.lastPathComponent.hasPrefix(".") && !attached.contains($0.path) }
    }

    /// Delete downloaded installers that no machine uses; they download again when needed.
    func removeUnusedInstallers() {
        for file in unusedInstallers() {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: Self.verificationMarker(for: file))
        }
    }

    func revealInFinder(_ vm: VMInstance) {
        NSWorkspace.shared.activateFileViewerSelecting([vm.bundle.url])
    }
}
