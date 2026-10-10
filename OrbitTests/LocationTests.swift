import Foundation
import Testing
@testable import Orbit

/// Machines kept where the user chose: created there, found again, moved, and removed completely.
@Suite(.serialized)
@MainActor
final class LocationTests {
    let library = VMLibrary.shared
    private var folders: [URL] = []

    deinit {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
    }

    /// An empty folder outside the library, on the temp volume or next to the project (often another drive).
    private func makeFolder(nearProject: Bool = false) throws -> URL {
        let base = nearProject
            ? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build")
            : FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("orbit-location-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    /// A machine in `folder` whose downloaded installer lives inside its package.
    private func makeMachine(in folder: URL) throws -> VMInstance {
        try library.validateLocation(folder)
        let bundle = try library.makeBundle(named: "Elsewhere-\(UUID().uuidString.prefix(6))", in: folder)
        try DiskImageService.createSparseRaw(at: bundle.url.appendingPathComponent("Disk-1.img"), bytes: 256 << 20)
        let installer = bundle.url.appendingPathComponent("installer.iso")
        try DiskImageService.createSparseRaw(at: installer, bytes: 8 << 20)
        try "hash".write(to: VMLibrary.verificationMarker(for: installer), atomically: true, encoding: .utf8)
        var config = VMConfiguration(name: "Elsewhere", engine: .apple, guestOS: .linux, cpuCount: 2, memoryMiB: 2048)
        config.disks = [DiskConfiguration(path: "Disk-1.img", sizeGiB: 1),
                        DiskConfiguration(path: installer.path, sizeGiB: 0, isReadOnly: true, interface: .usb, isRemovable: true)]
        return try library.register(bundle: bundle, config: config)
    }

    @Test func machineOutsideTheLibraryIsFoundAgain() async throws {
        let vm = try makeMachine(in: try makeFolder())
        #expect(library.isOutsideLibrary(vm))
        library.reload()
        #expect(library.vms.filter { $0.id == vm.id }.count == 1, "listed once, the same live instance")
        #expect(library.vm(with: vm.id) === vm)
        try await library.delete(vm)
        library.reload()
        #expect(library.vm(with: vm.id) == nil)
        #expect(!library.isUnreachable(vm.bundle.url), "deleting stops tracking it")
    }

    @Test func disconnectedMachineIsReportedAndCanBeForgotten() async throws {
        let vm = try makeMachine(in: try makeFolder())
        let url = vm.bundle.url
        // as if its drive were unplugged
        let parked = url.deletingLastPathComponent().appendingPathComponent("parked")
        try FileManager.default.moveItem(at: url, to: parked)
        library.reload()
        #expect(library.isUnreachable(url))
        try FileManager.default.moveItem(at: parked, to: url)
        library.reload()
        #expect(!library.isUnreachable(url), "back when the drive returns")
        #expect(library.vms.contains { $0.bundle.url.standardizedFileURL.path == url.standardizedFileURL.path })

        try FileManager.default.moveItem(at: url, to: parked)
        library.reload()
        library.forgetUnreachable(url)
        library.reload()
        #expect(!library.isUnreachable(url))
        #expect(FileManager.default.fileExists(atPath: parked.path), "forgetting never deletes files")
    }

    @Test(arguments: [false, true])
    func moveTakesEverythingAlong(acrossDrives: Bool) async throws {
        let source = try makeFolder()
        let target = try makeFolder(nearProject: acrossDrives)
        let vm = try makeMachine(in: source)
        let oldURL = vm.bundle.url

        let moved = try await library.move(vm, to: target)
        #expect(moved.id == vm.id)
        #expect(moved.bundle.url.deletingLastPathComponent().standardizedFileURL.path == target.standardizedFileURL.path)
        #expect(!FileManager.default.fileExists(atPath: oldURL.path), "nothing left at the old location")
        #expect(library.vm(with: vm.id) === moved)
        // the downloaded installer inside the package follows it
        let installer = try #require(moved.config.installerMedia)
        #expect(installer.path.hasPrefix(moved.bundle.url.standardizedFileURL.path + "/"))
        #expect(FileManager.default.fileExists(atPath: installer.path))
        // a sparse disk stays sparse, even across drives
        let disk = moved.bundle.url.appendingPathComponent("Disk-1.img")
        #expect(DiskImageService.allocatedBytes(at: disk) < 64 << 20)
        #expect(try VMBundle(url: moved.bundle.url).loadConfiguration().installerMedia?.path == installer.path, "saved")

        library.reload()
        #expect(library.vm(with: vm.id) === moved, "found at its new location")

        // and back into the library
        let home = try await library.move(moved, to: library.rootURL)
        #expect(!library.isOutsideLibrary(home))
        try await library.delete(home)
    }

    @Test func ejectingFreesAnInstallerInsideThePackage() async throws {
        let vm = try makeMachine(in: try makeFolder())
        let installer = try #require(vm.config.installerMedia)
        vm.ejectInstaller()
        #expect(vm.config.installerMedia == nil)
        #expect(!FileManager.default.fileExists(atPath: installer.path))
        #expect(!FileManager.default.fileExists(atPath: VMLibrary.verificationMarker(for: URL(fileURLWithPath: installer.path)).path))
        try await library.delete(vm)
    }

    @Test func duplicateStaysBesideTheOriginal() async throws {
        let folder = try makeFolder()
        let vm = try makeMachine(in: folder)
        let copy = try await library.duplicate(vm)
        #expect(copy.bundle.url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path)
        let installer = try #require(copy.config.installerMedia)
        #expect(installer.path.hasPrefix(copy.bundle.url.standardizedFileURL.path + "/"), "copy uses its own installer")
        try await library.delete(vm)
        #expect(FileManager.default.fileExists(atPath: installer.path))
        try await library.delete(copy)
    }

    @Test func refusesFoldersInsideMachines() throws {
        let vm = try makeMachine(in: try makeFolder())
        defer { Task { try? await library.delete(vm) } }
        #expect(throws: VMError.self) { try library.validateLocation(vm.bundle.url) }
        #expect(throws: VMError.self) { try library.validateLocation(URL(fileURLWithPath: "/nonexistent-\(UUID())")) }
    }
}
