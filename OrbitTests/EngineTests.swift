import Foundation
import Testing
import Virtualization
@testable import Orbit

struct EngineTests {
    private func bundle() -> VMBundle {
        VMBundle(url: FileManager.default.temporaryDirectory.appendingPathComponent("arg-test.orbitvm"))
    }

    @Test func nativeGuestsUseHVF() {
        var config = VMConfiguration(name: "Win", engine: .qemu, guestOS: .windows, architecture: .arm64, cpuCount: 4, memoryMiB: 8192)
        config.disks = []
        let args = QEMUArgumentBuilder(config: config, bundle: bundle(), qmpSocket: "/tmp/q", dataDirectory: URL(fileURLWithPath: "/share")).build()
        #expect(args.contains("hvf"))
        #expect(args.contains("host"))
        #expect(args.contains("ramfb"))
        #expect(args.contains("virt"))
        #expect(args.contains("unix:/tmp/q,server=on,wait=off"))
    }

    @Test func foreignGuestsUseMultiThreadedTCG() {
        var config = VMConfiguration(name: "PC", engine: .qemu, guestOS: .linux, architecture: .x86_64, cpuCount: 4, memoryMiB: 4096)
        config.qemu.tcgCacheMiB = 1024
        let args = QEMUArgumentBuilder(config: config, bundle: bundle(), qmpSocket: "/tmp/q", dataDirectory: URL(fileURLWithPath: "/share")).build()
        #expect(args.contains("tcg,thread=multi,tb-size=1024"))
        #expect(args.contains("q35"))
        #expect(!args.contains("hvf"))
    }

    @Test func portForwardsAndDiskCacheMapThrough() {
        var config = VMConfiguration(name: "S", engine: .qemu, guestOS: .linux, architecture: .arm64, cpuCount: 2, memoryMiB: 2048)
        config.network.portForwards = [PortForward(hostPort: 2222, guestPort: 22)]
        config.diskPerformance = .fast
        let args = QEMUArgumentBuilder(config: config, bundle: bundle(), qmpSocket: "/tmp/q", dataDirectory: URL(fileURLWithPath: "/share")).build()
        #expect(args.contains { $0.contains("hostfwd=tcp::2222-:22") })
    }

    @Test func configurationDecodesOlderFiles() throws {
        let json = #"{"name":"Old","engine":"apple","guestOS":"linux","cpuCount":2,"memoryMiB":2048}"#
        let config = try JSONDecoder.orbit.decode(VMConfiguration.self, from: Data(json.utf8))
        #expect(config.name == "Old")
        #expect(config.diskPerformance == .balanced)
        #expect(config.disks.isEmpty)
    }

    @Test func everyTemplateHasAMatchingLogo() {
        for template in OSTemplate.all where template.id != "emulated" {
            #expect(template.logo != nil, "\(template.id) has no logo")
        }
    }

    @Test func smartDefaultsStayInsideHostLimits() {
        for os in GuestOS.allCases {
            let memory = HostInfo.recommendedMemoryMiB(for: os)
            #expect(memory <= HostInfo.maxMemoryMiB)
            #expect(memory >= 2048)
        }
        #expect(HostInfo.recommendedCPUs <= HostInfo.maxCPUs)
    }
}

/// Launches real QEMU with the exact arguments Orbit generates, headless and paused,
/// to catch device and property errors that only show up when the machine is built.
@Suite(.serialized)
struct QEMULaunchTests {
    struct Scenario: CustomStringConvertible {
        let name: String
        let os: GuestOS
        let arch: GuestArchitecture
        let interface: DiskInterface
        var tpm = false
        var description: String { name }
    }

    static let scenarios = [
        Scenario(name: "Windows 11 ARM", os: .windows, arch: .arm64, interface: .nvme, tpm: true),
        Scenario(name: "Linux ARM", os: .linux, arch: .arm64, interface: .virtio),
        Scenario(name: "Linux x86-64", os: .linux, arch: .x86_64, interface: .virtio),
        Scenario(name: "Other x86-64", os: .other, arch: .x86_64, interface: .nvme),
    ]

