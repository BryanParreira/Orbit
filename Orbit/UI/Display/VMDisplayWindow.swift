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
                                      automaticallyReconfiguresDisplay: vm.config.display.dynamicResolution,
                                      scaling: vm.config.display.effectiveScaling,
                                      isMacGuest: vm.config.guestOS == .macOS)
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
///
/// macOS guests handle Retina themselves. For other guests Orbit sizes the guest display from
/// the window and the chosen text size, so a Linux desktop isn't rendered at half size.
struct VirtualMachineDisplay: NSViewRepresentable {
    let machine: VZVirtualMachine
    let backend: AppleBackend
    var capturesSystemKeys: Bool
    var automaticallyReconfiguresDisplay: Bool
    var scaling: DisplayScaling = .sharp
    var isMacGuest = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = machine
        view.postsFrameChangedNotifications = true
        context.coordinator.observe(view)
        configure(view, coordinator: context.coordinator)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== machine {
            view.virtualMachine = machine
        }
        configure(view, coordinator: context.coordinator)
    }

    private func configure(_ view: VZVirtualMachineView, coordinator: Coordinator) {
        view.capturesSystemKeys = capturesSystemKeys
        let managed = automaticallyReconfiguresDisplay && !isMacGuest && scaling != .sharp
        // VZ's own resizing uses full Retina pixels; for larger text Orbit sizes the display itself
        view.automaticallyReconfiguresDisplay = automaticallyReconfiguresDisplay && !managed
        coordinator.pixelsPerPoint = managed ? scaling.pixelsPerPoint : nil
        coordinator.resize(view)
        backend.displayView = view
    }

    @MainActor
    final class Coordinator {
        var pixelsPerPoint: CGFloat?
        private var pending: DispatchWorkItem?
        private var lastSize: CGSize = .zero
        private var observer: NSObjectProtocol?

        func observe(_ view: VZVirtualMachineView) {
            observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let self, let view else { return }
                    self.resize(view)
                }
            }
        }

        /// Debounced: live window resizing would otherwise reconfigure the guest dozens of times a second.
        func resize(_ view: VZVirtualMachineView) {
            guard let pixelsPerPoint, view.bounds.width > 100, view.bounds.height > 100 else { return }
            // even sizes, and never below what installers expect
            let width = max(1024, (view.bounds.width * pixelsPerPoint / 2).rounded() * 2)
            let height = max(640, (view.bounds.height * pixelsPerPoint / 2).rounded() * 2)
            let target = CGSize(width: width, height: height)
            guard target != lastSize else { return }
            pending?.cancel()
            let work = DispatchWorkItem { [weak self, weak view] in
                MainActor.assumeIsolated {
                    guard let self, let display = view?.virtualMachine?.graphicsDevices.first?.displays.first,
                          view?.virtualMachine?.state == .running else { return }
                    if (try? display.reconfigure(sizeInPixels: target)) != nil {
                        self.lastSize = target
                    }
                }
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
