import Foundation

/// Rules every VM package must follow, whatever its origin.
///
/// A package is just a folder, so one shared by someone else may describe anything. These
/// checks keep a VM's files inside its own package, so a crafted package can't point a disk at
/// a file elsewhere on this Mac or make a snapshot restore write outside the package.
enum PackageValidator {
    /// True for a plain file name that stays inside the package ("Disk-1.asif", not "../x" or "a/b").
    static func isContainedName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
            && (name as NSString).lastPathComponent == name
    }

    /// Make a configuration safe to run.
    ///
    /// - Parameter imported: The package came from outside Orbit's library: also drop shared
    ///   folders and raw QEMU arguments, which would give it access to this Mac without the user
    ///   choosing that.
    /// - Returns: what had to be removed, for telling the user.
    @discardableResult
    static func sanitize(_ config: inout VMConfiguration, imported: Bool) -> [String] {
        var removed: [String] = []
        config.disks = config.disks.compactMap { disk in
            var disk = disk
            if disk.isRemovable {
                // installer media may live anywhere, but is only ever read
                disk.isReadOnly = true
                return disk
            }
            if disk.isExternal || !isContainedName(disk.path) {
                removed.append("disk “\(disk.path)” outside the package")
                return nil
            }
            return disk
        }
        if imported {
            if !config.sharedFolders.isEmpty {
                removed.append("\(config.sharedFolders.count) shared folder(s)")
                config.sharedFolders = []
            }
            if !config.qemu.extraArguments.isEmpty {
                removed.append("custom QEMU arguments")
                config.qemu.extraArguments = []
            }
            if config.network.mode == .bridged {
                config.network.mode = .nat
            }
        }
        return removed
    }
}