    @Test(arguments: scenarios)
    func launches(_ scenario: Scenario) async throws {
        guard let binary = HostInfo.qemuBinary(for: scenario.arch), let data = HostInfo.qemuDataDirectory() else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ql-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = VMBundle(url: dir)

        try DiskImageService.createSparseRaw(at: dir.appendingPathComponent("disk.img"), bytes: 1 << 30)
        try DiskImageService.createSparseRaw(at: dir.appendingPathComponent("installer.iso"), bytes: 4 << 20)
        var config = VMConfiguration(name: scenario.name, engine: .qemu, guestOS: scenario.os, architecture: scenario.arch, cpuCount: 2, memoryMiB: 1024)
        config.disks = [
            DiskConfiguration(path: "disk.img", sizeGiB: 1, interface: scenario.interface),
            DiskConfiguration(path: dir.appendingPathComponent("installer.iso").path, sizeGiB: 0, isReadOnly: true, interface: .usb, isRemovable: true),
        ]
        if scenario.os == .windows {
            // the drivers disc rides along with the installer
            try DiskImageService.createSparseRaw(at: dir.appendingPathComponent(WindowsDrivers.discName), bytes: 4 << 20)
            config.disks.append(DiskConfiguration(path: dir.appendingPathComponent(WindowsDrivers.discName).path, sizeGiB: 0,
                                                  isReadOnly: true, interface: .usb, isRemovable: true))
        }
        config.network.portForwards = [PortForward(hostPort: 0, guestPort: 22)]
        config.sharedFolders = [SharedFolder(path: dir.path)]

        var builder = QEMUArgumentBuilder(config: config, bundle: bundle, qmpSocket: dir.appendingPathComponent("q").path, dataDirectory: data)
        // a real emulated TPM, as Windows 11 gets (the socket path must stay under 104 bytes)
        var tpm: Process?
        if scenario.tpm, let swtpm = HostInfo.swtpm {
            let socket = dir.appendingPathComponent("tpm.sock").path
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("TPM"), withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = swtpm
            process.arguments = ["socket", "--tpm2", "--tpmstate", "dir=\(dir.appendingPathComponent("TPM").path)",
                                 "--ctrl", "type=unixio,path=\(socket)", "--terminate"]
            try process.run()
            tpm = process
            for _ in 0..<30 where !FileManager.default.fileExists(atPath: socket) { try await Task.sleep(for: .milliseconds(100)) }
            builder.tpmSocket = socket
        }
        defer { tpm?.terminate() }
        try FileManager.default.copyItem(at: builder.firmwareVarsTemplateURL(), to: builder.efiVariablesURL)
        var args = builder.build()
        // same machine, but headless and paused
        if let i = args.firstIndex(of: "-display") { args[i + 1] = "none" }
        args.append("-S")

        let process = Process()
        process.executableURL = binary
        process.arguments = args
        // stderr to a file, never a pipe: a full pipe would block QEMU
        let log = dir.appendingPathComponent("qemu.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: log)
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        try await Task.sleep(for: .seconds(3))
        let alive = process.isRunning
        // no waitUntilExit(): it can miss the exit on a concurrency thread and hang
        if alive { process.terminate() }
        for _ in 0..<50 where process.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        let message = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        #expect(alive, "QEMU rejected the \(scenario.name) machine: \(message)")
    }
}

/// Every Apple-engine Linux configuration Orbit can produce must pass Virtualization's validator.
@Suite(.serialized)
@MainActor
struct AppleConfigurationTests {
    struct Variant: CustomStringConvertible {
        let name: String
        let apply: (inout VMConfiguration) -> Void
        var description: String { name }
    }

    static let variants: [Variant] = [
        Variant(name: "defaults") { _ in },
        Variant(name: "NVMe disk") { $0.disks[0].interface = .nvme },
        Variant(name: "USB disk") { $0.disks[0].interface = .usb },
        Variant(name: "no network, no audio") { $0.network.mode = .none; $0.audioOutput = false },
        Variant(name: "host-only network") { $0.network.mode = .hostOnly },
        Variant(name: "microphone + clipboard") { $0.audioInput = true; $0.clipboardSharing = true },
        Variant(name: "rosetta + nested + shared folder") {
            $0.rosetta = true; $0.nestedVirtualization = true
            $0.sharedFolders = [SharedFolder(path: NSTemporaryDirectory())]
        },
        Variant(name: "fast disks, fixed display") { $0.diskPerformance = .fast; $0.display.dynamicResolution = false },
        Variant(name: "safe disks, read-only data disk") {
            $0.diskPerformance = .safe
            $0.disks.append(DiskConfiguration(path: "data.img", sizeGiB: 1, isReadOnly: true))
        },
    ]

    @Test(arguments: variants)
    func validates(_ variant: Variant) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vz-\(UUID().uuidString).orbitvm")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = VMBundle(url: dir)
        try PlatformProvisioner.provisionGeneric(bundle: bundle)
        try DiskImageService.createSparseRaw(at: dir.appendingPathComponent("disk.img"), bytes: 1 << 30)
        try DiskImageService.createSparseRaw(at: dir.appendingPathComponent("data.img"), bytes: 1 << 30)
        try DiskImageService.createSparseRaw(at: dir.appendingPathComponent("installer.iso"), bytes: 4 << 20)

        var config = VMConfiguration(name: variant.name, engine: .apple, guestOS: .linux, cpuCount: 2, memoryMiB: 2048)
        config.disks = [
            DiskConfiguration(path: "disk.img", sizeGiB: 1),
            DiskConfiguration(path: dir.appendingPathComponent("installer.iso").path, sizeGiB: 0, isReadOnly: true, interface: .usb, isRemovable: true),
        ]
        variant.apply(&config)

