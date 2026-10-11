import Foundation
import Testing
@testable import Orbit

/// A machine package, a disk image or a configuration from someone else must never give a guest
/// access to files on this Mac, or make Orbit write or delete outside the machine.
@Suite(.serialized)
@MainActor
final class SecurityTests {
    let library = VMLibrary.shared
    private var folders: [URL] = []

    deinit {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-security-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    /// A file standing in for something private on this Mac.
    private func makeSecret(in folder: URL) throws -> URL {
        let secret = folder.appendingPathComponent("secret.txt")
        try "private".write(to: secret, atomically: true, encoding: .utf8)
        return secret
    }

    private func makeMachine(in folder: URL, configure: (inout VMConfiguration, VMBundle) throws -> Void = { _, _ in }) throws -> VMInstance {
        let bundle = try library.makeBundle(named: "Untrusted-\(UUID().uuidString.prefix(6))", in: folder)
        try DiskImageService.createSparseRaw(at: bundle.url.appendingPathComponent("Disk-1.img"), bytes: 64 << 20)
        var config = VMConfiguration(name: "Untrusted", engine: .apple, guestOS: .linux, cpuCount: 2, memoryMiB: 2048)
        config.disks = [DiskConfiguration(path: "Disk-1.img", sizeGiB: 1)]
        try configure(&config, bundle)
        return try library.register(bundle: bundle, config: config)
    }

    // MARK: - Configuration

    @Test func importedConfigurationLosesAccessToThisMac() {
        var config = VMConfiguration(name: "Crafted", engine: .qemu, guestOS: .linux, cpuCount: 2, memoryMiB: 2048)
        config.disks = [DiskConfiguration(path: "Disk-1.qcow2", sizeGiB: 8),
                        DiskConfiguration(path: "/Users/someone/.ssh/id_ed25519", sizeGiB: 0, isRemovable: true)]
        config.sharedFolders = [SharedFolder(path: "/Users/someone")]
        config.network.portForwards = [PortForward(hostPort: 2222, guestPort: 22)]
        config.network.macAddress = "52:54:00:00:00:01,id=evil"
        config.qemu.machine = "virt,dumpdtb=/Users/someone/.zshrc"
        config.qemu.extraArguments = ["-drive", "file=/etc/hosts"]
        config.startWithOrbit = true

        let removed = PackageValidator.sanitize(&config, imported: true)
        #expect(config.disks.map(\.path) == ["Disk-1.qcow2"], "installer outside the package")
        #expect(config.sharedFolders.isEmpty)
        #expect(config.network.portForwards.isEmpty)
        #expect(PackageValidator.isValidMACAddress(config.network.macAddress))
        #expect(config.qemu.machine == nil)
        #expect(config.qemu.extraArguments.isEmpty)
        #expect(!config.startWithOrbit)
        #expect(!removed.isEmpty)
    }

    @Test func ownMachinesKeepTheirChoices() {
        var config = VMConfiguration(name: "Mine", engine: .qemu, guestOS: .linux, cpuCount: 2, memoryMiB: 2048)
        config.disks = [DiskConfiguration(path: "/Users/me/Downloads/../Downloads/debian.iso", sizeGiB: 0, isRemovable: true)]
        config.network.portForwards = [PortForward(hostPort: 2222, guestPort: 22), PortForward(hostPort: 70000, guestPort: 22)]
        config.qemu.machine = "virt-9.2"
        PackageValidator.sanitize(&config, imported: false)
        #expect(config.disks.first?.path == "/Users/me/Downloads/debian.iso", "kept, without ..")
        #expect(config.network.portForwards.map(\.hostPort) == [2222], "invalid port dropped")
        #expect(config.qemu.machine == "virt-9.2")
    }

    @Test func qemuOptionsCantBeInjected() {
        var config = VMConfiguration(name: "Lab, test", engine: .qemu, guestOS: .linux, architecture: .arm64, cpuCount: 2, memoryMiB: 2048)
        config.network.macAddress = "52:54:00:00:00:01,id=x"
        config.qemu.machine = "virt,dumpdtb=/tmp/x"
        let bundle = VMBundle(url: FileManager.default.temporaryDirectory.appendingPathComponent("arg-test.orbitvm"))
        let args = QEMUArgumentBuilder(config: config, bundle: bundle, qmpSocket: "/tmp/q", dataDirectory: URL(fileURLWithPath: "/share")).build()
        #expect(args.contains("guest=Lab,, test"))
        #expect(!args.contains { $0.contains("dumpdtb") })
        #expect(!args.contains { $0.contains("mac=") }, "an invalid address is left to QEMU to pick")
        #expect(args.contains("virt"))
    }

    @Test func installerDiscsAreNeverProbed() throws {
        let folder = try makeFolder()
        let iso = folder.appendingPathComponent("installer.iso")
        try DiskImageService.createSparseRaw(at: iso, bytes: 1 << 20)
        var config = VMConfiguration(name: "CD", engine: .qemu, guestOS: .linux, architecture: .arm64, cpuCount: 2, memoryMiB: 2048)
        config.disks = [DiskConfiguration(path: iso.path, sizeGiB: 0, isReadOnly: true, interface: .usb, isRemovable: true)]
        let bundle = VMBundle(url: folder.appendingPathComponent("cd.orbitvm"))
        let args = QEMUArgumentBuilder(config: config, bundle: bundle, qmpSocket: "/tmp/q", dataDirectory: URL(fileURLWithPath: "/share")).build()
        #expect(args.contains { $0.contains("media=cdrom") && $0.contains("format=raw") })
    }

    // MARK: - Links

    @Test func linkedDiskStopsTheMachineFromStarting() throws {
        let folder = try makeFolder()
        let secret = try makeSecret(in: folder)
        let vm = try makeMachine(in: folder) { _, bundle in
            try FileManager.default.removeItem(at: bundle.url.appendingPathComponent("Disk-1.img"))
            try FileManager.default.createSymbolicLink(at: bundle.url.appendingPathComponent("Disk-1.img"), withDestinationURL: secret)
        }
        defer { Task { try? await self.library.delete(vm) } }
        #expect(PackageValidator.symbolicLinks(in: vm.bundle.url) == ["Disk-1.img"])
        #expect(throws: VMError.self) { try PackageValidator.checkFiles(of: vm.bundle) }
    }

    @Test func packageWithLinksIsNotImported() async throws {
        let folder = try makeFolder()
        let secret = try makeSecret(in: folder)
        let source = folder.appendingPathComponent("Shared.orbitvm")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("Disk-1.img"), withDestinationURL: secret)
        let name = "Shared \(UUID().uuidString.prefix(6))"
        var config = VMConfiguration(name: name, engine: .apple, guestOS: .linux, cpuCount: 2, memoryMiB: 2048)
        config.disks = [DiskConfiguration(path: "Disk-1.img", sizeGiB: 1)]
        try VMBundle(url: source).save(config)

        await #expect(throws: VMError.self) { try await self.library.importPackage(at: source) }
        #expect(!library.vms.contains { $0.config.name == name })
        #expect(!FileManager.default.fileExists(atPath: library.rootURL.appendingPathComponent("\(name).orbitvm").path), "nothing half-imported")
        #expect(FileManager.default.fileExists(atPath: secret.path))
    }

