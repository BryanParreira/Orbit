import Foundation
import Testing
@testable import Orbit

/// Deleting a machine must remove everything it used on this Mac, and nothing else.
@Suite(.serialized)
@MainActor
struct DeletionTests {
    let library = VMLibrary.shared

    /// A machine with every kind of file a real one accumulates.
    private func makeMachine(_ name: String, installer: URL?) throws -> VMInstance {
        let bundle = try library.makeBundle(named: "\(name)-\(UUID().uuidString.prefix(6))")
        let fm = FileManager.default
        try DiskImageService.createSparseRaw(at: bundle.url.appendingPathComponent("Disk-1.img"), bytes: 64 << 20)
        try Data(repeating: 7, count: 4096).write(to: bundle.savedStateURL)
        try Data(repeating: 1, count: 1024).write(to: bundle.screenshotURL)
        try fm.createDirectory(at: bundle.snapshotsURL.appendingPathComponent("snap"), withIntermediateDirectories: true)
        try Data(repeating: 2, count: 1024).write(to: bundle.snapshotsURL.appendingPathComponent("snap/Disk-1.img"))
        var config = VMConfiguration(name: name, engine: .apple, guestOS: .linux, cpuCount: 2, memoryMiB: 2048)
        config.disks = [DiskConfiguration(path: "Disk-1.img", sizeGiB: 1)]
        if let installer {
            config.disks.append(DiskConfiguration(path: installer.path, sizeGiB: 0, isReadOnly: true, interface: .usb, isRemovable: true))
        }
        return try library.register(bundle: bundle, config: config)
    }

    private func makeDownloadedInstaller() throws -> URL {
        try FileManager.default.createDirectory(at: library.installersURL, withIntermediateDirectories: true)
        let url = library.installersURL.appendingPathComponent("test-\(UUID().uuidString.prefix(8)).iso")
        try DiskImageService.createSparseRaw(at: url, bytes: 8 << 20)
        try "hash".write(to: VMLibrary.verificationMarker(for: url), atomically: true, encoding: .utf8)
        return url
    }

    @Test func deletingRemovesEverythingTheMachineUsed() async throws {
        let installer = try makeDownloadedInstaller()
        let vm = try makeMachine("DeleteMe", installer: installer)
        let socketDir = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-\(vm.id.uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: socketDir, withIntermediateDirectories: true)

        let plan = await library.deletionPlan(for: vm)
        #expect(plan.installer == installer)
        #expect(plan.packageBytes > 0)

        try await library.delete(vm, permanently: true, removeInstaller: true)
        #expect(!FileManager.default.fileExists(atPath: vm.bundle.url.path), "package")
        #expect(!FileManager.default.fileExists(atPath: installer.path), "downloaded installer")
        #expect(!FileManager.default.fileExists(atPath: VMLibrary.verificationMarker(for: installer).path), "checksum record")
        #expect(!FileManager.default.fileExists(atPath: socketDir.path), "temporary files")
        #expect(!library.vms.contains(vm))
    }

    @Test func keepsInstallersThatAreSharedOrTheUsersOwn() async throws {
        // shared with another machine: kept
        let shared = try makeDownloadedInstaller()
        let first = try makeMachine("SharedA", installer: shared)
        let second = try makeMachine("SharedB", installer: shared)
        #expect(await library.deletionPlan(for: first).installer == nil)
        try await library.delete(first)
        #expect(FileManager.default.fileExists(atPath: shared.path))

        // the user's own image outside Orbit's folders: never deleted
        let own = FileManager.default.temporaryDirectory.appendingPathComponent("my-own-\(UUID().uuidString.prefix(6)).iso")
        try DiskImageService.createSparseRaw(at: own, bytes: 8 << 20)
        defer { try? FileManager.default.removeItem(at: own) }
        let third = try makeMachine("OwnISO", installer: own)
        try await library.delete(third)
        #expect(FileManager.default.fileExists(atPath: own.path))

        // last user of the shared one: now it goes too
        try await library.delete(second)
        #expect(!FileManager.default.fileExists(atPath: shared.path))
    }

    @Test func leftoversListOnlyOrbitsOwnDebris() async throws {
        let keep = try makeMachine("Healthy", installer: nil)
        defer { Task { try? await library.delete(keep) } }
        let broken = library.rootURL.appendingPathComponent("Broken-\(UUID().uuidString.prefix(6)).orbitvm")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 2048).write(to: broken.appendingPathComponent("Disk.img"))

        let found = await library.leftovers()
        #expect(found.contains { $0.url.standardizedFileURL.path == broken.standardizedFileURL.path })
        #expect(!found.contains { $0.url.standardizedFileURL.path == keep.bundle.url.standardizedFileURL.path }, "a working machine is never a leftover")
        library.remove(found.filter { $0.url.standardizedFileURL.path == broken.standardizedFileURL.path })
        #expect(!FileManager.default.fileExists(atPath: broken.path))
    }

    @Test func temporaryPatternsAreOrbitsOnly() {
        #expect(VMLibrary.isOrbitTemporary("orbit-disposable-1234"))
        #expect(VMLibrary.isOrbitTemporary("orbit-A1B2C3D4"))
        #expect(!VMLibrary.isOrbitTemporary("orbit-something-else"))
        #expect(!VMLibrary.isOrbitTemporary("orbital-app-cache"))
    }
}
