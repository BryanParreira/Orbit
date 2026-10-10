import Foundation
import Virtualization

/// Facts about the Mac Orbit runs on, used to pick smart defaults and gate features.
enum HostInfo {
    static let totalCPUs = ProcessInfo.processInfo.processorCount
    static let performanceCores = sysctlInt("hw.perflevel0.physicalcpu").map(Int.init) ?? totalCPUs
    static let memoryBytes = ProcessInfo.processInfo.physicalMemory
    static var memoryMiB: Int { Int(memoryBytes / 1_048_576) }

    static let chipName: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }()

    static var maxCPUs: Int {
        min(totalCPUs, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
    }

    /// Leave at least 4 GiB (or a quarter of RAM on big machines) for macOS itself.
    static var maxMemoryMiB: Int {
        let headroom = max(4096, memoryMiB / 4)
        let vzMax = Int(VZVirtualMachineConfiguration.maximumAllowedMemorySize / 1_048_576)
        return min(vzMax, max(2048, memoryMiB - headroom))
    }

    /// Performance cores only: efficiency cores make guest vCPUs stall unpredictably.
    static var recommendedCPUs: Int {
        max(2, min(performanceCores, maxCPUs))
    }

    static func recommendedMemoryMiB(for os: GuestOS) -> Int {
        let floor = os == .macOS || os == .windows ? 4096 : 2048
        let half = (memoryMiB / 2 / 1024) * 1024
        return min(maxMemoryMiB, max(floor, min(half, 16384)))
    }

    static var supportsNestedVirtualization: Bool {
        VZGenericPlatformConfiguration.isNestedVirtualizationSupported
    }

    static var rosettaAvailability: VZLinuxRosettaAvailability {
        VZLinuxRosettaDirectoryShare.availability
    }

    // MARK: QEMU

    static let qemuSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]

    static func qemuBinary(for arch: GuestArchitecture) -> URL? {
        let name = "qemu-system-\(arch.rawValue)"
        let custom = UserDefaults.standard.string(forKey: PreferenceKey.qemuDirectory)
        let dirs = (custom.map { [$0] } ?? []) + qemuSearchPaths
        return dirs.lazy
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func qemuImg() -> URL? {
        qemuBinary(for: .arm64)?.deletingLastPathComponent().appendingPathComponent("qemu-img")
    }

    /// `share/qemu` next to the bin directory, where Homebrew installs EDK2 firmware.
    static func qemuDataDirectory() -> URL? {
        guard let bin = qemuBinary(for: .arm64) ?? qemuBinary(for: .x86_64) else { return nil }
        let resolved = bin.resolvingSymlinksInPath()
        let candidates = [
            resolved.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("share/qemu"),
            bin.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("share/qemu"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var isQEMUInstalled: Bool { qemuBinary(for: .arm64) != nil || qemuBinary(for: .x86_64) != nil }

    /// swtpm, which emulates a TPM 2.0 chip. Optional: without it, Windows guests install
    /// without a TPM (the drivers disc's answer file tells setup not to require one).
    static var swtpm: URL? {
        qemuSearchPaths.lazy
            .map { URL(fileURLWithPath: $0).appendingPathComponent("swtpm") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isHomebrewInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/brew")
    }

    // MARK: Storage

    static func freeSpaceBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        // "important usage" isn't reported by every volume (many external drives); fall back to plain free space
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    static func supportsCloning(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?.volumeSupportsFileCloning ?? false
    }

    private static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

enum PreferenceKey {
    static let libraryPath = "libraryPath"
    /// Machines the user chose to keep outside the library folder (package paths).
    static let machineLocations = "machineLocations"
    static let qemuDirectory = "qemuDirectory"
    static let showMenuBarExtra = "showMenuBarExtra"
    static let libraryLayout = "libraryLayout"
    static let quitBehavior = "quitBehavior"
    static let captureSystemKeys = "captureSystemKeys"
}