    @Test func linkedSnapshotIsRefusedAndNothingIsLost() async throws {
        let folder = try makeFolder()
        let secret = try makeSecret(in: folder)
        let vm = try makeMachine(in: folder)
        defer { Task { try? await self.library.delete(vm) } }
        let snapshot = try await SnapshotStore.create(named: "Before", for: vm)
        let cloned = SnapshotStore.directory(for: snapshot, in: vm.bundle).appendingPathComponent("Disk-1.img")
        try FileManager.default.removeItem(at: cloned)
        try FileManager.default.createSymbolicLink(at: cloned, withDestinationURL: secret)
        try Data(repeating: 9, count: 4096).write(to: vm.bundle.savedStateURL)

        await #expect(throws: VMError.self) { try await SnapshotStore.restore(snapshot, for: vm) }
        #expect(FileManager.default.fileExists(atPath: vm.bundle.savedStateURL.path), "a refused restore keeps the saved session")
        let disk = try String(contentsOf: vm.bundle.url.appendingPathComponent("Disk-1.img"), encoding: .utf8)
        #expect(disk != "private")
    }

    // MARK: - Ejecting

    @Test func ejectNeverDeletesFilesOutsideThePackage() throws {
        let folder = try makeFolder()
        let secret = try makeSecret(in: folder)
        let vm = try makeMachine(in: folder) { config, bundle in
            // looks like it's inside the package, but ".." leaves it
            let sneaky = bundle.url.path + "/../" + secret.lastPathComponent
            config.disks.append(DiskConfiguration(path: sneaky, sizeGiB: 0, isReadOnly: true, interface: .usb, isRemovable: true))
        }
        defer { Task { try? await self.library.delete(vm) } }
        vm.ejectInstaller()
        #expect(vm.config.installerMedia == nil)
        #expect(FileManager.default.fileExists(atPath: secret.path))
    }

    // MARK: - Disk images

