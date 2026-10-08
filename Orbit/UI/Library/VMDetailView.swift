import SwiftUI

struct VMDetailView: View {
    let vm: VMInstance
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HeaderView(vm: vm)
                PreviewView(vm: vm)
                Banners(vm: vm)
                OverviewGrid(vm: vm)
                SnapshotsSection(vm: vm)
                NotesSection(vm: vm)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle("")
        .inspector(isPresented: $router.isShowingInspector) {
            VMSettingsView(vm: vm)
                .inspectorColumnWidth(min: 330, ideal: 370, max: 480)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    router.isShowingInspector.toggle()
                } label: {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
                .help("Settings (⌘I)")
            }
        }
        .errorAlert(for: vm)
    }
}

// MARK: - Header

private struct HeaderView: View {
    let vm: VMInstance

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            OSArtwork(config: vm.config, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(vm.config.name)
                    .font(.system(size: 26, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    StatusDot(state: vm.state)
                    Text(statusText)
                    if let since = vm.startedAt, vm.state == .running {
                        Text("·")
                        UptimeText(since: since)
                    }
                    Text("·")
                    Text(subtitle)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 16)
            ActionBar(vm: vm)
        }
    }

    private var statusText: String {
        if let status = vm.installStatus { return status }
        if vm.state == .stopped && vm.hasSavedState { return "Suspended" }
        return vm.isDisposableRun ? "\(vm.state.label) · Disposable" : vm.state.label
    }

    private var subtitle: String {
        var parts = [vm.config.guestOS.displayName]
        switch vm.config.engine {
        case .apple: parts.append("Apple Virtualization")
        case .qemu: parts.append(vm.config.architecture.isNative ? "QEMU · HVF" : "QEMU · Emulated")
        }
        return parts.joined(separator: " · ")
    }
}

private struct ActionBar: View {
    let vm: VMInstance
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                switch vm.state {
                case .stopped:
                    Button { Task { await VMActions.startAndShow(vm, openWindow: openWindow) } } label: {
                        Label(vm.hasSavedState ? "Resume" : "Start", systemImage: "play.fill")
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(vm.installStatus != nil)
                case .running:
                    if vm.hasEmbeddedDisplay {
                        Button { openWindow(id: SceneID.display, value: vm.id) } label: {
                            Label("Open", systemImage: "macwindow").padding(.horizontal, 4)
                        }
                        .buttonStyle(.glassProminent)
                    }
                    iconButton("Pause", "pause.fill") { await vm.pause() }
                    if vm.canSuspend && !vm.isDisposableRun {
                        iconButton("Suspend", "moon.fill") { await vm.suspend() }
                    }
                    iconButton("Shut Down", "power") { await vm.requestStop() }
                case .paused:
                    Button { Task { await vm.resume() } } label: {
                        Label("Resume", systemImage: "play.fill").padding(.horizontal, 4)
                    }
                    .buttonStyle(.glassProminent)
                    iconButton("Stop", "stop.fill") { await vm.forceStop() }
                default:
                    iconButton("Force Stop", "stop.fill") { await vm.forceStop() }
                        .disabled(vm.state == .installing)
                }
                Menu {
                    VMActionsMenu(vm: vm)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 18, height: 18)
                }
                .menuIndicator(.hidden)
                .menuStyle(.button)
                .buttonStyle(.glass)
                .fixedSize()
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
        .tint(Theme.ink)
    }

    private func iconButton(_ title: String, _ symbol: String, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Image(systemName: symbol).frame(width: 18, height: 18)
        }
        .help(title)
        .accessibilityLabel(title)
    }
}

// MARK: - Preview

