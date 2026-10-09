import Foundation

/// Keeps virtual machines from starving the Mac they run on.
///
/// Two failure modes can make a whole Mac unusable: giving guests more memory than macOS can
/// spare (it swaps to a standstill) and letting a guest fill the host disk (macOS and the guest's
/// own disk image both suffer). These checks refuse a start that would do either, and pause a
/// running machine before the disk runs out.
@MainActor
enum ResourceGuard {
    /// Memory always left for macOS and its apps.
    static let memoryReserveMiB = 3072
    /// Free space needed to start a machine.
    static let minimumFreeToStart: Int64 = 3 * 1_073_741_824
    /// Below this, running machines are paused.
    static let pauseBelowFree: Int64 = 1_073_741_824

    static func checkCanStart(_ vm: VMInstance, library: VMLibrary) throws {
        let others = library.vms.filter { $0 !== vm && $0.state.isActive }
        let othersMemory = others.reduce(0) { $0 + $1.config.memoryMiB }
        let budget = HostInfo.memoryMiB - memoryReserveMiB
        if othersMemory + vm.config.memoryMiB > budget {
            let running = others.count == 1 ? "1 machine is" : "\(others.count) machines are"
            throw VMError.invalidConfiguration(
                others.isEmpty
                    ? "“\(vm.config.name)” is set to \(vm.config.memoryMiB.formattedMemory), which would leave too little memory for macOS on this \(HostInfo.memoryMiB.formattedMemory) Mac. Lower its memory in Settings (⌘I)."
                    : "\(running) already using \(othersMemory.formattedMemory). Starting “\(vm.config.name)” with \(vm.config.memoryMiB.formattedMemory) would leave too little of this Mac's \(HostInfo.memoryMiB.formattedMemory) for macOS. Shut down another machine or lower this one's memory in Settings (⌘I).")
        }
        if let free = HostInfo.freeSpaceBytes(at: vm.bundle.url), free < minimumFreeToStart {
            throw VMError.invalidConfiguration("Only \(free.formattedBytes) is free on the disk that holds “\(vm.config.name)”. Free up at least \(minimumFreeToStart.formattedBytes) before starting it, so neither macOS nor the machine runs out of space.")
        }
    }

    /// Free bytes on the volume holding `vm`, when it's low enough to pause.
    static func lowDiskSpace(for vm: VMInstance) -> Int64? {
        guard let free = HostInfo.freeSpaceBytes(at: vm.bundle.url), free < pauseBelowFree else { return nil }
        return free
    }
}
