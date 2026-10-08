import SwiftUI

struct OrbitCommands: Commands {
    let router: AppRouter
    @FocusedValue(\.selectedVM) private var vm

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesButton()
        }

        CommandGroup(replacing: .newItem) {
            Button("New Virtual Machine…") { router.isShowingWizard = true }
                .keyboardShortcut("n")
            Button("Import…") { router.isShowingImporter = true }
                .keyboardShortcut("o")
        }

        CommandMenu("Machine") {
            Button(vm?.state == .paused ? "Resume" : "Start") {
                guard let vm else { return }
                Task { vm.state == .paused ? await vm.resume() : await vm.start() }
            }
            .keyboardShortcut("r")
            .disabled(vm == nil || (vm!.state != .stopped && vm!.state != .paused))

            Button("Pause") { Task { await vm?.pause() } }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(vm?.state != .running)

            Button("Suspend") { Task { await vm?.suspend() } }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(vm?.state != .running || vm?.canSuspend == false)

            Button("Shut Down") { Task { await vm?.requestStop() } }
                .keyboardShortcut("q", modifiers: [.command, .option])
                .disabled(vm?.state != .running)

            Button("Force Stop") { Task { await vm?.forceStop() } }
                .keyboardShortcut("q", modifiers: [.command, .option, .shift])
                .disabled(vm?.state.isActive != true)

            Divider()

            Button("Take Snapshot") {
                guard let vm else { return }
                Task { await vm.takeSnapshot(named: Date.now.formatted(date: .abbreviated, time: .shortened)) }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(vm == nil || vm!.state.isBusy)

            Divider()

            Button("Show Settings Inspector") { router.isShowingInspector.toggle() }
                .keyboardShortcut("i")
        }
    }
}

extension FocusedValues {
    @Entry var selectedVM: VMInstance?
}

struct CheckForUpdatesButton: View {
    @State private var updater = AppUpdater.shared

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.isConfigured || !updater.canCheckForUpdates)
    }
}
