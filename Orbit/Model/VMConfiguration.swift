import Foundation

/// Which hypervisor runs the guest.
enum VMEngineKind: String, Codable, CaseIterable, Identifiable {
    /// Apple Virtualization.framework: native speed, paravirtual devices, Apple Silicon guests only.
    case apple
    /// QEMU subprocess: HVF-accelerated for arm64 guests, emulated (TCG) for everything else.
    case qemu

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: "Apple Virtualization"
        case .qemu: "QEMU"
        }
    }

    var summary: String {
        switch self {
        case .apple: "Native speed. Best for macOS and ARM Linux."
        case .qemu: "Maximum compatibility. Windows, x86 and exotic guests."
        }
    }
}

enum GuestOS: String, Codable, CaseIterable, Identifiable {
    case macOS
    case linux
    case windows
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .macOS: "macOS"
        case .linux: "Linux"
        case .windows: "Windows"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .macOS: "apple.logo"
        case .linux: "terminal.fill"
        case .windows: "macwindow.on.rectangle"
        case .other: "cpu"
        }
    }
}

enum GuestArchitecture: String, Codable, CaseIterable, Identifiable {
    case arm64 = "aarch64"
    case x86_64

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .arm64: "ARM64"
        case .x86_64: "x86-64"
        }
    }

    /// True when the guest can run on the host CPU without emulation.
    var isNative: Bool {
        #if arch(arm64)
        self == .arm64
        #else
        self == .x86_64
        #endif
    }
}

enum DiskInterface: String, Codable, CaseIterable, Identifiable {
    case virtio
    case nvme
    case usb

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .virtio: "VirtIO"
        case .nvme: "NVMe"
        case .usb: "USB"
        }
    }
}

/// Trade-off between host-side caching and crash safety for disk I/O.
enum DiskPerformance: String, Codable, CaseIterable, Identifiable {
    /// Every guest flush reaches the physical disk (F_FULLFSYNC).
    case safe
    /// Guest flushes use fsync; much faster on Apple SSDs, still survives guest crashes.
    case balanced
    /// No forced syncs; fastest, a host crash may lose recent writes.
    case fast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .safe: "Safe"
        case .balanced: "Balanced"
        case .fast: "Fast"
        }
    }

    var detail: String {
        switch self {
        case .safe: "Full flush on every guest sync. Slowest, safest."
        case .balanced: "Recommended. fsync on guest sync, survives guest crashes."
        case .fast: "No forced syncs. A Mac crash may lose recent guest writes."
        }
    }
}

struct DiskConfiguration: Codable, Identifiable, Hashable {
    var id = UUID()
    /// File name inside the bundle, or an absolute path for external images.
    var path: String
    var sizeGiB: Int
    var isReadOnly = false
    var interface: DiskInterface = .virtio
    /// Removable media such as installer ISOs.
    var isRemovable = false

    var isExternal: Bool { path.hasPrefix("/") }
}

enum NetworkMode: String, Codable, CaseIterable, Identifiable {
    case nat
    case hostOnly
    case bridged
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nat: "Shared (NAT)"
        case .hostOnly: "Host Only"
        case .bridged: "Bridged"
        case .none: "Disconnected"
        }
    }
}

struct PortForward: Codable, Identifiable, Hashable {
    var id = UUID()
    var isUDP = false
    var hostPort: Int
    var guestPort: Int
}

struct NetworkConfiguration: Codable, Hashable {
    var mode: NetworkMode = .nat
    var macAddress: String = NetworkConfiguration.randomMACAddress()
    var bridgeInterface: String?
    /// QEMU user networking only.
    var portForwards: [PortForward] = []

    /// Locally administered unicast address, same scheme as VZMACAddress.randomLocallyAdministered().
    static func randomMACAddress() -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] & 0xFC) | 0x02
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

/// How large a Linux guest's text and controls appear on a Retina screen.
enum DisplayScaling: String, Codable, CaseIterable, Identifiable {
    /// Full Retina resolution: sharpest, but tiny unless scaling is raised inside the guest.
    case sharp
    /// 150%: a middle ground.
    case balanced
    /// 200%: the guest sees the window's size in points, so text matches macOS.
    case large

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sharp: "Sharp (Retina)"
        case .balanced: "Medium"
        case .large: "Large"
        }
    }

    var detail: String {
        switch self {
        case .sharp: "Full resolution. Text is small unless you raise scaling inside the guest."
        case .balanced: "Between Sharp and Large."
        case .large: "Recommended. Text and controls match the size of macOS."
        }
    }

    /// Guest pixels per Mac point on a 2× screen.
    var pixelsPerPoint: CGFloat {
        switch self {
        case .sharp: 2
        case .balanced: 4.0 / 3.0
        case .large: 1
        }
    }
}