/// The guest's screen in a quiet bezel; the last frame when stopped.
private struct PreviewView: View {
    let vm: VMInstance
    @Environment(\.openWindow) private var openWindow
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.heroRadius, style: .continuous)
        Color.black
            .frame(maxWidth: .infinity)
            .frame(height: 380)
            .overlay { screen }
            .overlay { center }
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color.white.opacity(0.08)) }
            .shadow(color: .black.opacity(0.22), radius: 24, y: 12)
            .onHover { hovering = $0 }
            .onTapGesture(count: 2) {
                Task { await VMActions.startAndShow(vm, openWindow: openWindow) }
            }
    }

    @ViewBuilder
    private var screen: some View {
        if let image = vm.screenshot {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .opacity(vm.state == .running ? 1 : 0.45)
                .grayscale(vm.state == .running ? 0 : 1)
        } else {
            ZStack {
                RadialGradient(colors: [Color.white.opacity(0.07), .clear], center: .center, startRadius: 0, endRadius: 420)
                OSArtwork(config: vm.config, size: 76)
                    .environment(\.colorScheme, .dark)
                    .opacity(0.9)
            }
        }
    }

    @ViewBuilder
    private var center: some View {
        if vm.installStatus != nil || vm.state == .installing {
            InstallProgressCard(vm: vm)
                .environment(\.colorScheme, .dark)
        } else if vm.state == .stopped || vm.state == .paused {
            Button {
                Task { await VMActions.startAndShow(vm, openWindow: openWindow) }
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .offset(x: 2)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(.white.opacity(hovering ? 0.2 : 0.12)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .scaleEffect(hovering ? 1.05 : 1)
            .animation(.spring(duration: 0.3), value: hovering)
            .help(vm.hasSavedState ? "Resume where you left off" : "Start")
        } else if vm.state == .running && vm.hasEmbeddedDisplay {
            Button {
                openWindow(id: SceneID.display, value: vm.id)
            } label: {
                Label("Open Display", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .glassEffect(.regular.interactive(), in: .capsule)
            .environment(\.colorScheme, .dark)
            .opacity(hovering ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: hovering)
        } else if vm.state.isBusy {
            ProgressView().controlSize(.large).tint(.white)
        }
    }
}

private struct InstallProgressCard: View {
    let vm: VMInstance

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(vm.installStatus ?? "Installing…")
                .font(.headline)
            if let download = vm.activeDownload {
                ProgressView(value: download.fraction)
                HStack {
                    Text("\(download.receivedBytes.formattedBytes) of \(download.expectedBytes > 0 ? download.expectedBytes.formattedBytes : "…")")
                    Spacer()
                    if download.bytesPerSecond > 0 {
                        Text("\(Int64(download.bytesPerSecond).formattedBytes)/s")
                    }
                    if let eta = download.etaSeconds {
                        Text("· \(eta.formattedDuration)")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                Button("Cancel") { download.cancel() }
                    .controlSize(.small)
            } else if let progress = vm.installProgress {
                ProgressView(value: progress)
                Text("\(Int(progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
        .tint(.white)
        .frame(width: 340)
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

// MARK: - Banners

private struct Banners: View {
    let vm: VMInstance

    var body: some View {
        let items = VStack(spacing: 8) {
            if vm.hasSavedState && vm.state == .stopped {
                Banner(symbol: "moon.fill", title: "Suspended",
                       message: "Memory is saved. Start resumes exactly where you left off.") {
                    Button("Discard") { vm.discardSavedState() }
                }
            }
            if let installer = vm.config.installerMedia, vm.installStatus == nil {
                Banner(symbol: "opticaldisc", title: "Installer attached",
                       message: URL(fileURLWithPath: installer.path).lastPathComponent) {
                    Button("Eject") { vm.ejectInstaller() }
                        .disabled(vm.state.isActive)
                        .help(vm.state.isActive ? "Shut down to eject" : "Remove the installer once the OS is installed")
                }
            }
            if vm.config.engine == .qemu && !HostInfo.isQEMUInstalled {
                Banner(symbol: "shippingbox", title: "QEMU required",
                       message: "Install it from Settings → Engines, or run brew install qemu.") {
                    SettingsLink { Text("Settings") }
                }
            }
        }
        items
    }
}

private struct Banner<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(title).font(.callout.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            actions.controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .surface(radius: 12)
    }
}

// MARK: - Overview

private struct OverviewGrid: View {
    let vm: VMInstance

    var body: some View {
        let c = vm.config
        let diskTotal = Int64(c.totalDiskGiB) * 1_073_741_824
        Card(title: "Overview") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                SpecTile(symbol: "cpu", caption: "Processor", value: "\(c.cpuCount) cores",
                         detail: c.architecture.displayName + (c.architecture.isNative ? " · native" : " · emulated"))
                SpecTile(symbol: "memorychip", caption: "Memory", value: c.memoryMiB.formattedMemory,
                         detail: "of \(HostInfo.memoryMiB.formattedMemory) on this Mac",
                         usage: Double(c.memoryMiB) / Double(max(1, HostInfo.memoryMiB)))
                SpecTile(symbol: "internaldrive", caption: "Storage", value: vm.diskUsageBytes.formattedBytes,
                         detail: "used of \(c.totalDiskGiB) GB",
                         usage: diskTotal > 0 ? Double(vm.diskUsageBytes) / Double(diskTotal) : nil)
                SpecTile(symbol: "network", caption: "Network", value: c.network.mode.displayName,
                         detail: c.network.mode == .none ? nil : c.network.macAddress)
                SpecTile(symbol: "display", caption: "Display", value: "\(c.display.widthPixels) × \(c.display.heightPixels)",
                         detail: c.display.dynamicResolution ? "Follows window size" : "Fixed")
                SpecTile(symbol: "bolt", caption: "Engine", value: c.engine == .apple ? "Apple Virtualization" : "QEMU",
                         detail: "\(c.diskPerformance.displayName) disk I/O")
            }
        }
    }
}

// MARK: - Snapshots

private struct SnapshotsSection: View {
    let vm: VMInstance
    @State private var isNaming = false
    @State private var name = ""

    private var canSnapshot: Bool {
        !vm.state.isBusy && vm.installStatus == nil && !(vm.state.isActive && !vm.canSuspend) && !vm.isDisposableRun
    }

    var body: some View {
        Card(title: "Snapshots") {
            Button {
                name = Date.now.formatted(date: .abbreviated, time: .shortened)
                isNaming = true
            } label: {
                Label("Take Snapshot", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(!canSnapshot)
        } content: {
            if vm.snapshots.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No snapshots").font(.callout.weight(.medium))
                        Text("Instant APFS clones. They use no space until the machine changes.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .surface()
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(vm.snapshots) { snapshot in
                            SnapshotThumb(vm: vm, snapshot: snapshot)
                        }
                    }
                    .padding(.bottom, 4)
                }
                .scrollIndicators(.hidden)
            }
        }
        .alert("New Snapshot", isPresented: $isNaming) {
            TextField("Name", text: $name)
            Button("Take Snapshot") { Task { await vm.takeSnapshot(named: name) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(vm.state.isActive ? "The machine pauses for a moment while its memory is saved." : "Captures the disks as they are now.")
        }
    }
}

private struct SnapshotThumb: View {
    let vm: VMInstance
    let snapshot: VMSnapshot
    @State private var confirmRestore = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.black
                if let image = NSImage(contentsOf: SnapshotStore.screenshotURL(for: snapshot, in: vm.bundle)) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    OSArtwork(config: vm.config, size: 32).environment(\.colorScheme, .dark)
                }
            }
            .frame(width: 176, height: 110)
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline)
            }
            .overlay(alignment: .bottomTrailing) {
                if hovering {
                    Button("Restore") { confirmRestore = true }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .environment(\.colorScheme, .dark)
                        .padding(6)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(snapshot.name).font(.callout.weight(.medium)).lineLimit(1)
                    if snapshot.includesMemory {
                        Image(systemName: "memorychip")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Includes memory: restores to the running state")
                    }
                }
                Text(snapshot.createdAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 176)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Restore…", systemImage: "clock.arrow.circlepath") { confirmRestore = true }
            Button("Delete", systemImage: "trash", role: .destructive) { vm.delete(snapshot) }
        }
        .confirmationDialog("Restore “\(snapshot.name)”?", isPresented: $confirmRestore) {
            Button("Restore", role: .destructive) { Task { await vm.restore(snapshot) } }
        } message: {
            Text("The machine's current state is replaced. Take a snapshot first to keep it.")
        }
    }
}

// MARK: - Notes

private struct NotesSection: View {
    let vm: VMInstance

    var body: some View {
        @Bindable var vm = vm
        Card(title: "Notes") {
            TextField("What this machine is for, login hints, setup steps…", text: $vm.config.notes, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3...12)
                .padding(14)
                .surface()
        }
    }
}

// MARK: - Error alert

extension View {
    func errorAlert(for vm: VMInstance) -> some View {
        modifier(ErrorAlert(vm: vm))
    }
}

private struct ErrorAlert: ViewModifier {
    let vm: VMInstance

    func body(content: Content) -> some View {
        content.alert("Something went wrong",
                      isPresented: Binding(get: { vm.lastError != nil }, set: { if !$0 { vm.lastError = nil } })) {
            Button("OK", role: .cancel) { vm.lastError = nil }
        } message: {
            Text(vm.lastError ?? "")
        }
    }
}