        var builder = AppleConfigurationBuilder(config: config, bundle: bundle)
        let vz = try builder.build()
        try vz.validate()
    }

    /// Linux installers must see the machine's own disk first (vda) and the installer after it:
    /// as a USB drive the installer was "sda", listed and preselected first, and partitioning it failed.
    @Test func linuxInstallerComesAfterTheMachinesDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vz-\(UUID().uuidString).orbitvm")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = VMBundle(url: dir)
        try PlatformProvisioner.provisionGeneric(bundle: bundle)
        try DiskImageService.createSparseRaw(at: dir.appendingPathComponent("disk.img"), bytes: 1 << 30)
        try DiskImageService.createSparseRaw(at: dir.appendingPathComponent("installer.iso"), bytes: 4 << 20)
        var config = VMConfiguration(name: "order", engine: .apple, guestOS: .linux, cpuCount: 2, memoryMiB: 2048)
        // installer listed first in the settings on purpose: the order must not depend on it
        config.disks = [
            DiskConfiguration(path: dir.appendingPathComponent("installer.iso").path, sizeGiB: 0, isReadOnly: true, interface: .usb, isRemovable: true),
            DiskConfiguration(path: "disk.img", sizeGiB: 1),
        ]
        var builder = AppleConfigurationBuilder(config: config, bundle: bundle)
        let devices = try builder.build().storageDevices
        #expect(devices.count == 2)
        #expect(devices.allSatisfy { $0 is VZVirtioBlockDeviceConfiguration }, "no USB drive for Linux to list first")
        let attachments = devices.compactMap { ($0.attachment as? VZDiskImageStorageDeviceAttachment) }
        #expect(attachments.first?.url.lastPathComponent == "disk.img", "the machine's disk is vda")
        #expect(attachments.last?.isReadOnly == true, "the installer is read-only")
    }

    @Test func missingDiskFailsWithItsName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vz-\(UUID().uuidString).orbitvm")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = VMBundle(url: dir)
        try PlatformProvisioner.provisionGeneric(bundle: bundle)
        var config = VMConfiguration(name: "x", engine: .apple, guestOS: .linux, cpuCount: 2, memoryMiB: 2048)
        config.disks = [DiskConfiguration(path: "gone.img", sizeGiB: 1)]
        var builder = AppleConfigurationBuilder(config: config, bundle: bundle)
        #expect(throws: VMError.self) { try builder.build() }
    }
}

@Suite struct OnlineCatalogTests {
    /// Apple's catalog and every distro mirror must resolve to a real, downloadable image.
    @MainActor @Test func macOSRestoreImageResolves() async throws {
        let latest = try await PlatformProvisioner.latestRestoreImage()
        #expect(latest.url.pathExtension == "ipsw")
        #expect(!latest.version.isEmpty)
    }

    @Test(arguments: [ISOResolver.ubuntuDesktop, .ubuntuServer, .fedoraWorkstation, .debianNetinst, .alpineVirt,
                      .kaliInstaller, .rockyMinimal, .almaMinimal, .openSUSETumbleweed, .nixosMinimal, .freeBSD])
    func distroResolves(_ resolver: ISOResolver) async throws {
        let resolved = try await resolver.resolve()
        #expect(resolved.url.pathExtension == "iso")
        // every download must be verifiable: its checksum list has to name this exact image
        let checksum = try #require(resolved.checksumURL, "\(resolver) has no checksum source")
        let hash = try await ChecksumVerifier.expectedHash(for: resolved.url.lastPathComponent, from: checksum)
        #expect(hash.count == 64)
        var request = URLRequest(url: resolved.url)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200, "\(resolved.url)")
    }
}


struct ChecksumTests {
    @Test func parsesBothChecksumFormats() throws {
        let gnu = """
        aaaa000000000000000000000000000000000000000000000000000000000000  other.iso
        b9a08050ee522fbee7cac703b1bc48178f79eb974c962d4ed9dc1ccfdfa77fb6  kali-linux-2026.2-installer-arm64.iso
        """
        #expect(try ChecksumVerifier.expectedHash(for: "kali-linux-2026.2-installer-arm64.iso", in: gnu) == "b9a08050ee522fbee7cac703b1bc48178f79eb974c962d4ed9dc1ccfdfa77fb6")
        let bsd = "# comment\nSHA256 (Rocky-10.2-aarch64-minimal.iso) = 1D1C21199DF32F6D17EEDB4F713EE0D089B49294401A364B640FCF4FFAB45F35\n"
        #expect(try ChecksumVerifier.expectedHash(for: "Rocky-10.2-aarch64-minimal.iso", in: bsd) == "1d1c21199df32f6d17eedb4f713ee0d089b49294401a364b640fcf4ffab45f35")
        #expect(throws: (any Error).self) { try ChecksumVerifier.expectedHash(for: "missing.iso", in: gnu) }
    }

