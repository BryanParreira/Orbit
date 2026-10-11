import Foundation

struct VMSnapshot: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    /// Captured while running: restoring resumes the guest exactly where it was.
    var includesMemory: Bool
    var files: [String]
    /// Taken by Orbit on a schedule (nil in snapshots saved before automatic ones existed).
    var isAutomatic: Bool?
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
    static func create(named name: String, for vm: VMInstance, automatic: Bool = false) async throws -> VMSnapshot {
        let bundle = vm.bundle
        let files = bundle.stateFiles(for: vm.config) + qemuFirmware(in: bundle)
        let includesMemory = files.contains(bundle.savedStateURL)
        let snapshot = VMSnapshot(name: name, includesMemory: includesMemory, files: files.map(\.lastPathComponent),
                                  isAutomatic: automatic ? true : nil)
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
        // a manifest is data: never let it name a file outside the package, and never copy in
        // a link to a file elsewhere on this Mac (cloning follows it and would copy that file)
        guard snapshot.files.allSatisfy(PackageValidator.isContainedName) else {
            throw VMError.invalidConfiguration("This snapshot is damaged and can't be restored.")
        }
        for name in snapshot.files {
            let source = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw VMError.missingFile("\(name) in snapshot \(snapshot.name)")
            }
            guard !PackageValidator.isSymbolicLink(source) else {
                throw VMError.invalidConfiguration("This snapshot is damaged and can't be restored.")
            }
        }
        // checked first, so a damaged snapshot leaves the machine as it was.
        // RAM from after the snapshot would not match its disks.
        try? FileManager.default.removeItem(at: bundle.savedStateURL)
        for name in snapshot.files {
            try await FileCloner.cloneInBackground(dir.appendingPathComponent(name), to: bundle.url.appendingPathComponent(name))
        }
        let shot = dir.appendingPathComponent(screenshotName)
        if FileManager.default.fileExists(atPath: shot.path) {
            try? FileCloner.clone(shot, to: bundle.screenshotURL)
        }
    }

    static func delete(_ snapshot: VMSnapshot, for vm: VMInstance) throws {
        try FileManager.default.removeItem(at: directory(for: snapshot, in: vm.bundle))
    }

    /// Take an automatic snapshot when the last one is older than the machine's schedule, and
    /// keep only the newest few. The machine must be stopped (or suspended).
    /// - Returns: true when a snapshot was taken.
    @discardableResult
    static func takeAutomaticIfDue(for vm: VMInstance, now: Date = .now) async throws -> Bool {
        guard let interval = vm.config.automaticSnapshots.interval else { return false }
        let automatic = list(for: vm.bundle).filter { $0.isAutomatic == true }
        if let latest = automatic.first, now.timeIntervalSince(latest.createdAt) < interval { return false }
        try await create(named: "Automatic · \(now.formatted(date: .abbreviated, time: .shortened))", for: vm, automatic: true)
        for old in list(for: vm.bundle).filter({ $0.isAutomatic == true }).dropFirst(AutomaticSnapshots.keep) {
            try? delete(old, for: vm)
        }
        return true
    }

    private static func qemuFirmware(in bundle: VMBundle) -> [URL] {
        let url = bundle.url.appendingPathComponent("EFIVariables.fd")
        return FileManager.default.fileExists(atPath: url.path) ? [url] : []
    }
}
