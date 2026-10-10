import AppKit
import Observation

/// All virtual machines Orbit knows about, stored as `.orbitvm` packages in the library folder or,
/// when the user chose so, in a folder of their own (another drive, for example).
@Observable
@MainActor
final class VMLibrary {
    static let shared = VMLibrary()

    private(set) var vms: [VMInstance] = []
    private(set) var rootURL: URL
    /// Set when the library folder can't be reached (e.g. its external drive is unplugged).
    private(set) var isRootUnavailable = false
    /// Machines kept outside the library whose drive or folder can't be reached right now.
    private(set) var unreachableMachines: [URL] = []

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
        // the library first; machines on other drives after the window is up: reading a
        // removable drive waits for the user to allow it, and that must not freeze launch
        reload(includeElsewhere: false)
        trackActivity()
        loadElsewhereInBackground()
        // a library on an external drive comes back when the drive is reconnected
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { VMLibrary.shared.reload() }
            }
        }
    }

    // MARK: - Staying awake

    @ObservationIgnored private var activity: (options: ProcessInfo.ActivityOptions, token: NSObjectProtocol)?

    /// Keep macOS from napping Orbit while it works in the background: App Nap would throttle
    /// the timers that pause machines before the disk fills, and stall downloads and installs.
    /// Running machines still let an idle Mac sleep; downloads and installs keep it awake.
    private func trackActivity() {
        withObservationTracking {
            updateActivity()
        } onChange: {
            Task { @MainActor in VMLibrary.shared.trackActivity() }
        }
    }

    private func updateActivity() {
        let busy = vms.contains { $0.installStatus != nil || $0.activeDownload != nil }
        let running = vms.contains { $0.state.isActive }
        let wanted: ProcessInfo.ActivityOptions? = busy ? .userInitiated : running ? .userInitiatedAllowingIdleSystemSleep : nil
        guard wanted != activity?.options else { return }
        if let activity { ProcessInfo.processInfo.endActivity(activity.token) }
        activity = wanted.map { options in
            let reason = busy ? "Downloading or installing a virtual machine" : "Running virtual machines"
            return (options, ProcessInfo.processInfo.beginActivity(options: options, reason: reason))
        }
    }

    func vm(with id: UUID) -> VMInstance? {
        vms.first { $0.id == id }
    }

    /// Read each machine kept elsewhere once off the main thread (where macOS may hold the read
    /// until the user answers its removable-drive prompt), then list them.
    private func loadElsewhereInBackground() {
        let paths = externalLocations
        guard !paths.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            for path in paths {
                _ = FileManager.default.contents(atPath: (path as NSString).appendingPathComponent("config.json"))
            }
            await MainActor.run { VMLibrary.shared.reload() }
        }
    }

    func reload(includeElsewhere: Bool = true) {
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var isDirectory: ObjCBool = false
        isRootUnavailable = !(FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: rootURL.path))
        var urls = ((try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == VMBundle.fileExtension }
        // no trailing "/": these must compare equal to package URLs built by appending a name
        let elsewhere = includeElsewhere ? externalLocations.map { URL(filePath: $0, directoryHint: .notDirectory) } : []
        unreachableMachines = elsewhere.filter { !FileManager.default.fileExists(atPath: $0.appendingPathComponent("config.json").path) }
        let inLibrary = Set(urls.map(\.standardizedFileURL.path))
        urls += elsewhere.filter { !unreachableMachines.contains($0) && !inLibrary.contains($0.standardizedFileURL.path) }
        var loaded: [VMInstance] = []
        for url in urls {
            // match by location (paths: listed folder URLs end in "/", others don't) and keep the
            // live instance, so a reload never creates a second copy of a machine
            if let existing = vms.first(where: { $0.bundle.url.standardizedFileURL.path == url.standardizedFileURL.path }) {
                loaded.append(existing)
                continue
            }
            let bundle = VMBundle(url: url)
            guard var config = try? bundle.loadConfiguration() else { continue }
            // a package copied in Finder carries the original's identity: give the copy its own, so
            // the two never collide (same ID, same MAC address, same machine identifier)
            if vms.contains(where: { $0.id == config.id }) || loaded.contains(where: { $0.id == config.id }) {
                config.id = UUID()
                config.network.macAddress = NetworkConfiguration.randomMACAddress()
                try? PlatformProvisioner.regenerateIdentity(bundle: bundle, guestOS: config.guestOS)
                try? FileManager.default.removeItem(at: bundle.savedStateURL)
                try? bundle.save(config)
            }
            loaded.append(VMInstance(bundle: bundle, config: config))
        }
        // keep running VMs even if their package disappeared
        loaded += vms.filter { vm in vm.state.isActive && !loaded.contains(vm) }
        vms = loaded.sorted { $0.config.createdAt < $1.config.createdAt }
    }

    /// Use `url` for the library. A folder that already holds other things (Documents, an external
    /// drive) gets an "Orbit Virtual Machines" folder inside it rather than having machines mixed
    /// in with the user's files.
    func moveLibrary(to url: URL) {
        let items = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }
        let isLibrary = items.allSatisfy { $0 == "Installers" || $0.hasSuffix(".\(VMBundle.fileExtension)") }
        let target = isLibrary ? url : url.appendingPathComponent("Orbit Virtual Machines", isDirectory: true)
        UserDefaults.standard.set(target.path, forKey: PreferenceKey.libraryPath)
        rootURL = target
        vms = vms.filter { $0.state.isActive }
        reload()
    }

    // MARK: - Locations

    /// Package paths of machines kept outside the library folder.
    private var externalLocations: [String] {
        get { UserDefaults.standard.stringArray(forKey: PreferenceKey.machineLocations) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: PreferenceKey.machineLocations) }
    }

    /// Whether `vm` lives outside the library folder, in a place the user chose.
    func isOutsideLibrary(_ vm: VMInstance) -> Bool {
        vm.bundle.url.deletingLastPathComponent().standardizedFileURL.path != rootURL.standardizedFileURL.path
    }

    /// Remember (or forget) a package that lives outside the library, so reloads find it.
    private func track(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = externalLocations.filter { $0 != path }
        if url.deletingLastPathComponent().standardizedFileURL.path != rootURL.standardizedFileURL.path {
            paths.append(path)
        }
        externalLocations = paths
    }

    private func untrack(_ url: URL) {
        let path = url.standardizedFileURL.path
        externalLocations = externalLocations.filter { $0 != path }
    }

    /// Stop listing a machine whose drive is gone. Its files, wherever they are, are left alone.
    func forgetUnreachable(_ url: URL) {
        untrack(url)
        unreachableMachines.removeAll { $0.standardizedFileURL.path == url.standardizedFileURL.path }
    }

    /// Whether the machine package at `url` is on a drive or folder that can't be reached.
    func isUnreachable(_ url: URL) -> Bool {
        unreachableMachines.contains { $0.standardizedFileURL.path == url.standardizedFileURL.path }
    }

    /// Where a new machine's package goes: `folder` as chosen, or the library.
    /// Refuses folders inside another machine and places Orbit can't write to.
    func validateLocation(_ folder: URL) throws {
        let path = folder.standardizedFileURL.path
        if folder.pathComponents.contains(where: { $0.hasSuffix(".\(VMBundle.fileExtension)") }) {
            throw VMError.invalidConfiguration("That folder is inside another machine. Choose a folder outside any .\(VMBundle.fileExtension) package.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: path) else {
            throw VMError.invalidConfiguration("Orbit can't save to \(folder.path(percentEncoded: false)). Choose a folder you can write to.")
        }
    }

    /// Move a stopped machine to `folder`: a rename on the same drive, a copy then delete across drives.
    /// Returns the machine at its new location (the old instance is replaced).
    @discardableResult
    func move(_ vm: VMInstance, to folder: URL) async throws -> VMInstance {
        guard !vm.state.isActive, vm.installStatus == nil else {
            throw VMError.invalidConfiguration("Shut down “\(vm.config.name)” before moving it.")
        }
        try validateLocation(folder)
        let source = vm.bundle.url
        if folder.standardizedFileURL.path == source.deletingLastPathComponent().standardizedFileURL.path { return vm }
        vm.saveNow()
        let destination = Self.uniquePackageURL(named: source.deletingPathExtension().lastPathComponent, in: folder)
        let sameVolume = Self.volume(of: source) == Self.volume(of: folder)
        if !sameVolume {
            let needed = await Self.allocatedSize(of: source)
            if let free = HostInfo.freeSpaceBytes(at: folder), free < needed + ResourceGuard.minimumFreeToStart {
                throw VMError.invalidConfiguration("“\(vm.config.name)” uses \(needed.formattedBytes), but only \(free.formattedBytes) is free there. Free up space or choose another drive.")
            }
        }
        vm.installStatus = sameVolume ? "Moving…" : "Copying to \(folder.lastPathComponent)…"
        defer { vm.installStatus = nil }
        do {
            try await Task.detached(priority: .userInitiated) {
                if sameVolume {
                    try FileManager.default.moveItem(at: source, to: destination)
                } else {
                    try Self.copyPackage(source, to: destination)
                }
            }.value
        } catch {
            if !sameVolume { try? FileManager.default.removeItem(at: destination) }
            throw error
        }
        let bundle = VMBundle(url: destination)
        var config = vm.config
        Self.rebase(&config, from: source, to: destination)
        try bundle.save(config)
        if !sameVolume {
            // the copy is complete and saved; only now remove the original
            try? FileManager.default.removeItem(at: source)
        }
        untrack(source)
        track(destination)
        let moved = VMInstance(bundle: bundle, config: config)
        if let index = vms.firstIndex(of: vm) { vms[index] = moved }
        return moved
    }

    /// Paths in `config` that point inside the package (a downloaded installer) follow it to `new`.
    private static func rebase(_ config: inout VMConfiguration, from old: URL, to new: URL) {
        let prefix = old.standardizedFileURL.path + "/"
        for index in config.disks.indices where config.disks[index].path.hasPrefix(prefix) {
            config.disks[index].path = new.standardizedFileURL.path + "/" + config.disks[index].path.dropFirst(prefix.count)
        }
    }

    /// Copy a package to another drive, keeping sparse disks sparse.
    nonisolated private static func copyPackage(_ source: URL, to destination: URL) throws {
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_DATA_SPARSE)
        guard copyfile(source.path, destination.path, nil, flags) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path,
                                                          NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
        }
    }

    nonisolated private static func volume(of url: URL) -> URL? {
        try? url.resourceValues(forKeys: [.volumeURLKey]).volume
    }

    // MARK: - Creating

    /// A fresh, uniquely named package directory, in the library or in `folder`.
    func makeBundle(named name: String, in folder: URL? = nil) throws -> VMBundle {
        let parent = folder ?? rootURL
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let url = Self.uniquePackageURL(named: name, in: parent)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return VMBundle(url: url)
    }

    nonisolated private static func uniquePackageURL(named name: String, in parent: URL) -> URL {
        var safe = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        // no hidden or empty package names, and stay well under the file system's name limit
        while safe.hasPrefix(".") { safe.removeFirst() }
        if safe.isEmpty { safe = "Virtual Machine" }
        safe = String(safe.prefix(120))
        var url = parent.appendingPathComponent(safe).appendingPathExtension(VMBundle.fileExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = parent.appendingPathComponent("\(safe) \(n)").appendingPathExtension(VMBundle.fileExtension)
            n += 1
        }
        return url
    }

    @discardableResult
    func register(bundle: VMBundle, config: VMConfiguration) throws -> VMInstance {
        try bundle.save(config)
        track(bundle.url)
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
        vm.prepareForDeletion()
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
        untrack(vm.bundle.url)
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
        // Only Orbit's own kinds of files are ever candidates: the library may share a folder with
        // the user's documents, and nothing that isn't recognizably Orbit's may be offered for deletion.
        for item in (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        where item.pathExtension == VMBundle.fileExtension && !known.contains(item.standardizedFileURL.path) {
            if fm.fileExists(atPath: item.appendingPathComponent("config.json").path) { continue }
            found.append(Leftover(url: item, bytes: await Self.allocatedSize(of: item),
                                  reason: "An unfinished machine (it has no settings file), for example from an interrupted import."))
        }
        for installer in unusedInstallers() {
            found.append(Leftover(url: installer, bytes: DiskImageService.allocatedBytes(at: installer),
                                  reason: "A downloaded installer no machine uses. It downloads again if you need it."))
        }
        for partial in (try? fm.contentsOfDirectory(at: installersURL, includingPropertiesForKeys: nil)) ?? []
        where partial.lastPathComponent.hasPrefix(".") && partial.pathExtension == "download" && activeDownloads == 0 {
            found.append(Leftover(url: partial, bytes: DiskImageService.allocatedBytes(at: partial),
                                  reason: "A download that was interrupted before it finished."))
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
        if !vms.contains(where: { $0.state == .installing || $0.installStatus != nil }) {
            // Apple's macOS installer unpacks the restore image here (about 9 GB) and leaves it
            // behind if the install is interrupted. Only stale ones: another app may be installing.
            let temp = fm.temporaryDirectory
            for item in (try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where item.lastPathComponent.hasPrefix("com.apple.Virtualization.Installation.") {
                let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
                guard Date().timeIntervalSince(modified) > 2 * 3600 else { continue }
                found.append(Leftover(url: item, bytes: await Self.allocatedSize(of: item),
                                      reason: "Files from a macOS installation that was interrupted."))
            }
        }
        return found
    }

    private var activeDownloads: Int { vms.filter { $0.activeDownload != nil }.count }

    nonisolated static func isOrbitTemporary(_ name: String) -> Bool {
        name.hasPrefix("orbit-disposable-")
            || name.hasPrefix("orbit-drivers-")
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
        // beside the original, so the copy is an instant clone on the same drive
        let bundle = try makeBundle(named: config.name, in: isOutsideLibrary(vm) ? vm.bundle.url.deletingLastPathComponent() : nil)
        Self.rebase(&config, from: vm.bundle.url, to: bundle.url)
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
