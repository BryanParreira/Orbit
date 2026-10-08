import SwiftUI

/// Control every VM from the menu bar without opening the library.
struct MenuBarView: View {
    @Environment(VMLibrary.self) private var library
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Orbit").font(.headline)
                Spacer()
                Text("\(library.runningCount) running").font(.caption).foregroundStyle(.secondary)
            }
            if library.vms.isEmpty {
                Text("No virtual machines yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                VStack(spacing: 4) {
                    ForEach(library.vms) { vm in
                        MenuBarRow(vm: vm)
                    }
                }
            }
            Divider()
            HStack {
                Button("Open Orbit") {
                    openWindow(id: SceneID.library)
                    NSApp.activate()
                }
                Spacer()
                CheckForUpdatesButton()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 320)
    }
}

private struct MenuBarRow: View {
    let vm: VMInstance
    @Environment(\.openWindow) private var openWindow
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            OSArtwork(config: vm.config, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(vm.config.name).lineLimit(1)
                HStack(spacing: 4) {
                    StatusDot(state: vm.state)
                    if let since = vm.startedAt, vm.state == .running {
                        UptimeText(since: since)
                    } else {
                        Text(vm.hasSavedState && vm.state == .stopped ? "Suspended" : vm.state.label)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if vm.state == .running {
                Button { Task { await vm.pause() } } label: { Image(systemName: "pause.fill") }
                    .help("Pause")
                Button { Task { await vm.requestStop() } } label: { Image(systemName: "power") }
                    .help("Shut Down")
            } else if vm.state == .stopped || vm.state == .paused {
                Button {
                    Task {
                        await VMActions.startAndShow(vm, openWindow: openWindow)
                        NSApp.activate()
                    }
                } label: {
                    Image(systemName: "play.fill")
                }
                .help(vm.state == .paused ? "Resume" : "Start")
                .disabled(vm.installStatus != nil)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .buttonStyle(.borderless)
        .padding(6)
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 8))
        .onHover { hovering = $0 }
        .contentShape(.rect)
        .onTapGesture {
            AppRouter.shared.selection = vm.id
            if vm.state.isActive && vm.hasEmbeddedDisplay {
                openWindow(id: SceneID.display, value: vm.id)
            } else {
                openWindow(id: SceneID.library)
            }
            NSApp.activate()
        }
    }
}
