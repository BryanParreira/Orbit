import Foundation
import UniformTypeIdentifiers

/// What a file the user hands Orbit actually is, decided by its contents rather than its name.
enum FileKind: Equatable {
    case orbitPackage
    case utmPackage
    /// macOS restore image.
    case ipsw
    /// ISO 9660 / UDF optical image (installer).
    case iso
    case diskImage(DiskFormat)
    case unsupported(String)

    var isInstaller: Bool {
        switch self {
        case .iso, .ipsw: true
        default: false
        }
    }
}

enum DiskFormat: String, CaseIterable {
    case raw, asif, qcow2, vmdk, vdi, vhdx, vhd

    var displayName: String {
        switch self {
        case .raw: "Raw"
        case .asif: "ASIF"
        case .qcow2: "QCOW2"
        case .vmdk: "VMDK (VMware)"
        case .vdi: "VDI (VirtualBox)"
        case .vhdx: "VHDX (Hyper-V)"
        case .vhd: "VHD"
        }
    }

    /// Name qemu-img uses for the format.
    var qemuName: String {
        switch self {
        case .vhd: "vpc"
        default: rawValue
        }
    }

    /// Converting to `engine`'s format needs qemu-img (ASIF converts with Apple's own tools).
    func needsQEMUImg(for engine: VMEngineKind) -> Bool {
        !isNative(to: engine) && self != .asif
    }

    /// Format the disk ends up in for `engine`.
    func importedFormatName(for engine: VMEngineKind) -> String {
        if isNative(to: engine) { return displayName }
        return engine == .apple || self == .asif ? "RAW" : "QCOW2"
    }

    /// Formats each engine reads without conversion.
    func isNative(to engine: VMEngineKind) -> Bool {
        switch engine {
        case .apple: self == .raw || self == .asif
        case .qemu: self == .raw || self == .qcow2
        }
    }
}

enum FileInspector {
    static let supportedSummary = "ISO installers, macOS IPSW restore images, disk images (RAW/IMG, ASIF, QCOW2, VMDK, VDI, VHD, VHDX), and Orbit or UTM virtual machines."

    /// Types for open panels: everything is selectable, `inspect` decides.
    static let openPanelTypes: [UTType] = [.item, .folder, .package]

    static func inspect(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .unsupported("“\(url.lastPathComponent)” could not be found.")
        }
        if isDirectory.boolValue {
            if ext == VMBundle.fileExtension, FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path) {
                return .orbitPackage
            }
            if ext == "utm", FileManager.default.fileExists(atPath: url.appendingPathComponent("config.plist").path) {
                return .utmPackage
            }
            return .unsupported("“\(url.lastPathComponent)” is a folder, not a virtual machine.")
        }
        guard FileManager.default.isReadableFile(atPath: url.path), let handle = try? FileHandle(forReadingFrom: url) else {
            return .unsupported("Orbit doesn't have permission to read “\(url.lastPathComponent)”.")
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > 0 else { return .unsupported("“\(url.lastPathComponent)” is empty.") }

        func bytes(at offset: UInt64, count: Int) -> Data {
            guard offset < size, (try? handle.seek(toOffset: offset)) != nil else { return Data() }
            return (try? handle.read(upToCount: count)) ?? Data()
        }
        let head = bytes(at: 0, count: 64)
        func headHas(_ magic: [UInt8], at offset: Int = 0) -> Bool {
            head.count >= offset + magic.count && Array(head[offset..<offset + magic.count]) == magic
        }

        // Container formats with a signature in the first bytes
        if headHas([0x51, 0x46, 0x49, 0xFB]) { return .diskImage(.qcow2) }
        if headHas(Array("KDMV".utf8)) || headHas(Array("# Disk DescriptorFile".utf8)) { return .diskImage(.vmdk) }
        if headHas(Array("vhdxfile".utf8)) { return .diskImage(.vhdx) }
        if headHas(Array("conectix".utf8)) { return .diskImage(.vhd) }
        if bytes(at: 0x40, count: 4) == Data([0x7F, 0x10, 0xDA, 0xBE]) { return .diskImage(.vdi) }
        if headHas([0x50, 0x4B, 0x03, 0x04]) {
            return ext == "ipsw" ? .ipsw : .unsupported("“\(url.lastPathComponent)” is a ZIP archive. Unzip it first.")
        }
        // ISO 9660 ("CD001") or UDF ("BEA01"/"NSR0x") volume descriptor at 32 KiB
        let descriptor = bytes(at: 0x8001, count: 5)
        if descriptor == Data("CD001".utf8) || descriptor == Data("BEA01".utf8) || descriptor.starts(with: Data("NSR0".utf8)) {
            return .iso
        }
        // VHD fixed disks keep their footer at the end
        if size >= 512, bytes(at: size - 512, count: 8) == Data("conectix".utf8) { return .diskImage(.vhd) }
        // UDIF .dmg ("koly" trailer): Virtualization can't boot these
        if size >= 512, bytes(at: size - 512, count: 4) == Data("koly".utf8) {
            return .unsupported("“\(url.lastPathComponent)” is a macOS .dmg. Use an ISO, or convert it with: hdiutil convert -format UDTO")
        }
        if ext == "asif" { return .diskImage(.asif) }
        // raw read/write .dmg files (UDRW) have no trailer and are plain disks
        if ["img", "raw", "bin", "dd", "dmg"].contains(ext) || ext == "iso" {
            // Raw disks: any size that is a whole number of sectors
            guard size % 512 == 0, size >= 1_048_576 else {
                return .unsupported("“\(url.lastPathComponent)” doesn't look like a disk image (\(Int64(size).formattedBytes)).")
            }
            return .diskImage(.raw)
        }
        return .unsupported("Orbit can't use “\(url.lastPathComponent)”. It works with \(supportedSummary)")
    }

    /// Size of the virtual disk in GiB (not the file size), when it can be told.
    static func virtualSizeGiB(of url: URL, format: DiskFormat) async -> Int {
        func gib(_ bytes: Int64) -> Int { Int(max(1, (bytes + 1_073_741_823) / 1_073_741_824)) }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        switch format {
        case .raw:
            return gib(fileSize)
        case .asif:
            // qemu-img doesn't know ASIF and would report the sparse file's size
            if let output = try? await DiskImageService.run(URL(fileURLWithPath: "/usr/sbin/diskutil"), ["image", "info", "--plist", url.path]),
               let plist = try? PropertyListSerialization.propertyList(from: Data(output.utf8), format: nil) as? [String: Any],
               let sizes = plist["Size Info"] as? [String: Any], let bytes = (sizes["Total Bytes"] as? NSNumber)?.int64Value {
                return gib(bytes)
            }
            return gib(fileSize)
        default:
            if let qemuImg = HostInfo.qemuImg(), FileManager.default.isExecutableFile(atPath: qemuImg.path),
               let output = try? await DiskImageService.run(qemuImg, ["info", "--output=json", "-f", format.qemuName, url.path]),
               let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
               let bytes = (json["virtual-size"] as? NSNumber)?.int64Value {
                return gib(bytes)
            }
            return gib(fileSize)
        }
    }
}
