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

    func delete(_ vm: VMInstance) async throws {
        vm.activeDownload?.cancel()
        if vm.state.isActive {
            await vm.forceStop()
        }
        try FileManager.default.trashItem(at: vm.bundle.url, resultingItemURL: nil)
        vms.removeAll { $0 == vm }
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
        let skip: Set<String> = ["config.json", "Snapshots", VMBundle(url: vm.bundle.url).savedStateURL.lastPathComponent]
        for item in try FileManager.default.contentsOfDirectory(atPath: vm.bundle.url.path) where !skip.contains(item) {
            try await FileCloner.cloneInBackground(vm.bundle.url.appendingPathComponent(item), to: bundle.url.appendingPathComponent(item))
        }
        try PlatformProvisioner.regenerateIdentity(bundle: bundle, guestOS: config.guestOS)
        return try register(bundle: bundle, config: config)
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
            try FileManager.default.removeItem(at: bundle.url)
            try await FileCloner.cloneInBackground(url, to: bundle.url)
            return try register(bundle: bundle, config: config)
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
            let marker = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).verified")
            try? FileManager.default.removeItem(at: marker)
        }
    }

    func revealInFinder(_ vm: VMInstance) {
        NSWorkspace.shared.activateFileViewerSelecting([vm.bundle.url])
    }
}
