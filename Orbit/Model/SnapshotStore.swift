import Foundation

struct VMSnapshot: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    /// Captured while running: restoring resumes the guest exactly where it was.
    var includesMemory: Bool
    var files: [String]
}

/// Snapshots as APFS clones of the VM's state files.
///
/// A clone shares every block with the original until one of them is written, so taking a
/// snapshot is instant and only the blocks the guest changes afterwards use new space.
@MainActor
enum SnapshotStore {
    private static let manifestName = "snapshot.json"
    private static let screenshotName = "Screenshot.png"

    static func list(for bundle: VMBundle) -> [VMSnapshot] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: bundle.snapshotsURL, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(manifestName)) else { return nil }
            return try? JSONDecoder.orbit.decode(VMSnapshot.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    static func directory(for snapshot: VMSnapshot, in bundle: VMBundle) -> URL {
        bundle.snapshotsURL.appendingPathComponent(snapshot.id.uuidString, isDirectory: true)
    }

    static func screenshotURL(for snapshot: VMSnapshot, in bundle: VMBundle) -> URL {
        directory(for: snapshot, in: bundle).appendingPathComponent(screenshotName)
    }

    /// Clone the VM's current state. The VM must be stopped (or suspended).
    @discardableResult
    static func create(named name: String, for vm: VMInstance) async throws -> VMSnapshot {
        let bundle = vm.bundle
        let files = bundle.stateFiles(for: vm.config) + qemuFirmware(in: bundle)
        let includesMemory = files.contains(bundle.savedStateURL)
        let snapshot = VMSnapshot(name: name, includesMemory: includesMemory, files: files.map(\.lastPathComponent))
        let dir = directory(for: snapshot, in: bundle)
        do {
            try await FileCloner.cloneInBackground(files, into: dir)
            if FileManager.default.fileExists(atPath: bundle.screenshotURL.path) {
                try? FileCloner.clone(bundle.screenshotURL, to: dir.appendingPathComponent(screenshotName))
            }
            try JSONEncoder.orbit.encode(snapshot).write(to: dir.appendingPathComponent(manifestName))
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return snapshot
    }

    /// Replace the VM's state with the snapshot's. The VM must be stopped.
    static func restore(_ snapshot: VMSnapshot, for vm: VMInstance) async throws {
        let bundle = vm.bundle
        let dir = directory(for: snapshot, in: bundle)
        // RAM from after the snapshot would not match its disks
        try? FileManager.default.removeItem(at: bundle.savedStateURL)
        for name in snapshot.files {
            let source = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw VMError.missingFile("\(name) in snapshot \(snapshot.name)")
            }
            try await FileCloner.cloneInBackground(source, to: bundle.url.appendingPathComponent(name))
        }
        let shot = dir.appendingPathComponent(screenshotName)
        if FileManager.default.fileExists(atPath: shot.path) {
            try? FileCloner.clone(shot, to: bundle.screenshotURL)
        }
    }

    static func delete(_ snapshot: VMSnapshot, for vm: VMInstance) throws {
        try FileManager.default.removeItem(at: directory(for: snapshot, in: vm.bundle))
    }

    private static func qemuFirmware(in bundle: VMBundle) -> [URL] {
        let url = bundle.url.appendingPathComponent("EFIVariables.fd")
        return FileManager.default.fileExists(atPath: url.path) ? [url] : []
    }
}
