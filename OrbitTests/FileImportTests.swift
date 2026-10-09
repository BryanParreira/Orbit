import Foundation
import Testing
@testable import Orbit

/// Files users bring from elsewhere: detection by content, routing and conversion.
@Suite(.serialized)
final class FileImportTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // a class suite gets a fresh instance per test and tears it down after, so nothing is left behind
    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Helpers

    @discardableResult
    private func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        // a semaphore instead of waitUntilExit(), which can hang off the main run loop
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        try p.run()
        guard done.wait(timeout: .now() + 120) == .success else {
            p.terminate()
            return -1
        }
        return p.terminationStatus
    }

    private func makeISO(_ name: String) throws -> URL {
        let src = dir.appendingPathComponent("iso-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "hello".write(to: src.appendingPathComponent("README.TXT"), atomically: true, encoding: .utf8)
        let out = dir.appendingPathComponent(name)
        try #require(try run("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-o", out.path, src.path]) == 0)
        return out
    }

    private func makeRaw(_ name: String, bytes: Int64) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try DiskImageService.createSparseRaw(at: url, bytes: bytes)
        return url
    }

    private var qemuImg: String? {
        guard let url = HostInfo.qemuImg(), FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url.path
    }

    private func makeQemuImage(_ format: String, ext: String) throws -> URL? {
        guard let qemuImg else { return nil }
        let url = dir.appendingPathComponent("disk.\(ext)")
        try #require(try run(qemuImg, ["create", "-f", format, url.path, "2G"]) == 0)
        return url
    }

    // MARK: Detection

    @Test func detectsISOByContent() throws {
        let iso = try makeISO("installer.iso")
        #expect(FileInspector.inspect(iso) == .iso)
        // the name doesn't matter, the content does
        let renamed = dir.appendingPathComponent("installer.bin")
        try FileManager.default.copyItem(at: iso, to: renamed)
        #expect(FileInspector.inspect(renamed) == .iso)
    }

    @Test func detectsIPSWAndRejectsPlainZip() throws {
        let payload = dir.appendingPathComponent("payload.txt")
        try "x".write(to: payload, atomically: true, encoding: .utf8)
        let zip = dir.appendingPathComponent("archive.zip")
        try #require(try run("/usr/bin/zip", ["-j", "-q", zip.path, payload.path]) == 0)
        let ipsw = dir.appendingPathComponent("UniversalMac_Restore.ipsw")
        try FileManager.default.copyItem(at: zip, to: ipsw)
        #expect(FileInspector.inspect(ipsw) == .ipsw)
        guard case .unsupported(let reason) = FileInspector.inspect(zip) else {
            Issue.record("zip should be rejected")
            return
        }
        #expect(reason.contains("ZIP"))
    }

    @Test func acceptsRawDMGAndRejectsCompressedDMG() throws {
        let raw = dir.appendingPathComponent("raw.dmg")
        try #require(try run("/usr/bin/hdiutil", ["create", "-size", "2m", "-fs", "HFS+", "-volname", "T", raw.path]) == 0)
        #expect(FileInspector.inspect(raw) == .diskImage(.raw))

        let dmg = dir.appendingPathComponent("compressed.dmg")
        try #require(try run("/usr/bin/hdiutil", ["convert", raw.path, "-format", "UDZO", "-o", dmg.path]) == 0)
        guard case .unsupported(let reason) = FileInspector.inspect(dmg) else {
            Issue.record("dmg should be rejected")
            return
        }
        #expect(reason.contains("hdiutil convert"))
    }

    @Test func detectsRawDisksAndRejectsJunk() throws {
        #expect(FileInspector.inspect(try makeRaw("disk.img", bytes: 8 << 20)) == .diskImage(.raw))
        let tiny = dir.appendingPathComponent("tiny.img")
        try Data(repeating: 1, count: 1000).write(to: tiny)
        #expect(FileInspector.inspect(tiny).isUnsupported)
        let text = dir.appendingPathComponent("notes.txt")
        try "not a disk".write(to: text, atomically: true, encoding: .utf8)
        #expect(FileInspector.inspect(text).isUnsupported)
        let empty = dir.appendingPathComponent("empty.iso")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        #expect(FileInspector.inspect(empty).isUnsupported)
        #expect(FileInspector.inspect(dir.appendingPathComponent("missing.iso")).isUnsupported)
    }

    @Test func detectsPackagesAndRejectsPlainFolders() throws {
        let orbit = dir.appendingPathComponent("My VM.orbitvm")
        try FileManager.default.createDirectory(at: orbit, withIntermediateDirectories: true)
        try "{}".write(to: orbit.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        #expect(FileInspector.inspect(orbit) == .orbitPackage)

        let utm = dir.appendingPathComponent("Old.utm")
        try FileManager.default.createDirectory(at: utm, withIntermediateDirectories: true)
        try "<plist/>".write(to: utm.appendingPathComponent("config.plist"), atomically: true, encoding: .utf8)
        #expect(FileInspector.inspect(utm) == .utmPackage)

        let folder = dir.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(FileInspector.inspect(folder).isUnsupported)
    }

    @Test func detectsASIF() async throws {
        let id = UUID()
        let name = try await DiskImageService.create(in: dir, id: id, sizeGiB: 1, engine: .apple)
        #expect(name.hasSuffix(".asif"))
        #expect(FileInspector.inspect(dir.appendingPathComponent(name)) == .diskImage(.asif))
    }

    @Test(arguments: [("qcow2", "qcow2", DiskFormat.qcow2), ("vmdk", "vmdk", .vmdk), ("vdi", "vdi", .vdi),
                      ("vhdx", "vhdx", .vhdx), ("vpc", "vhd", .vhd)])
    func detectsForeignFormats(qemuFormat: String, ext: String, expected: DiskFormat) throws {
        guard let url = try makeQemuImage(qemuFormat, ext: ext) else { return } // QEMU not installed
        #expect(FileInspector.inspect(url) == .diskImage(expected))
    }

    // MARK: Conversion

    @Test func clonesNativeDisksUnchanged() async throws {
        let source = try makeRaw("source.img", bytes: 64 << 20)
        let name = try await DiskImporter.importDisk(source, format: .raw, into: dir, id: UUID(), engine: .apple)
        let copy = dir.appendingPathComponent(name)
        #expect(name.hasSuffix(".img"))
        #expect(try copy.resourceValues(forKeys: [.fileSizeKey]).fileSize == 64 << 20)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func convertsForeignDisksForEachEngine() async throws {
        guard let vmdk = try makeQemuImage("vmdk", ext: "vmdk") else { return }
        let forApple = try await DiskImporter.importDisk(vmdk, format: .vmdk, into: dir, id: UUID(), engine: .apple)
        #expect(forApple.hasSuffix(".img"))
        #expect(FileInspector.inspect(dir.appendingPathComponent(forApple)) == .diskImage(.raw))
        #expect(await FileInspector.virtualSizeGiB(of: dir.appendingPathComponent(forApple), format: .raw) == 2)

        let forQEMU = try await DiskImporter.importDisk(vmdk, format: .vmdk, into: dir, id: UUID(), engine: .qemu)
        #expect(forQEMU.hasSuffix(".qcow2"))
        #expect(FileInspector.inspect(dir.appendingPathComponent(forQEMU)) == .diskImage(.qcow2))
        #expect(await FileInspector.virtualSizeGiB(of: dir.appendingPathComponent(forQEMU), format: .qcow2) == 2)
    }

    @Test func asifReportsItsVirtualSizeAndImportsIntoQEMU() async throws {
        let name = try await DiskImageService.create(in: dir, id: UUID(), sizeGiB: 3, engine: .apple)
        let asif = dir.appendingPathComponent(name)
        // the file itself is a few MB; the disk it describes is 3 GB
        #expect(await FileInspector.virtualSizeGiB(of: asif, format: .asif) == 3)
        #expect(!DiskFormat.asif.needsQEMUImg(for: .qemu))
        let imported = try await DiskImporter.importDisk(asif, format: .asif, into: dir, id: UUID(), engine: .qemu)
        #expect(imported.hasSuffix(".img"))
        #expect(FileInspector.inspect(dir.appendingPathComponent(imported)) == .diskImage(.raw))
        #expect(await FileInspector.virtualSizeGiB(of: dir.appendingPathComponent(imported), format: .raw) == 3)
    }

    @Test func conversionWithoutQEMUExplainsWhatToDo() {
        let error = DiskImporter.ImportError.needsQEMU(.vdi)
        #expect(error.localizedDescription.contains("brew install qemu"))
    }

    // MARK: Routing into the wizard

    @MainActor @Test func draftsMatchTheFile() throws {
        let library = VMLibrary.shared
        let ubuntu = try makeISO("ubuntu-26.04-desktop-arm64.iso")
        let draft = try NewVMWizard.draft(for: ubuntu, library: library)
        #expect(draft.template.id == "ubuntu")
        #expect(draft.installer == .local(ubuntu))
        #expect(draft.existingDisk == nil)

        let raw = try makeRaw("server-backup.img", bytes: 8 << 20)
        let diskDraft = try NewVMWizard.draft(for: raw, library: library)
        #expect(diskDraft.existingDisk == raw)
        #expect(diskDraft.existingDiskFormat == .raw)
        #expect(diskDraft.installer == .none)
        #expect(diskDraft.isValid)

        let text = dir.appendingPathComponent("readme.md")
        try "# hi".write(to: text, atomically: true, encoding: .utf8)
        #expect(throws: VMError.self) { try NewVMWizard.draft(for: text, library: library) }
    }
}

