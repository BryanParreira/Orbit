import SwiftUI
import Virtualization

struct VMDisplayWindow: View {
    let vm: VMInstance
    @AppStorage(PreferenceKey.captureSystemKeys) private var captureSystemKeys = true
    @Environment(\.dismiss) private var dismiss
    @State private var isPickingFolder = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let backend = vm.appleBackend, let machine = backend.virtualMachine, vm.state != .stopped {
                VirtualMachineDisplay(machine: machine, backend: backend,
                                      capturesSystemKeys: captureSystemKeys,
                                      automaticallyReconfiguresDisplay: vm.config.display.dynamicResolution)
            } else {
                StoppedOverlay(vm: vm)
            }
            if vm.isCapturingScreenshot {
                EmptyView()
            } else if vm.state == .paused {
                PausedOverlay(vm: vm)
            } else if vm.state.isBusy {
                ProgressView(vm.state.label)
                    .padding(20)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
            }
        }
        .transaction { if vm.isCapturingScreenshot { $0.disablesAnimations = true } }
        .navigationTitle(vm.config.name)
        .navigationSubtitle(vm.isDisposableRun ? "\(vm.state.label) · Disposable" : vm.state.label)
        .toolbar { toolbar }
        .onDisappear { Task { await vm.captureScreenshot() } }
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                vm.config.sharedFolders += urls.map { SharedFolder(path: $0.path) }
            }
        }
        .errorAlert(for: vm)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if vm.state == .paused {
                Button { Task { await vm.resume() } } label: { Label("Resume", systemImage: "play.fill") }
            } else {
                Button { Task { await vm.pause() } } label: { Label("Pause", systemImage: "pause.fill") }
                    .disabled(vm.state != .running)
            }
            Button { Task { await vm.restart() } } label: { Label("Restart", systemImage: "arrow.clockwise") }
                .disabled(vm.state != .running)
            Menu {
                Button("Shut Down", systemImage: "power") { Task { await vm.requestStop() } }
                if vm.canSuspend && !vm.isDisposableRun {
                    Button("Suspend", systemImage: "moon.zzz.fill") {
                        Task {
                            await vm.suspend()
                            dismiss()
                        }
                    }
                }
                Divider()
                Button("Force Stop", systemImage: "bolt.slash.fill", role: .destructive) { Task { await vm.forceStop() } }
            } label: {
                Label("Power", systemImage: "power")
            }
            .disabled(!(vm.state == .running || vm.state == .paused))
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await vm.takeSnapshot(named: Date.now.formatted(date: .abbreviated, time: .shortened)) }
            } label: {
                Label("Snapshot", systemImage: "camera")
            }
            .help("Take a snapshot (memory included)")
            .disabled(vm.state != .running || !vm.canSuspend || vm.isDisposableRun)
            Button { isPickingFolder = true } label: { Label("Share Folder", systemImage: "folder.badge.plus") }
                .help("Share a Mac folder with the guest (live)")
            Toggle(isOn: $captureSystemKeys) {
                Label("Capture System Keys", systemImage: captureSystemKeys ? "command.circle.fill" : "command.circle")
            }
            .help("Send ⌘Tab, ⌘Space and other system shortcuts to the guest")
        }
    }
}

private struct StoppedOverlay: View {
    let vm: VMInstance

    var body: some View {
        ZStack {
            if let image = vm.screenshot {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(0.35)
                    .blur(radius: 4)
            }
            if vm.state == .stopped {
                VStack(spacing: 14) {
                    OSArtwork(config: vm.config, size: 64)
                    Text(vm.hasSavedState ? "Suspended" : "Stopped").font(.title2.weight(.semibold)).foregroundStyle(.white)
                    Button {
                        Task { await vm.start() }
                    } label: {
                        Label(vm.hasSavedState ? "Resume" : "Start", systemImage: "play.fill")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.extraLarge)
                    .disabled(vm.installStatus != nil)
                }
            }
        }
    }
}

private struct PausedOverlay: View {
    let vm: VMInstance

    var body: some View {
        Button {
            Task { await vm.resume() }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "pause.fill").font(.system(size: 38))
                Text("Paused · click to resume").font(.headline)
            }
            .padding(28)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
    }
}

/// Hosts Apple's `VZVirtualMachineView`, which renders the guest with Metal and forwards input.
struct VirtualMachineDisplay: NSViewRepresentable {
    let machine: VZVirtualMachine
    let backend: AppleBackend
    var capturesSystemKeys: Bool
    var automaticallyReconfiguresDisplay: Bool

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = machine
        configure(view)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== machine {
            view.virtualMachine = machine
        }
        configure(view)
    }

    private func configure(_ view: VZVirtualMachineView) {
        view.capturesSystemKeys = capturesSystemKeys
        view.automaticallyReconfiguresDisplay = automaticallyReconfiguresDisplay
        backend.displayView = view
    }
}
