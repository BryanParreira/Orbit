import SwiftUI

/// Control every VM from the menu bar without opening the library.
struct MenuBarView: View {
    @Environment(VMLibrary.self) private var library
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image("MenuBarIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Orbit").font(.headline)
                    Text(library.runningCount == 0 ? "No machines running" : "\(library.runningCount) running")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if library.runningCount > 0 {
                let used = library.vms.filter { $0.state.isActive }.reduce(0) { $0 + $1.config.memoryMiB }
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(Color.primary.opacity(0.08)).frame(height: 3)
                        .overlay(alignment: .leading) {
                            GeometryReader { geo in
                                Capsule().fill(Color.primary.opacity(0.55))
                                    .frame(width: max(3, geo.size.width * min(1, Double(used) / Double(max(1, HostInfo.memoryMiB)))))
                            }
                        }
                    Text("\(used.formattedMemory) of \(HostInfo.memoryMiB.formattedMemory) memory in use")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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

    /// The machine's last frame, so you can tell machines apart at a glance.
    private var thumbnail: some View {
        ZStack {
            Color.black
            if let image = vm.screenshot {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .opacity(vm.state == .running ? 1 : 0.5)
            } else {
                OSArtwork(config: vm.config, size: 22).environment(\.colorScheme, .dark)
            }
        }
        .frame(width: 56, height: 35)
        .clipShape(.rect(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
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
