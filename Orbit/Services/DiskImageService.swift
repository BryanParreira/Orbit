import Foundation

enum DiskImageError: LocalizedError {
    case toolFailed(String, String)
    case qemuImgMissing
    case cannotShrink

    var errorDescription: String? {
        switch self {
        case .toolFailed(let tool, let output): "\(tool) failed: \(output)"
        case .qemuImgMissing: "qemu-img was not found. Install QEMU with Homebrew: brew install qemu"
        case .cannotShrink: "Disks can only grow. Shrink the partition inside the guest first."
        }
    }
}

/// Creates and resizes disk images in the fastest format each engine supports.
enum DiskImageService {
    /// Create a blank disk in `directory` and return its file name.
    ///
    /// Apple engine: ASIF, Apple's sparse format (macOS 26+). Sparse like raw files, but stays
    /// sparse when copied to other volumes, and Virtualization reads it natively.
    /// QEMU engine: qcow2 tuned for SSDs.
    static func create(in directory: URL, id: UUID, sizeGiB: Int, engine: VMEngineKind) async throws -> String {
        let bytes = Int64(sizeGiB) * 1_073_741_824
        let base = "Disk-\(id.uuidString.prefix(8))"
        switch engine {
        case .qemu:
            let name = base + ".qcow2"
            guard let qemuImg = HostInfo.qemuImg(), FileManager.default.isExecutableFile(atPath: qemuImg.path) else {
                throw DiskImageError.qemuImgMissing
            }
            // lazy_refcounts + 2 MiB clusters: fewer metadata writes, noticeably faster on SSDs
            try await run(qemuImg, ["create", "-f", "qcow2", "-o", "lazy_refcounts=on,cluster_size=2M", directory.appendingPathComponent(name).path, "\(bytes)"])
            return name
        case .apple:
            let name = base + ".asif"
            do {
                try await run(URL(fileURLWithPath: "/usr/sbin/diskutil"), ["image", "create", "blank", "--fs", "None", "--format", "ASIF", "--size", "\(bytes)", directory.appendingPathComponent(name).path])
                return name
            } catch {
                // raw sparse file is still instant on APFS
                let raw = base + ".img"
                try createSparseRaw(at: directory.appendingPathComponent(raw), bytes: bytes)
                return raw
            }
        }
    }

    /// Raw image as an APFS sparse file: allocates nothing until the guest writes.
    static func createSparseRaw(at url: URL, bytes: Int64) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(bytes))
    }

    static func resize(at url: URL, toGiB sizeGiB: Int, currentGiB: Int) async throws {
        guard sizeGiB >= currentGiB else { throw DiskImageError.cannotShrink }
        let bytes = Int64(sizeGiB) * 1_073_741_824
        switch url.pathExtension {
        case "qcow2":
            guard let qemuImg = HostInfo.qemuImg() else { throw DiskImageError.qemuImgMissing }
            try await run(qemuImg, ["resize", url.path, "\(bytes)"])
        case "asif":
            try await run(URL(fileURLWithPath: "/usr/sbin/diskutil"), ["image", "resize", "--size", "\(bytes)", url.path])
        default:
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(bytes))
        }
    }

    /// Bytes the image actually occupies on disk (sparse-aware).
    static func allocatedBytes(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }

    @discardableResult
    static func run(_ tool: URL, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { process in
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: DiskImageError.toolFailed(tool.lastPathComponent, output.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// APFS copy-on-write cloning. Snapshots, duplicates and disposable runs cost no time or space.
enum FileCloner {
    static func clone(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        if clonefile(source.path, destination.path, 0) == 0 {
            return
        }
        // different volume or non-APFS: real copy
        try fm.copyItem(at: source, to: destination)
    }

    /// Clone files into `directory`, keeping their names.
    static func clone(_ files: [URL], into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files {
            try clone(file, to: directory.appendingPathComponent(file.lastPathComponent))
        }
    }
}

/// Brings a disk image made elsewhere (UTM, VMware, VirtualBox, Hyper-V, dd…) into a VM package,
/// converting it to the engine's native format when needed. The original file is never modified.
enum DiskImporter {
    enum ImportError: LocalizedError {
        case needsQEMU(DiskFormat)

        var errorDescription: String? {
            switch self {
            case .needsQEMU(let format):
                "Converting a \(format.displayName) disk needs qemu-img. Install QEMU from Settings → Engines (or run brew install qemu), then try again."
            }
        }
    }

    /// Copy or convert `source` into `directory`; returns the new file name.
    static func importDisk(_ source: URL, format: DiskFormat, into directory: URL, id: UUID, engine: VMEngineKind) async throws -> String {
        let base = "Disk-\(id.uuidString.prefix(8))"
        if format.isNative(to: engine) {
            let ext = switch format {
            case .asif: "asif"
            case .qcow2: "qcow2"
            default: "img"
            }
            let name = "\(base).\(ext)"
            let destination = directory.appendingPathComponent(name)
            // APFS clone when on the same volume (instant), real copy otherwise; off the main thread
            try await Task.detached(priority: .userInitiated) {
                try FileCloner.clone(source, to: destination)
            }.value
            return name
        }
        if format == .asif {
            // only Apple's tools read ASIF; a sparse raw copy works for QEMU as is
            let name = "\(base).img"
            let destination = directory.appendingPathComponent(name)
            do {
                try await DiskImageService.run(URL(fileURLWithPath: "/usr/sbin/diskutil"), ["image", "create", "from", "--format", "RAW", source.path, destination.path])
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            return name
        }
        guard let qemuImg = HostInfo.qemuImg(), FileManager.default.isExecutableFile(atPath: qemuImg.path) else {
            throw ImportError.needsQEMU(format)
        }
        // Apple engine reads raw (kept sparse by qemu-img); QEMU gets qcow2
        let (outFormat, ext) = engine == .apple ? ("raw", "img") : ("qcow2", "qcow2")
        let name = "\(base).\(ext)"
        let destination = directory.appendingPathComponent(name)
        var arguments = ["convert", "-f", format.qemuName, "-O", outFormat]
        if outFormat == "qcow2" { arguments += ["-o", "lazy_refcounts=on,cluster_size=2M"] }
        arguments += [source.path, destination.path]
        do {
            try await DiskImageService.run(qemuImg, arguments)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return name
    }
}