    @Test func tamperedDownloadIsDeleted() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sum-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let iso = dir.appendingPathComponent("image.iso")
        try Data("real contents".utf8).write(to: iso)
        let good = try await ChecksumVerifier.sha256(of: iso)
        // a list that matches: verifies and leaves the file
        let sums = dir.appendingPathComponent("SHA256SUMS")
        try "\(good)  image.iso\n".write(to: sums, atomically: true, encoding: .utf8)
        try await ChecksumVerifier.verify(iso, against: sums)
        #expect(FileManager.default.fileExists(atPath: iso.path))
        // the file changes after verification: the old marker no longer covers it
        try Data("altered".utf8).write(to: iso)
        try String(repeating: "0", count: 64).appending("  image.iso\n").write(to: sums, atomically: true, encoding: .utf8)
        await #expect(throws: ChecksumVerifier.Failure.self) { try await ChecksumVerifier.verify(iso, against: sums) }
        #expect(!FileManager.default.fileExists(atPath: iso.path))
    }
}

struct PackageSafetyTests {
    @Test func rejectsPathsThatEscapeThePackage() {
        for bad in ["../x.img", "a/b.img", "..", ".", "", "/etc/passwd"] {
            #expect(!PackageValidator.isContainedName(bad), "\(bad)")
        }
        #expect(PackageValidator.isContainedName("Disk-1A2B.asif"))
    }

    @Test func importedPackagesLoseHostAccess() {
        var config = VMConfiguration(name: "x", engine: .qemu, guestOS: .linux, cpuCount: 1, memoryMiB: 1024)
        config.disks = [
            DiskConfiguration(path: "Disk.qcow2", sizeGiB: 8),
            DiskConfiguration(path: "../../Documents/secret.img", sizeGiB: 1),
            DiskConfiguration(path: "/Users/someone/secret.img", sizeGiB: 1),
            DiskConfiguration(path: "/Users/someone/installer.iso", sizeGiB: 0, isReadOnly: false, isRemovable: true),
        ]
        config.sharedFolders = [SharedFolder(path: NSHomeDirectory())]
        config.qemu.extraArguments = ["-drive", "file=/etc/hosts"]
        config.network.mode = .bridged
        let removed = PackageValidator.sanitize(&config, imported: true)
        #expect(config.disks.map(\.path) == ["Disk.qcow2", "/Users/someone/installer.iso"])
        #expect(config.disks[1].isReadOnly, "installer media is forced read-only")
        #expect(config.sharedFolders.isEmpty)
        #expect(config.qemu.extraArguments.isEmpty)
        #expect(config.network.mode == .nat)
        #expect(removed.count == 4)
    }

    @Test func qemuEscapesCommasInPaths() {
        var config = VMConfiguration(name: "x", engine: .qemu, guestOS: .linux, cpuCount: 1, memoryMiB: 1024)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("a,readonly=off,b")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("disk.img").path, contents: Data())
        config.disks = [DiskConfiguration(path: "disk.img", sizeGiB: 1)]
        let args = QEMUArgumentBuilder(config: config, bundle: VMBundle(url: dir), qmpSocket: "/tmp/q", dataDirectory: URL(fileURLWithPath: "/share")).build()
        let drive = args.first { $0.contains("disk.img") } ?? ""
        #expect(drive.contains("a,,readonly=off,,b"), "commas in paths must be doubled: \(drive)")
    }
}

@MainActor
struct ResourceGuardTests {
    private func machine(memory: Int) -> VMInstance {
        var config = VMConfiguration(name: "Guarded", engine: .apple, guestOS: .linux, cpuCount: 2, memoryMiB: memory)
        config.disks = []
        return VMInstance(bundle: VMBundle(url: FileManager.default.temporaryDirectory), config: config)
    }

    @Test func refusesMemoryThatWouldStarveMacOS() {
        let greedy = machine(memory: HostInfo.memoryMiB) // all of the Mac's memory
        #expect(throws: VMError.self) { try ResourceGuard.checkCanStart(greedy, library: VMLibrary.shared) }
    }

    @Test func allowsTheRecommendedSize() throws {
        let normal = machine(memory: HostInfo.recommendedMemoryMiB(for: .linux))
        try ResourceGuard.checkCanStart(normal, library: VMLibrary.shared)
    }

    @Test func maximumPresetFitsTheBudget() {
        // the settings' Maximum must never be something the guard then refuses on its own
        #expect(HostInfo.maxMemoryMiB <= HostInfo.memoryMiB - ResourceGuard.memoryReserveMiB)
    }
}
