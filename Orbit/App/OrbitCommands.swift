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

        CommandGroup(replacing: .help) {
            Link("Orbit User Guide", destination: HelpLinks.guide)
            Link("Shared Folders and Clipboard", destination: HelpLinks.section("sharing-files-and-the-clipboard"))
            Link("Troubleshooting", destination: HelpLinks.section("troubleshooting"))
            Divider()
            Link("Privacy and Security", destination: HelpLinks.security)
            Link("Release Notes", destination: HelpLinks.releases)
            Link("Report a Problem…", destination: HelpLinks.issues)
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

enum HelpLinks {
    private static let repo = "https://github.com/BryanParreira/Orbit"
    static let guide = URL(string: "\(repo)/blob/main/docs/GUIDE.md")!
    static let security = URL(string: "\(repo)/blob/main/SECURITY.md")!
    static let releases = URL(string: "\(repo)/releases")!
    static let issues = URL(string: "\(repo)/issues/new")!

    static func section(_ anchor: String) -> URL {
        URL(string: "\(repo)/blob/main/docs/GUIDE.md#\(anchor)")!
    }
}