struct DisplayConfiguration: Codable, Hashable {
    var widthPixels = 2560
    var heightPixels = 1600
    var pixelsPerInch = 220
    /// Resize the guest display to match the window (macOS 14+ guests, Linux with virtio-gpu).
    var dynamicResolution = true
    /// Optional so configurations saved before it existed still load; nil means Large.
    var scaling: DisplayScaling?

    var effectiveScaling: DisplayScaling { scaling ?? .large }
}

struct SharedFolder: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    var isReadOnly = false

    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct QEMUOptions: Codable, Hashable {
    /// Override for the -machine value; nil picks a sensible default per architecture.
    var machine: String?
    /// Extra raw arguments appended last.
    var extraArguments: [String] = []
    /// Translation-block cache for TCG, in MiB.
    var tcgCacheMiB = 512
    /// Expose a TPM 2.0 emulator (requires swtpm installed).
    var tpm = false
}

struct VMConfiguration: Codable, Identifiable, Hashable {
    static let currentVersion = 1

    var version = VMConfiguration.currentVersion
    var id = UUID()
    var name: String
    var notes = ""
    /// Catalog template this VM was created from; drives icon and colors.
    var templateID: String?
    var engine: VMEngineKind
    var guestOS: GuestOS
    var architecture: GuestArchitecture = .arm64

    var cpuCount: Int
    var memoryMiB: Int
    var disks: [DiskConfiguration] = []
    var display = DisplayConfiguration()
    var network = NetworkConfiguration()
    var sharedFolders: [SharedFolder] = []

    var audioOutput = true
    var audioInput = false
    /// Off by default: with it on, a guest can read anything copied on this Mac.
    var clipboardSharing = false
    var rosetta = false
    var nestedVirtualization = false
    var diskPerformance: DiskPerformance = .balanced
    /// Save the machine state when Orbit quits and resume instantly next launch.
    var suspendOnQuit = true
    /// Boot from removable media before the main disk (first boot after creation).
    var bootFromInstaller = true
    var qemu = QEMUOptions()

    var createdAt = Date()
    var lastRunAt: Date?

    var primaryDisk: DiskConfiguration? { disks.first { !$0.isRemovable } }
    var installerMedia: DiskConfiguration? { disks.first { $0.isRemovable } }

    var totalDiskGiB: Int { disks.filter { !$0.isRemovable }.reduce(0) { $0 + $1.sizeGiB } }

    init(name: String, engine: VMEngineKind, guestOS: GuestOS, architecture: GuestArchitecture = .arm64, cpuCount: Int, memoryMiB: Int) {
        self.name = name
        self.engine = engine
        self.guestOS = guestOS
        self.architecture = architecture
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
    }
}

extension VMConfiguration {
    /// Decode tolerantly so older or hand-edited files keep loading as fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = VMConfiguration(name: "", engine: .apple, guestOS: .linux, cpuCount: 2, memoryMiB: 4096)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? defaults.version
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        templateID = try c.decodeIfPresent(String.self, forKey: .templateID)
        engine = try c.decode(VMEngineKind.self, forKey: .engine)
        guestOS = try c.decode(GuestOS.self, forKey: .guestOS)
        architecture = try c.decodeIfPresent(GuestArchitecture.self, forKey: .architecture) ?? .arm64
        cpuCount = try c.decode(Int.self, forKey: .cpuCount)
        memoryMiB = try c.decode(Int.self, forKey: .memoryMiB)
        disks = try c.decodeIfPresent([DiskConfiguration].self, forKey: .disks) ?? []
        display = try c.decodeIfPresent(DisplayConfiguration.self, forKey: .display) ?? defaults.display
        network = try c.decodeIfPresent(NetworkConfiguration.self, forKey: .network) ?? defaults.network
        sharedFolders = try c.decodeIfPresent([SharedFolder].self, forKey: .sharedFolders) ?? []
        audioOutput = try c.decodeIfPresent(Bool.self, forKey: .audioOutput) ?? defaults.audioOutput
        audioInput = try c.decodeIfPresent(Bool.self, forKey: .audioInput) ?? defaults.audioInput
        clipboardSharing = try c.decodeIfPresent(Bool.self, forKey: .clipboardSharing) ?? defaults.clipboardSharing
        rosetta = try c.decodeIfPresent(Bool.self, forKey: .rosetta) ?? defaults.rosetta
        nestedVirtualization = try c.decodeIfPresent(Bool.self, forKey: .nestedVirtualization) ?? defaults.nestedVirtualization
        diskPerformance = try c.decodeIfPresent(DiskPerformance.self, forKey: .diskPerformance) ?? defaults.diskPerformance
        suspendOnQuit = try c.decodeIfPresent(Bool.self, forKey: .suspendOnQuit) ?? defaults.suspendOnQuit
        bootFromInstaller = try c.decodeIfPresent(Bool.self, forKey: .bootFromInstaller) ?? false
        qemu = try c.decodeIfPresent(QEMUOptions.self, forKey: .qemu) ?? defaults.qemu
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastRunAt = try c.decodeIfPresent(Date.self, forKey: .lastRunAt)
    }
}
