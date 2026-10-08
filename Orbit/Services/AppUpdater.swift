import Foundation
import Observation
import Sparkle

/// In-app updates through Sparkle.
///
/// Orbit reads the appcast attached to the newest GitHub release, verifies each update
/// against the EdDSA key embedded in Info.plist, and replaces itself in place. Installing
/// quits Orbit normally, so running VMs are suspended first and resume after the update.
@Observable
@MainActor
final class AppUpdater {
    static let shared = AppUpdater()

    private(set) var canCheckForUpdates = false
    /// False in builds without a release feed (local development).
    let isConfigured: Bool

    var automaticallyChecks: Bool {
        get { access(keyPath: \.automaticallyChecks); return controller.updater.automaticallyChecksForUpdates }
        set { withMutation(keyPath: \.automaticallyChecks) { controller.updater.automaticallyChecksForUpdates = newValue } }
    }

    var automaticallyDownloads: Bool {
        get { access(keyPath: \.automaticallyDownloads); return controller.updater.automaticallyDownloadsUpdates }
        set { withMutation(keyPath: \.automaticallyDownloads) { controller.updater.automaticallyDownloadsUpdates = newValue } }
    }

    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        isConfigured = !key.isEmpty && !key.hasPrefix("REPLACE") && feed.hasPrefix("https://")
        // never start against a missing key: Sparkle would refuse every update anyway
        controller = SPUStandardUpdaterController(startingUpdater: isConfigured, updaterDelegate: nil, userDriverDelegate: nil)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    /// Start early so scheduled background checks run from launch.
    func start() {
        _ = controller
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
