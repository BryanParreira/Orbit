import SwiftUI

/// "All Machines": every VM as a large live card, acted on directly. Orbit's home screen.
struct GalleryView: View {
    @Environment(VMLibrary.self) private var library
    @Environment(AppRouter.self) private var router

    private var running: Int { library.vms.filter { $0.state.isActive }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if !library.unreachableMachines.isEmpty {
                    unreachableNotice
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270, maximum: 420), spacing: 20, alignment: .top)], spacing: 24) {
                    ForEach(library.vms) { vm in
                        MachineCard(vm: vm)
                    }
                    NewMachineCard()
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle("All Machines")
        .toolbar(removing: .title)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("All Machines")
                    .font(.system(size: 26, weight: .semibold))
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                router.isShowingWizard = true
            } label: {
                Label("New", systemImage: "plus")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .tint(Theme.ink)
        }
    }

    private var unreachableNotice: some View {
        let count = library.unreachableMachines.count
        let names = library.unreachableMachines.map { "“\($0.deletingPathExtension().lastPathComponent)”" }.formatted(.list(type: .and))
        return HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("\(names) \(count == 1 ? "is" : "are") on a drive that isn't connected. \(count == 1 ? "It comes" : "They come") back when you connect it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            SettingsLink { Text("Manage") }
        }
        .padding(14)
        .surface(radius: 12)
    }

    private var summary: String {
        let count = library.vms.count
        let machines = "\(count) machine\(count == 1 ? "" : "s")"
        guard running > 0 else { return "\(machines) · none running" }
        let memory = library.vms.filter { $0.state.isActive }.reduce(0) { $0 + $1.config.memoryMiB }
        return "\(machines) · \(running) running · \(memory.formattedMemory) of \(HostInfo.memoryMiB.formattedMemory) memory in use"
    }
}

/// One machine: a live preview you can start, pause or open without leaving the gallery.
private struct MachineCard: View {
    let vm: VMInstance
    @Environment(\.openWindow) private var openWindow
    @Environment(VMLibrary.self) private var library
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            preview
            HStack(alignment: .center, spacing: 10) {
                OSArtwork(config: vm.config, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.config.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        StatusDot(state: vm.state)
                        statusText
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                Menu {
                    VMActionsMenu(vm: vm)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 26, height: 26)
                        .contentShape(.rect)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(hovering ? 1 : 0.5)
            }
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            Task { await VMActions.startAndShow(vm, openWindow: openWindow) }
        }
        .onTapGesture {
            AppRouter.shared.selection = vm.id
        }
        .contextMenu { VMActionsMenu(vm: vm) }
        .animation(.easeOut(duration: 0.18), value: hovering)
    }

    @ViewBuilder
    private var statusText: some View {
        if let status = vm.installStatus {
            Text(status)
        } else if let since = vm.startedAt, vm.state == .running {
            HStack(spacing: 4) {
                Text("Running")
                Text("·")
                UptimeText(since: since)
            }
        } else if vm.state == .stopped && vm.hasSavedState {
            Text("Suspended")
        } else if vm.state == .stopped {
            Text(vm.config.specLine)
        } else {
            Text(vm.state.label)
        }
    }

    private var preview: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return ZStack {
            Color.black
            if let image = vm.screenshot {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(vm.state == .running ? 1 : 0.5)
                    .grayscale(vm.state == .running ? 0 : 1)
            } else {
                RadialGradient(colors: [Color.white.opacity(0.07), .clear], center: .center, startRadius: 0, endRadius: 220)
                // hidden under the progress overlay, where it would smudge through the glass
                if vm.installStatus == nil && !vm.state.isBusy {
                    OSArtwork(config: vm.config, size: 56)
                        .environment(\.colorScheme, .dark)
                        .opacity(0.9)
                }
            }
            overlay
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.primary.opacity(hovering ? 0.25 : 0.08)) }
        .shadow(color: .black.opacity(hovering ? 0.3 : 0.15), radius: hovering ? 18 : 10, y: hovering ? 10 : 5)
        .scaleEffect(hovering ? 1.015 : 1)
    }

    @ViewBuilder
    private var overlay: some View {
        if let progress = vm.activeDownload?.fraction ?? vm.installProgress {
            VStack(spacing: 8) {
                ProgressView(value: progress)
                    .tint(.white)
                    .frame(width: 140)
                Text(vm.installStatus ?? "Installing…")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .environment(\.colorScheme, .dark)
        } else if vm.installStatus != nil || vm.state.isBusy {
            VStack(spacing: 8) {
                ProgressView().controlSize(.regular).tint(.white)
                Text(vm.installStatus ?? vm.state.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
        } else if hovering {
            HStack(spacing: 10) {
                switch vm.state {
                case .stopped, .paused:
                    CardButton(symbol: "play.fill", help: vm.hasSavedState || vm.state == .paused ? "Resume" : "Start") {
                        await VMActions.startAndShow(vm, openWindow: openWindow)
                    }
                case .running:
                    if vm.hasEmbeddedDisplay {
                        CardButton(symbol: "macwindow", help: "Open") { openWindow(id: SceneID.display, value: vm.id) }
                    }
                    CardButton(symbol: "pause.fill", help: "Pause") { await vm.pause() }
                    if vm.canSuspend && !vm.isDisposableRun {
                        CardButton(symbol: "moon.fill", help: "Suspend") { await vm.suspend() }
                    }
                    CardButton(symbol: "power", help: "Shut Down") { await vm.requestStop() }
                default:
                    EmptyView()
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }
}

private struct CardButton: View {
    let symbol: String
    let help: String
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(Circle().fill(.white.opacity(0.16)))
                .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct NewMachineCard: View {
    @Environment(AppRouter.self) private var router
    @State private var hovering = false

    var body: some View {
        Button {
            router.isShowingWizard = true
        } label: {
            // same footprint as a machine card: a 16:10 preview plus the name row below it
            VStack(alignment: .leading, spacing: 12) {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .background(Theme.surface, in: .rect(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.primary.opacity(hovering ? 0.3 : 0.12), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                    }
                    .overlay {
                        VStack(spacing: 10) {
                            Image(systemName: "plus")
                                .font(.system(size: 26, weight: .light))
                            Text("New Virtual Machine")
                                .font(.callout.weight(.medium))
                        }
                        .foregroundStyle(hovering ? .primary : .secondary)
                    }
                Color.clear.frame(height: 30)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
