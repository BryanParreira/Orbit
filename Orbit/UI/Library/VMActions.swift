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

    static func confirmDelete(_ vm: VMInstance, library: VMLibrary) {
        let alert = NSAlert()
        alert.messageText = "Move “\(vm.config.name)” to the Trash?"
        alert.informativeText = "Its disks, snapshots and saved state go with it. You can restore it from the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                try await library.delete(vm)
                if AppRouter.shared.selection == vm.id {
                    AppRouter.shared.selection = library.vms.first?.id
                }
            } catch {
                vm.lastError = error.localizedDescription
            }
        }
    }

    static func duplicate(_ vm: VMInstance, library: VMLibrary) {
        do {
            let copy = try library.duplicate(vm)
            AppRouter.shared.selection = copy.id
        } catch {
            vm.lastError = error.localizedDescription
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
            Button("Show in Finder", systemImage: "folder") { library.revealInFinder(vm) }
            Divider()
            Button("Move to Trash…", systemImage: "trash", role: .destructive) { VMActions.confirmDelete(vm, library: library) }
                .disabled(vm.state == .installing)
        }
    }
}
