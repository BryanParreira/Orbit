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
        .defaultLaunchBehavior(.presented)
        .commands { OrbitCommands(router: router) }

        WindowGroup("Display", id: SceneID.display, for: UUID.self) { $id in
            if let id, let vm = library.vm(with: id) {
                VMDisplayWindow(vm: vm)
                    .environment(library)
                    .environment(router)
                    .tint(Theme.ink)
            }
        }
        .defaultSize(width: 1280, height: 820)
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