extension FileKind {
    var isUnsupported: Bool {
        if case .unsupported = self { true } else { false }
    }
}

@Suite(.serialized)
struct UTMImportTests {
    @MainActor @Test func importsAppleLinuxUTMPackage() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("utm-\(UUID().uuidString)")
        let utm = dir.appendingPathComponent("Ubuntu Server.utm")
        let data = utm.appendingPathComponent("Data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try DiskImageService.createSparseRaw(at: data.appendingPathComponent("disk-1.img"), bytes: 4 << 30)
        try DiskImageService.createSparseRaw(at: data.appendingPathComponent("efi_vars.fd"), bytes: 128 << 10)
        let plist: [String: Any] = [
            "Backend": "Apple",
            "ConfigurationVersion": 4,
            "Information": ["Name": "Ubuntu Server", "Notes": "from UTM"],
            "System": ["CPUCount": 3, "MemorySize": 3072,
                       "Boot": ["OperatingSystem": "Linux", "EfiVariableStoragePath": "efi_vars.fd", "UEFIBoot": true]],
            "Drive": [["ImageName": "disk-1.img", "ReadOnly": false, "Nvme": false]],
            "Network": [["Mode": "Shared", "MacAddress": "AA:BB:CC:DD:EE:01"]],
            "Display": [["WidthPixels": 1280, "HeightPixels": 800, "PixelsPerInch": 80, "DynamicResolution": true]],
            "Virtualization": ["Audio": false, "Rosetta": true, "ClipboardSharing": true],
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: utm.appendingPathComponent("config.plist"))

        let library = VMLibrary.shared
        #expect(FileInspector.inspect(utm) == .utmPackage)
        let vm = try await library.importPackage(at: utm)
        defer { try? FileManager.default.removeItem(at: vm.bundle.url); library.reload(); try? FileManager.default.removeItem(at: dir) }

        #expect(vm.config.engine == .apple)
        #expect(vm.config.guestOS == .linux)
        #expect(vm.config.cpuCount == 3)
        #expect(vm.config.memoryMiB == 3072)
        #expect(vm.config.notes == "from UTM")
        #expect(vm.config.network.macAddress == "aa:bb:cc:dd:ee:01")
        #expect(vm.config.display.widthPixels == 1280)
        #expect(vm.config.rosetta)
        #expect(!vm.config.audioOutput)
        #expect(vm.config.disks.count == 1)
        #expect(vm.config.disks[0].sizeGiB == 4)
        #expect(FileManager.default.fileExists(atPath: vm.bundle.diskURL(for: vm.config.disks[0]).path))
        #expect(FileManager.default.fileExists(atPath: vm.bundle.efiVariablesURL.path))
        // original untouched
        #expect(FileManager.default.fileExists(atPath: data.appendingPathComponent("disk-1.img").path))
    }
}
