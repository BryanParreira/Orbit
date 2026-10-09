import SwiftUI

@main
struct OrbitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library = VMLibrary.shared
    @State private var router = AppRouter.shared
    @AppStorage(PreferenceKey.showMenuBarExtra) private var showMenuBarExtra = true

    var body: some Scene {
        Window("Orbit", id: SceneID.library) {
            LibraryView()
                .environment(library)
                .environment(router)
                .tint(Theme.ink)
                .frame(minWidth: 900, minHeight: 580)
        }
        .defaultSize(width: 1180, height: 760)
        .defaultWindowPlacement { _, context in
            // fit smaller screens instead of opening larger than them
            let screen = context.defaultDisplay.visibleRect.size
            return WindowPlacement(size: CGSize(width: min(1180, screen.width * 0.9), height: min(760, screen.height * 0.9)))
        }
        .defaultLaunchBehavior(.presented)
        .commands { OrbitCommands(router: router) }

        WindowGroup("Display", id: SceneID.display, for: UUID.self) { $id in
            if let id, let vm = library.vm(with: id) {
                VMDisplayWindow(vm: vm)
                    .environment(library)
                    .environment(router)
                    .tint(Theme.ink)
            } else {
                // the machine was deleted while its window was open
                ClosingWindow()
            }
        }
        .defaultSize(width: 1280, height: 820)
        .defaultWindowPlacement { _, context in
            // a VM window sized to the screen it opens on: large, 16:10, never bigger than the screen
            let screen = context.defaultDisplay.visibleRect.size
            let width = min(1600, screen.width * 0.85)
            let height = min(screen.height * 0.85, width / 1.6 + 52)
            return WindowPlacement(size: CGSize(width: width, height: height))
        }
        .windowToolbarStyle(.unifiedCompact)
        .restorationBehavior(.disabled)

        Settings {
            PreferencesView()
                .environment(library)
                .tint(Theme.ink)
        }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarView()
                .environment(library)
                .environment(router)
                .tint(Theme.ink)
        } label: {
            MenuBarLabel(runningCount: library.runningCount)
        }
        .menuBarExtraStyle(.window)
    }
}

enum SceneID {
    static let library = "library"
    static let display = "display"
}

/// Cross-window UI requests (menu bar → library, commands → sheets).
@Observable
@MainActor
final class AppRouter {
    static let shared = AppRouter()

    var selection: UUID?
    var isShowingWizard = false
    var isShowingImporter = false
    var isShowingInspector = false
    /// File (installer or disk) preselected when the wizard opens, e.g. after a drop.
    var pendingFile: URL?
    var pendingTemplateID: String?

    /// Registered by any live view, so non-view code (Finder "Open With", menu bar)
    /// can bring the library window back after it was closed.
    @ObservationIgnored var openWindowAction: OpenWindowAction?

    func showLibrary() {
        openWindowAction?(id: SceneID.library)
        NSApp.activate()
    }
}

private struct ClosingWindow: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Color.clear.onAppear { dismiss() }
    }
}

/// Menu bar icon; also keeps a window opener available while the library is closed.
struct MenuBarLabel: View {
    let runningCount: Int
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // the app icon's planet and ring; a moon joins the orbit while machines run
        Image(runningCount > 0 ? "MenuBarIconActive" : "MenuBarIcon")
            .accessibilityLabel(runningCount > 0 ? "Orbit, \(runningCount) running" : "Orbit")
            .onAppear { AppRouter.shared.openWindowAction = openWindow }
    }
}
