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
            if vm.config.installerMedia != nil {
                InstallGuideButton(vm: vm, label: false)
            }
            Button { isPickingFolder = true } label: { Label("Share Folder", systemImage: "folder.badge.plus") }
                .help("Share a Mac folder with the guest (live)")
            if #available(macOS 27, *), USBPassthrough.isAvailable {
                USBMenu(vm: vm)
            }
            if vm.config.guestOS != .macOS && vm.config.display.dynamicResolution {
                Menu {
                    Picker("Text Size", selection: Binding(get: { vm.config.display.effectiveScaling }, set: { vm.config.display.scaling = $0 })) {
                        ForEach(DisplayScaling.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Text Size", systemImage: "textformat.size")
                }
                .help("How large the guest looks: Sharp, Medium or Large")
            }
            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help("Full screen (⌃⌘F)")
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
        // macOS guests scale themselves; for others Orbit sizes the display so text size is a choice
        let managed = automaticallyReconfiguresDisplay && !isMacGuest
        view.automaticallyReconfiguresDisplay = automaticallyReconfiguresDisplay && !managed
        coordinator.scaling = managed ? scaling : nil
        coordinator.resize(view)
        backend.displayView = view
    }

    @MainActor
    final class Coordinator {
        var scaling: DisplayScaling?
        private var pending: DispatchWorkItem?
        private var lastSize: CGSize = .zero
        private var observers: [NSObjectProtocol] = []

        func observe(_ view: VZVirtualMachineView) {
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let self, let view else { return }
                    self.resize(view)
                }
            })
            // moving the window between a Retina screen and an external monitor changes its pixel density
            observers.append(center.addObserver(forName: NSWindow.didChangeBackingPropertiesNotification, object: nil, queue: .main) { [weak self, weak view] note in
                MainActor.assumeIsolated {
                    guard let self, let view, (note.object as? NSWindow) === view.window else { return }
                    self.lastSize = .zero
                    self.resize(view)
                }
            })
        }

        /// Debounced: live window resizing would otherwise reconfigure the guest dozens of times a second.
        func resize(_ view: VZVirtualMachineView) {
            guard let scaling, view.bounds.width > 100, view.bounds.height > 100 else { return }
            let pixelsPerPoint = scaling.pixelsPerPoint(backingScale: view.window?.backingScaleFactor ?? 2)
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
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

/// USB devices plugged into the Mac, each one a toggle: on gives it to this machine.
@available(macOS 27, *)
private struct USBMenu: View {
    let vm: VMInstance
    @State private var usb = USBPassthrough.shared

    var body: some View {
        Menu {
            if usb.devices.isEmpty {
                Text("No USB devices connected")
            }
            ForEach(usb.devices) { device in
                let owner = usb.owner(of: device)
                Toggle(isOn: Binding(
                    get: { owner == vm.id },
                    set: { on in
                        Task {
                            do {
                                if on { try await usb.attach(device, to: vm) } else { try await usb.detach(device, from: vm) }
                            } catch {
                                vm.report(error)
                            }
                        }
                    })) {
                    Text(device.name)
                    if let owner, owner != vm.id {
                        Text("In use by \(VMLibrary.shared.vm(with: owner)?.config.name ?? "another machine")")
                    }
                }
                .disabled(owner != nil && owner != vm.id)
            }
            Divider()
            Text("A device given to this machine is unavailable to macOS until you turn it off here, the machine shuts down, or you unplug it.")
        } label: {
            Label("USB", systemImage: "cable.connector")
        }
        .help("Connect a USB device from this Mac to the guest")
        .disabled(vm.state != .running)
        .onAppear { usb.start() }
    }
}
