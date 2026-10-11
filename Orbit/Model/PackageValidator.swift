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

    /// "52:54:00:12:34:56": the only form a MAC address may take. Anything else could smuggle
    /// options into QEMU's command line.
    static func isValidMACAddress(_ mac: String) -> Bool {
        mac.wholeMatch(of: /[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}/) != nil
    }

    /// A QEMU machine type ("virt", "q35", "pc-q35-9.2"): letters, digits, dots, dashes and
    /// underscores only, so it can't carry extra options such as `dumpdtb=` (which writes a file).
    static func isValidMachineType(_ machine: String) -> Bool {
        machine.wholeMatch(of: /[A-Za-z0-9._-]{1,64}/) != nil
    }

    static let validPorts = 1...65535

    /// Make a configuration safe to run.
    ///
    /// - Parameter imported: The package came from outside Orbit's library: also drop shared
    ///   folders, raw QEMU arguments, port forwards and installer media outside the package,
    ///   which would give it access to this Mac without the user choosing that.
    /// - Returns: what had to be removed, for telling the user.
    @discardableResult
    static func sanitize(_ config: inout VMConfiguration, imported: Bool) -> [String] {
        var removed: [String] = []
        config.disks = config.disks.compactMap { disk in
            var disk = disk
            if disk.isRemovable {
                // installer media may live anywhere, but is only ever read; a package from
                // elsewhere could name any file on this Mac and let its guest read it
                if imported && (disk.isExternal || !isContainedName(disk.path)) {
                    removed.append("installer “\((disk.path as NSString).lastPathComponent)” outside the package")
                    return nil
                }
                disk.isReadOnly = true
                // no "..": a path that only looks like it's inside the package must not be
                // treated as Orbit's own file (ejecting deletes those)
                if disk.isExternal {
                    disk.path = URL(fileURLWithPath: disk.path).standardizedFileURL.path
                }
                return disk
            }
            if disk.isExternal || !isContainedName(disk.path) {
                removed.append("disk “\(disk.path)” outside the package")
                return nil
            }
            return disk
        }
        if !isValidMACAddress(config.network.macAddress) {
            config.network.macAddress = NetworkConfiguration.randomMACAddress()
        }
        if let machine = config.qemu.machine, !isValidMachineType(machine) {
            removed.append("QEMU machine type “\(machine)”")
            config.qemu.machine = nil
        }
        config.network.portForwards.removeAll { !validPorts.contains($0.hostPort) || !validPorts.contains($0.guestPort) }
        config.cpuCount = max(1, config.cpuCount)
        config.memoryMiB = max(512, config.memoryMiB)
        config.qemu.tcgCacheMiB = min(max(config.qemu.tcgCacheMiB, 64), 4096)
        if imported {
            if !config.sharedFolders.isEmpty {
                removed.append("\(config.sharedFolders.count) shared folder(s)")
                config.sharedFolders = []
            }
            if !config.qemu.extraArguments.isEmpty {
                removed.append("custom QEMU arguments")
                config.qemu.extraArguments = []
            }
            if !config.network.portForwards.isEmpty {
                // each one opens a port on this Mac that other devices on the network can reach
                removed.append("\(config.network.portForwards.count) port forward(s)")
                config.network.portForwards = []
            }
            if config.network.mode == .bridged {
                config.network.mode = .nat
            }
            config.startWithOrbit = false
        }
        return removed
    }

    /// Names of symbolic links in `package` (top level and every folder below it).
    ///
    /// Orbit never creates links inside a package. One found there was planted: a "disk" that
    /// links to a file elsewhere would hand that file to the guest, and a link in a snapshot
    /// would copy it into the package on restore.
    static func symbolicLinks(in package: URL) -> [String] {
        guard let items = FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return [] }
        var links: [String] = []
        for case let item as URL in items where (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            links.append(item.lastPathComponent)
        }
        return links
    }

    /// Refuse to run a machine whose package contains links to files outside it.
    static func checkFiles(of bundle: VMBundle) throws {
        let links = symbolicLinks(in: bundle.url)
        guard links.isEmpty else {
            throw VMError.invalidConfiguration("“\(bundle.url.lastPathComponent)” contains links to files outside the machine (\(links.prefix(3).joined(separator: ", "))). Orbit won't start it, because the guest could reach those files. Remove the links, or import the machine again from a trusted copy.")
        }
    }

    /// True when `url` is a symbolic link (not followed).
    static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }
}
