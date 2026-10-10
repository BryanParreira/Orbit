import Foundation
import Testing
@testable import Orbit

/// The drivers disc that lets Windows on ARM go online during setup.
@Suite(.serialized)
@MainActor
final class WindowsDriversTests {
    private var folders: [URL] = []

    deinit {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-wd-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    /// The pinned virtio-win ISO, when a copy is in build/fixtures (it's 900 MB, so not in the repo).
    private var fixture: URL? {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/fixtures/virtio-win-\(WindowsDrivers.version).iso")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @Test func answerFileIsValidAndOnlyAddsSteps() throws {
        let xml = try XMLDocument(data: Data(WindowsDrivers.answerFile.utf8))
        let passes = try xml.nodes(forXPath: "//*[local-name()='settings']/@pass").compactMap(\.stringValue)
        #expect(passes == ["windowsPE", "specialize"], "no oobeSystem pass: every setup page still shows")
        let architectures = try xml.nodes(forXPath: "//*[local-name()='component']/@processorArchitecture").compactMap(\.stringValue)
        #expect(!architectures.isEmpty && architectures.allSatisfy { $0 == "arm64" })
        let commands = try xml.nodes(forXPath: "//*[local-name()='Path']").compactMap(\.stringValue)
        #expect(commands.contains { $0.contains(#"\OrbitDrivers\install.cmd"#) })
        // nothing that partitions disks, sets accounts or product keys
        for element in ["DiskConfiguration", "UserAccounts", "ProductKey", "AutoLogon"] {
            #expect(try xml.nodes(forXPath: "//*[local-name()='\(element)']").isEmpty, "\(element)")
        }
        #expect(WindowsDrivers.installScript.contains("\r\n"), "Windows batch files need CRLF")
    }

    @Test func buildsTheDiscFromThePinnedISO() async throws {
        guard let fixture else { return }
        #expect(try await ChecksumVerifier.sha256(of: fixture) == WindowsDrivers.sha256)
        let disc = try makeFolder().appendingPathComponent("drivers.iso")
        try await WindowsDrivers.buildDisc(from: fixture, to: disc)

        let listing = try await DiskImageService.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-tf", disc.path])
        let files = Set(listing.split(whereSeparator: \.isNewline).map { String($0).replacingOccurrences(of: "./", with: "") })
        for required in ["autounattend.xml", "OrbitDrivers/install.cmd", "OrbitDrivers/NetKVM/netkvm.inf",
                         "OrbitDrivers/NetKVM/netkvm.sys", "OrbitDrivers/NetKVM/netkvm.cat", "OrbitDrivers/Balloon/balloon.inf",
                         "OrbitDrivers/viorng/viorng.inf"] {
            #expect(files.contains(required), "\(required)")
        }
        #expect(!files.contains { $0.hasSuffix(".pdb") }, "no debug symbols")
        #expect(!files.contains { $0.contains("amd64") || $0.contains("2k25") }, "Windows 11 ARM64 drivers only")
        #expect(DiskImageService.allocatedBytes(at: disc) < 32 << 20)
        // the network driver matches QEMU's virtio-net-pci
        let inf = try await DiskImageService.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xOf", disc.path, "OrbitDrivers/NetKVM/netkvm.inf"])
        #expect(inf.contains(#"PCI\VEN_1AF4&DEV_1000"#) && inf.contains("NTARM64"))
        // no temporary files left behind
        let temp = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
        #expect(!temp.contains { $0.hasPrefix("orbit-drivers-") })
    }

    @Test func refusesADownloadThatIsntThePinnedBuild() async throws {
        let package = try makeFolder()
        let cache = try makeFolder()
        let fake = try makeFolder().appendingPathComponent("virtio-win.iso")
        await #expect(throws: ChecksumVerifier.Failure.self) {
            try await WindowsDrivers.prepareDisc(in: package, cache: cache) { _ in
                try Data("not the drivers".utf8).write(to: fake)
                return fake
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fake.path), "the bad download is deleted")
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty, "nothing cached")
        #expect(try FileManager.default.contentsOfDirectory(atPath: package.path).isEmpty, "nothing attached")
    }

    @Test func reusesTheCachedDiscWithoutDownloading() async throws {
        let package = try makeFolder()
        let cache = try makeFolder()
        try Data("disc".utf8).write(to: cache.appendingPathComponent("Orbit Windows Drivers \(WindowsDrivers.version).iso"))
        let disc = try await WindowsDrivers.prepareDisc(in: package, cache: cache) { _ in
            Issue.record("downloaded although a disc was cached")
            throw CancellationError()
        }
        #expect(disc.lastPathComponent == WindowsDrivers.discName)
        #expect(try String(contentsOf: disc, encoding: .utf8) == "disc")
    }

    @Test func installerAndDriversDiscStayApart() throws {
        let bundle = VMBundle(url: try makeFolder())
        var config = VMConfiguration(name: "Windows", engine: .qemu, guestOS: .windows, architecture: .arm64, cpuCount: 2, memoryMiB: 4096)
        config.disks = [DiskConfiguration(path: "disk.qcow2", sizeGiB: 64, interface: .nvme)]
        let vm = VMInstance(bundle: bundle, config: config)
        let isos = try makeFolder()
        let windows = isos.appendingPathComponent("Win11_ARM64.iso")
        try Data("iso".utf8).write(to: windows)
        let drivers = bundle.url.appendingPathComponent(WindowsDrivers.discName)
        try Data("disc".utf8).write(to: drivers)

        vm.attachInstaller(windows)
        vm.attachDriversDisc(drivers)
        #expect(vm.config.installerMedia?.path == windows.path)
        #expect(vm.config.driversDisc?.path == drivers.path)

        // a different installer keeps the drivers
        let other = isos.appendingPathComponent("Win11_ARM64_other.iso")
        try Data("iso".utf8).write(to: other)
        vm.attachInstaller(other)
        #expect(vm.config.installerMedia?.path == other.path)
        #expect(vm.config.driversDisc != nil)
        #expect(FileManager.default.fileExists(atPath: drivers.path))

        // only the installer boots
        let args = QEMUArgumentBuilder(config: vm.config, bundle: bundle, qmpSocket: "/tmp/q", dataDirectory: bundle.url).build()
        #expect(args.filter { $0.contains("bootindex=0") }.count == 1)
        #expect(args.filter { $0.contains("media=cdrom") }.count == 2, "both discs attached")
        #expect(args.contains { $0.contains("bootindex=0") && $0.contains("drive") } )

        // ejecting after setup removes both, and frees the disc's space
        vm.ejectInstaller()
        #expect(vm.config.installerMedia == nil && vm.config.driversDisc == nil)
        #expect(!FileManager.default.fileExists(atPath: drivers.path))
    }
}

/// Only Microsoft's own HTTPS servers can hand Orbit a Windows image.
struct MicrosoftDownloadTests {
    @Test(arguments: [
        ("https://software.download.prss.microsoft.com/dbazure/Win11_26H2_English_Arm64.iso?t=abc&e=1&h=x", true),
        ("https://www.microsoft.com/a/Win11.iso", true),
        ("http://software.download.prss.microsoft.com/Win11.iso", false),
        ("https://microsoft.com.evil.example/Win11.iso", false),
        ("https://evilmicrosoft.com/Win11.iso", false),
        ("https://software.download.prss.microsoft.com/Win11.exe", false),
    ])
    func acceptsOnlyMicrosoftImages(_ link: String, _ expected: Bool) {
        #expect(MicrosoftDownload.accepts(URL(string: link)!) == expected)
    }

    @Test func fileNameIgnoresTheSignedQuery() {
        let download = MicrosoftDownload(url: URL(string: "https://software.download.prss.microsoft.com/dbazure/Win11_26H2_English_Arm64.iso?t=abc")!, hashes: [])
        #expect(download.fileName == "Win11_26H2_English_Arm64.iso")
    }
}