    /// A minimal QCOW2 header: version, and optionally a backing file or an external data file.
    private func qcow2(at url: URL, version: UInt32 = 3, backingOffset: UInt64 = 0, incompatible: UInt64 = 0) throws {
        var header = Data([0x51, 0x46, 0x49, 0xFB])
        func be<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.bigEndian) { header.append(contentsOf: $0) } }
        be(version)
        be(backingOffset)
        header.append(Data(count: 72 - header.count))
        be(incompatible)
        header.append(Data(count: 512 - header.count))
        try header.write(to: url)
    }

    @Test func qcow2ThatNamesOtherFilesIsRefused() throws {
        let folder = try makeFolder()
        let plain = folder.appendingPathComponent("plain.qcow2")
        try qcow2(at: plain)
        try DiskImageSafety.checkQCOW2Header(plain)

        let backed = folder.appendingPathComponent("backed.qcow2")
        try qcow2(at: backed, backingOffset: 512)
        #expect(throws: DiskImageSafety.Unsafe.self) { try DiskImageSafety.checkQCOW2Header(backed) }

        let external = folder.appendingPathComponent("external.qcow2")
        try qcow2(at: external, incompatible: 0b100)
        #expect(throws: DiskImageSafety.Unsafe.self) { try DiskImageSafety.checkQCOW2Header(external) }
    }

    @Test func refusedImageIsNeverImported() async throws {
        let folder = try makeFolder()
        let backed = folder.appendingPathComponent("backed.qcow2")
        try qcow2(at: backed, backingOffset: 512)
        let target = try makeFolder()
        await #expect(throws: DiskImageSafety.Unsafe.self) {
            _ = try await DiskImporter.importDisk(backed, format: .qcow2, into: target, id: UUID(), engine: .qemu)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func vmdkExtentsMustStayBesideIt() throws {
        let folder = try makeFolder()
        let vmdk = folder.appendingPathComponent("disk.vmdk")
        func info(_ extent: String) -> [String: Any] {
            ["format-specific": ["type": "vmdk", "data": ["extents": [["filename": extent]]]]]
        }
        try DiskImageSafety.check(info: info(folder.appendingPathComponent("disk-flat.vmdk").path), of: vmdk)
        #expect(throws: DiskImageSafety.Unsafe.self) { try DiskImageSafety.check(info: info("/Users/someone/.ssh/id_ed25519"), of: vmdk) }
        #expect(throws: DiskImageSafety.Unsafe.self) { try DiskImageSafety.check(info: ["backing-filename": "base.vmdk"], of: vmdk) }
    }

    // MARK: - Microsoft

    @Test func windowsSheetShowsOnlyMicrosoftPages() {
        #expect(MicrosoftDownload.isMicrosoftPage(URL(string: "https://www.microsoft.com/en-us/software-download/windows11arm64")!))
        #expect(!MicrosoftDownload.isMicrosoftPage(URL(string: "http://www.microsoft.com/")!))
        #expect(!MicrosoftDownload.isMicrosoftPage(URL(string: "https://microsoft.com.example.net/")!))
        #expect(!MicrosoftDownload.isMicrosoftPage(URL(string: "https://evilmicrosoft.com/")!))
    }
}

/// Parallels-style SmartGuard: snapshots on a schedule, the newest few kept.
@Suite(.serialized)
@MainActor
struct AutomaticSnapshotTests {
    let library = VMLibrary.shared

    @Test func takesOnScheduleAndKeepsTheNewest() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-auto-snap-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundle = try library.makeBundle(named: "Auto-\(UUID().uuidString.prefix(6))", in: folder)
        try DiskImageService.createSparseRaw(at: bundle.url.appendingPathComponent("Disk-1.img"), bytes: 16 << 20)
        var config = VMConfiguration(name: "Auto", engine: .apple, guestOS: .linux, cpuCount: 2, memoryMiB: 2048)
        config.disks = [DiskConfiguration(path: "Disk-1.img", sizeGiB: 1)]
        config.automaticSnapshots = .daily
        let vm = try library.register(bundle: bundle, config: config)
        defer { Task { try? await library.delete(vm) } }
        let manual = try await SnapshotStore.create(named: "Mine", for: vm)

        var now = Date()
        #expect(try await SnapshotStore.takeAutomaticIfDue(for: vm, now: now))
        #expect(try await !SnapshotStore.takeAutomaticIfDue(for: vm, now: now.addingTimeInterval(3600)), "not due yet")
        for _ in 0..<4 {
            now += 25 * 3600
            // creation dates come from the clock; keep them apart
            try await Task.sleep(for: .milliseconds(10))
            #expect(try await SnapshotStore.takeAutomaticIfDue(for: vm, now: now))
        }
        let all = SnapshotStore.list(for: vm.bundle)
        #expect(all.filter { $0.isAutomatic == true }.count == AutomaticSnapshots.keep)
        #expect(all.contains { $0.id == manual.id }, "snapshots you take are never pruned")

        vm.config.automaticSnapshots = .off
        #expect(try await !SnapshotStore.takeAutomaticIfDue(for: vm, now: now.addingTimeInterval(30 * 86400)))
    }

    @Test func olderSnapshotsStillLoad() throws {
        let json = #"{"id":"6F0C4F6B-6C3A-4B53-9B57-0B5D1E2A1C11","name":"Old","createdAt":"2026-01-01T00:00:00Z","includesMemory":false,"files":["Disk-1.img"]}"#
        let snapshot = try JSONDecoder.orbit.decode(VMSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.isAutomatic == nil)
    }

    @Test func newSettingsDefaultOffForOlderMachines() throws {
        let json = #"{"name":"Old","engine":"apple","guestOS":"linux","cpuCount":2,"memoryMiB":2048}"#
        let config = try JSONDecoder.orbit.decode(VMConfiguration.self, from: Data(json.utf8))
        #expect(config.automaticSnapshots == .off)
        #expect(!config.startWithOrbit)
    }
}
