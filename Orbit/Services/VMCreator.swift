import Foundation
import Observation

/// Everything the New VM wizard collects.
struct VMDraft {
    enum Installer: Equatable {
        /// Fetch the newest image for the template (distro mirror or Apple).
        case download
        case local(URL)
        case none
    }

    var template: OSTemplate
    var name: String
    var cpuCount: Int
    var memoryMiB: Int
    var diskGiB: Int
    var installer: Installer
    var engine: VMEngineKind
    var architecture: GuestArchitecture
    var guestOS: GuestOS
    var rosetta: Bool
    var sharedFolder: URL?
    var startWhenReady = true
    /// Off unless the user turns it on: a guest with it can read anything copied on this Mac.
    var clipboardSharing = false
    /// Boot an existing disk image instead of creating a blank one.
    var existingDisk: URL?
    var existingDiskFormat: DiskFormat?

    init(template: OSTemplate, name: String) {
        self.template = template
        self.name = name
        cpuCount = HostInfo.recommendedCPUs
        memoryMiB = HostInfo.recommendedMemoryMiB(for: template.guestOS)
        diskGiB = template.defaultDiskGiB
        engine = template.engine
        architecture = template.architecture
        guestOS = template.guestOS
        rosetta = template.recommendsRosetta && HostInfo.rosettaAvailability != .notSupported
        switch template.source {
        case .macOSRestoreImage, .resolver: installer = .download
        case .manual, .custom: installer = .none
        }
    }
}

/// Turns a draft into a ready-to-boot VM, reporting progress on the new `VMInstance`
/// so the library shows it immediately instead of blocking in a modal.
@MainActor
enum VMCreator {
    static func create(_ draft: VMDraft, in library: VMLibrary) async throws -> VMInstance {
        var config = VMConfiguration(name: library.uniqueName(draft.name), engine: draft.engine, guestOS: draft.guestOS,
                                     architecture: draft.architecture, cpuCount: draft.cpuCount, memoryMiB: draft.memoryMiB)
        config.templateID = draft.template.id
        config.rosetta = draft.rosetta && draft.guestOS == .linux && draft.engine == .apple
        config.clipboardSharing = draft.clipboardSharing && draft.guestOS == .linux && draft.engine == .apple
        if let folder = draft.sharedFolder {
            config.sharedFolders = [SharedFolder(path: folder.path)]
        }
        if draft.guestOS == .windows {
            // Windows 11 setup wants a TPM 2.0; emulate one when swtpm is installed
            config.qemu.tpm = HostInfo.qemuSearchPaths.contains { FileManager.default.isExecutableFile(atPath: "\($0)/swtpm") }
        }
        if draft.guestOS == .macOS {
            config.display = DisplayConfiguration(widthPixels: 2880, heightPixels: 1800, pixelsPerInch: 224, dynamicResolution: true)
        } else {
            config.display = DisplayConfiguration(widthPixels: 1920, heightPixels: 1200, pixelsPerInch: 144, dynamicResolution: true)
        }

        let bundle = try library.makeBundle(named: config.name)
        do {
            if draft.existingDisk == nil {
                let diskID = UUID()
                let diskName = try await DiskImageService.create(in: bundle.url, id: diskID, sizeGiB: draft.diskGiB, engine: draft.engine)
                config.disks = [DiskConfiguration(id: diskID, path: diskName, sizeGiB: draft.diskGiB, interface: diskInterface(for: draft))]
            }
            if draft.engine == .apple && draft.guestOS != .macOS {
                try PlatformProvisioner.provisionGeneric(bundle: bundle)
            }
            if case .local(let url) = draft.installer, draft.guestOS != .macOS {
                config.disks.append(DiskConfiguration(path: url.path, sizeGiB: 0, isReadOnly: true, interface: .usb, isRemovable: true))
            }
            config.bootFromInstaller = draft.installer != .none
        } catch {
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
        }

        let vm = try library.register(bundle: bundle, config: config)
        vm.installStatus = draft.existingDisk == nil ? "Preparing…" : "Importing disk…"
        Task { await finish(vm, draft: draft, library: library) }
        return vm
    }

    /// Windows on ARM ships NVMe drivers but none for virtio-blk.
    private static func diskInterface(for draft: VMDraft) -> DiskInterface {
        draft.guestOS == .windows ? .nvme : .virtio
    }

    /// Download + install phase, runs after the VM is visible in the library.
    private static func finish(_ vm: VMInstance, draft: VMDraft, library: VMLibrary) async {
        do {
            if let source = draft.existingDisk, let format = draft.existingDiskFormat {
                vm.installStatus = format.isNative(to: draft.engine) ? "Importing disk…" : "Converting \(format.displayName) disk…"
                let id = UUID()
                let size = await FileInspector.virtualSizeGiB(of: source, format: format)
                let name = try await DiskImporter.importDisk(source, format: format, into: vm.bundle.url, id: id, engine: draft.engine)
                vm.config.disks.insert(DiskConfiguration(id: id, path: name, sizeGiB: size, interface: diskInterface(for: draft)), at: 0)
                vm.saveNow()
                vm.refreshFileState()
            }
            if draft.guestOS == .macOS {
                let ipsw: URL
                switch draft.installer {
                case .local(let url): ipsw = url
                default:
                    vm.installStatus = "Finding the latest macOS…"
                    let latest = try await PlatformProvisioner.latestRestoreImage()
                    vm.installStatus = "Downloading macOS \(latest.version)"
                    ipsw = try await download(latest.url, into: library, for: vm)
                }
                vm.installStatus = "Preparing hardware…"
                let minimum = try await PlatformProvisioner.provisionMac(bundle: vm.bundle, ipsw: ipsw)
                vm.config.cpuCount = max(vm.config.cpuCount, minimum.cpus)
                vm.config.memoryMiB = max(vm.config.memoryMiB, minimum.memoryMiB)
                vm.saveNow()
                // a cancelled install reports no error, so ask whether it actually finished
                if await vm.installMacOS(from: ipsw), draft.startWhenReady {
                    await vm.start()
                }
            } else {
                if draft.installer == .download, case .resolver(let resolver) = draft.template.source {
                    vm.installStatus = "Finding the latest \(draft.template.name)…"
                    let resolved = try await resolver.resolve()
                    vm.installStatus = "Downloading \(draft.template.name) \(resolved.version)"
                    let iso = try await download(resolved.url, into: library, for: vm)
                    if let checksum = resolved.checksumURL {
                        vm.installStatus = "Verifying \(draft.template.name) \(resolved.version)…"
                        vm.installProgress = nil
                        try await ChecksumVerifier.verify(iso, against: checksum)
                    }
                    vm.attachInstaller(iso)
                    vm.saveNow()
                }
                vm.installStatus = nil
                vm.installProgress = nil
                if draft.startWhenReady && (vm.config.installerMedia != nil || draft.existingDisk != nil) {
                    await vm.start()
                }
            }
        } catch {
            vm.report(error)
        }
        vm.installStatus = nil
        vm.installProgress = nil
        vm.activeDownload = nil
    }

    private static func download(_ url: URL, into library: VMLibrary, for vm: VMInstance) async throws -> URL {
        let task = DownloadTask(source: url, destination: library.installersURL.appendingPathComponent(url.lastPathComponent))
        vm.activeDownload = task
        defer { vm.activeDownload = nil }
        return try await task.run()
    }
}
