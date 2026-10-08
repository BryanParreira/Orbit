import Foundation

enum VMState: Equatable {
    case stopped
    case starting
    case running
    case pausing
    case paused
    case resuming
    case saving
    case restoring
    case stopping
    case installing

    var isActive: Bool {
        switch self {
        case .stopped: false
        default: true
        }
    }

    /// Transitional states during which no new command should be issued.
    var isBusy: Bool {
        switch self {
        case .starting, .pausing, .resuming, .saving, .restoring, .stopping: true
        default: false
        }
    }

    var label: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .running: "Running"
        case .pausing: "Pausing…"
        case .paused: "Paused"
        case .resuming: "Resuming…"
        case .saving: "Saving state…"
        case .restoring: "Restoring…"
        case .stopping: "Shutting down…"
        case .installing: "Installing"
        }
    }
}

struct StartOptions: OptionSet {
    let rawValue: Int
    /// macOS guests: boot into recoveryOS.
    static let recovery = StartOptions(rawValue: 1 << 0)
    /// Run on throwaway APFS clones; nothing the guest writes is kept.
    static let disposable = StartOptions(rawValue: 1 << 1)
    /// Ignore any saved state and cold boot.
    static let coldBoot = StartOptions(rawValue: 1 << 2)
}

/// One running (or startable) instance of a hypervisor engine.
@MainActor
protocol VMBackend: AnyObject {
    /// Called whenever the engine changes state on its own (guest shut down, crashed...).
    var onStateChange: ((VMState, Error?) -> Void)? { get set }
    var state: VMState { get }
    /// Engine can save RAM to disk and resume later.
    var supportsSuspend: Bool { get }
    /// Engine renders inside Orbit's display window (vs. its own window).
    var hasEmbeddedDisplay: Bool { get }

    func start(options: StartOptions) async throws
    /// Ask the guest OS to shut down (ACPI power button).
    func requestStop() async throws
    /// Pull the plug.
    func forceStop() async throws
    func pause() async throws
    func resume() async throws
    func restart() async throws
    /// Save RAM to disk and stop. The next `start` resumes where it left off.
    func suspend() async throws
}

enum VMError: LocalizedError {
    case notRunning
    case unsupported(String)
    case missingFile(String)
    case qemuNotInstalled
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: "The virtual machine is not running."
        case .unsupported(let what): "\(what) is not supported by this virtual machine."
        case .missingFile(let name): "Required file is missing: \(name)"
        case .qemuNotInstalled: "QEMU is not installed. Install it with Homebrew (brew install qemu) or set its location in Settings."
        case .invalidConfiguration(let reason): reason
        }
    }
}
