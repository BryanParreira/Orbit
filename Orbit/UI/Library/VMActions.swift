import SwiftUI

/// Actions shared by the sidebar, detail view, menu bar and display window.
@MainActor
enum VMActions {
    static func startAndShow(_ vm: VMInstance, openWindow: OpenWindowAction, options: StartOptions = []) async {
        guard vm.installStatus == nil else { return }
        if vm.hasEmbeddedDisplay {
            openWindow(id: SceneID.display, value: vm.id)
        }
        switch vm.state {
        case .stopped: await vm.start(options: options)
        case .paused: await vm.resume()
        default: break
        }
        if !vm.hasEmbeddedDisplay {
            (vm.backend as? QEMUBackend)?.bringToFront()
        }
    }

    /// Opens the delete sheet, which shows what will be removed before anything happens.
    static func confirmDelete(_ vm: VMInstance, library: VMLibrary) {
        AppRouter.shared.showLibrary()
        AppRouter.shared.deleting = vm
    }

    /// Ask for a folder to keep machines in, on any drive.
    static func chooseFolder(message: String, prompt: String, startingAt directory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = message
        panel.prompt = prompt
        panel.directoryURL = directory
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Move a machine to a folder the user picks, such as an external drive.
    static func move(_ vm: VMInstance, library: VMLibrary) {
        guard let folder = chooseFolder(message: "Choose where to keep “\(vm.config.name)”. Everything it uses moves with it.",
                                        prompt: "Move Here", startingAt: vm.bundle.url.deletingLastPathComponent()) else { return }
        Task {
            do {
                let moved = try await library.move(vm, to: folder)
                if AppRouter.shared.selection == vm.id { AppRouter.shared.selection = moved.id }
            } catch {
                vm.report(error)
            }
        }
    }

    static func moveToLibrary(_ vm: VMInstance, library: VMLibrary) {
        Task {
            do {
                try await library.move(vm, to: library.rootURL)
            } catch {
                vm.report(error)
            }
        }
    }

    static func duplicate(_ vm: VMInstance, library: VMLibrary) {
        Task {
            do {
                let copy = try await library.duplicate(vm)
                AppRouter.shared.selection = copy.id
            } catch {
                vm.report(error)
            }
        }
    }
}

struct VMActionsMenu: View {
    let vm: VMInstance
    @Environment(VMLibrary.self) private var library
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch vm.state {
            case .stopped:
                Button("Start", systemImage: "play.fill") { Task { await VMActions.startAndShow(vm, openWindow: openWindow) } }
                    .disabled(vm.installStatus != nil)
                Menu("Start Options") {
                    Button("Disposable Session", systemImage: "trash.slash") {
                        Task { await VMActions.startAndShow(vm, openWindow: openWindow, options: .disposable) }
                    }
                    if vm.hasSavedState {
                        Button("Cold Boot (discard saved state)", systemImage: "snowflake") {
                            Task { await VMActions.startAndShow(vm, openWindow: openWindow, options: .coldBoot) }
                        }
                    }
                    if vm.config.guestOS == .macOS {
                        Button("Recovery Mode", systemImage: "lifepreserver") {
                            Task { await VMActions.startAndShow(vm, openWindow: openWindow, options: .recovery) }
                        }
                    }
                }
            case .paused:
                Button("Resume", systemImage: "play.fill") { Task { await vm.resume() } }
                Button("Shut Down", systemImage: "power") { Task { await vm.requestStop() } }
            case .running:
                if vm.hasEmbeddedDisplay {
                    Button("Show Display", systemImage: "display") { openWindow(id: SceneID.display, value: vm.id) }
                }
                Button("Pause", systemImage: "pause.fill") { Task { await vm.pause() } }
                if vm.canSuspend {
                    Button("Suspend", systemImage: "moon.zzz.fill") { Task { await vm.suspend() } }
                }
                Button("Shut Down", systemImage: "power") { Task { await vm.requestStop() } }
                Button("Force Stop", systemImage: "bolt.slash.fill") { Task { await vm.forceStop() } }
            default:
                Button("Force Stop", systemImage: "bolt.slash.fill") { Task { await vm.forceStop() } }
                    .disabled(vm.state == .installing)
            }
            Divider()
            Button("Duplicate", systemImage: "plus.square.on.square") { VMActions.duplicate(vm, library: library) }
                .disabled(vm.state.isActive)
            Button("Move…", systemImage: "externaldrive") { VMActions.move(vm, library: library) }
                .disabled(vm.state.isActive || vm.installStatus != nil)
            if library.isOutsideLibrary(vm) {
                Button("Move to Library", systemImage: "tray.and.arrow.down") { VMActions.moveToLibrary(vm, library: library) }
                    .disabled(vm.state.isActive || vm.installStatus != nil)
            }
            Button("Show in Finder", systemImage: "folder") { library.revealInFinder(vm) }
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive) { VMActions.confirmDelete(vm, library: library) }
                .disabled(vm.state == .installing)
        }
    }
}
