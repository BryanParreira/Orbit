import SwiftUI
import Virtualization

/// Live inspector instead of UTM's modal settings dialog: edits save automatically.
struct VMSettingsView: View {
    let vm: VMInstance

    var body: some View {
        @Bindable var vm = vm
        Form {
            if vm.state.isActive {
                Label("Most changes apply the next time the machine starts. Shared folders update live.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if vm.hasSavedState {
                Label("This machine is suspended. Changing its hardware means the next start is a fresh boot instead of a resume.", systemImage: "moon")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            GeneralSection(config: $vm.config)
            SystemSection(config: $vm.config)
            DisplaySection(config: $vm.config)
            StorageSection(vm: vm)
            NetworkSection(config: $vm.config)
            SharingSection(config: $vm.config)
            AdvancedSection(config: $vm.config)
        }
        .formStyle(.grouped)
    }
}

private struct GeneralSection: View {
    @Binding var config: VMConfiguration

    var body: some View {
        Section("General") {
            TextField("Name", text: $config.name)
            LabeledContent("Engine", value: config.engine.displayName)
            LabeledContent("Guest", value: "\(config.guestOS.displayName) · \(config.architecture.displayName)")
            if config.engine == .qemu {
                Picker("Guest type", selection: $config.guestOS) {
                    ForEach([GuestOS.linux, .windows, .other]) { Text($0.displayName).tag($0) }
                }
            }
        }
    }
}

private struct SystemSection: View {
    @Binding var config: VMConfiguration

    var body: some View {
        Section("System") {
            ResourceSlider(title: "CPU cores", symbol: "cpu", value: $config.cpuCount, range: 1...HostInfo.maxCPUs,
                           recommended: HostInfo.recommendedCPUs)
            ResourceSlider(title: "Memory", symbol: "memorychip", value: $config.memoryMiB, range: 1024...HostInfo.maxMemoryMiB, step: 512,
                           recommended: HostInfo.recommendedMemoryMiB(for: config.guestOS), format: { $0.formattedMemory })
            if config.engine == .apple && config.guestOS == .linux {
                Toggle(isOn: $config.nestedVirtualization) {
                    Text("Nested virtualization")
                    Text(HostInfo.supportsNestedVirtualization ? "Run KVM inside the guest." : "Requires an M3 or newer chip.")
                }
                .disabled(!HostInfo.supportsNestedVirtualization)
            }
        }
    }
}

private struct DisplaySection: View {
    @Binding var config: VMConfiguration

    private static let presets: [(String, Int, Int)] = [
        ("1280 × 800", 1280, 800), ("1920 × 1080", 1920, 1080), ("1920 × 1200", 1920, 1200),
        ("2560 × 1440", 2560, 1440), ("2560 × 1600", 2560, 1600), ("2880 × 1800 (Retina)", 2880, 1800),
        ("3840 × 2160 (4K)", 3840, 2160),
    ]

    var body: some View {
        Section("Display") {
            Picker("Resolution", selection: Binding(
                get: { "\(config.display.widthPixels)x\(config.display.heightPixels)" },
                set: { value in
                    let parts = value.split(separator: "x").compactMap { Int($0) }
                    if parts.count == 2 { config.display.widthPixels = parts[0]; config.display.heightPixels = parts[1] }
                })) {
                ForEach(Self.presets, id: \.0) { preset in
                    Text(preset.0).tag("\(preset.1)x\(preset.2)")
                }
                if !Self.presets.contains(where: { $0.1 == config.display.widthPixels && $0.2 == config.display.heightPixels }) {
                    Text("\(config.display.widthPixels) × \(config.display.heightPixels)").tag("\(config.display.widthPixels)x\(config.display.heightPixels)")
                }
            }
            if config.guestOS == .macOS {
                Picker("Pixel density", selection: $config.display.pixelsPerInch) {
                    Text("Standard (110 ppi)").tag(110)
                    Text("Retina (220 ppi)").tag(220)
                    if ![110, 220].contains(config.display.pixelsPerInch) {
                        Text("\(config.display.pixelsPerInch) ppi").tag(config.display.pixelsPerInch)
                    }
                }
            }
            if config.engine == .apple {
                Toggle(isOn: $config.display.dynamicResolution) {
                    Text("Resize with window")
                    Text("Guest resolution follows the window size.")
                }
            }
        }
    }
}

private struct StorageSection: View {
    let vm: VMInstance
    @State private var resizing: DiskConfiguration?
    @State private var newSize = 64
    @State private var isPickingInstaller = false
    @State private var isPickingDisk = false
    @State private var confirmRemove: DiskConfiguration?

    var body: some View {
        @Bindable var vm = vm
        Section("Storage") {
            ForEach(vm.config.disks.filter { !$0.isRemovable }) { disk in
                LabeledContent {
                    HStack {
                        Text("\(disk.sizeGiB) GB · \(disk.interface.displayName)").foregroundStyle(.secondary)
                        Button("Resize…") {
                            newSize = disk.sizeGiB
                            resizing = disk
                        }
                        .disabled(vm.state.isActive || !vm.snapshots.isEmpty)
                        .help(vm.snapshots.isEmpty ? "Grow the disk" : "Delete snapshots before resizing")
                        if vm.config.disks.filter({ !$0.isRemovable }).count > 1 {
                            Button {
                                confirmRemove = disk
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .disabled(vm.state.isActive)
                            .help("Remove this disk")
                        }
                    }
                } label: {
                    Label(URL(fileURLWithPath: disk.path).lastPathComponent, systemImage: "internaldrive")
                        .lineLimit(1)
                }
            }
            Button("Add Existing Disk…", systemImage: "plus") { isPickingDisk = true }
                .disabled(vm.state.isActive || vm.installStatus != nil || vm.config.guestOS == .macOS)
                .help("QCOW2, VMDK, VDI, VHD(X), RAW or ASIF. Converted automatically when needed.")
            LabeledContent {
                HStack {
                    if let installer = vm.config.installerMedia {
                        Text(URL(fileURLWithPath: installer.path).lastPathComponent)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Eject") { vm.ejectInstaller() }
                    } else {
                        Text("None").foregroundStyle(.tertiary)
                    }
                    Button("Choose…") { isPickingInstaller = true }
                }
                .disabled(vm.state.isActive)
            } label: {
                Label("Installer / CD", systemImage: "opticaldisc")
            }
            Picker("Disk performance", selection: $vm.config.diskPerformance) {
                ForEach(DiskPerformance.allCases) { Text($0.displayName).tag($0) }
            }
            Text(vm.config.diskPerformance.detail).font(.caption).foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $isPickingInstaller, allowedContentTypes: FileInspector.openPanelTypes) { result in
            if case .success(let url) = result { vm.attachInstallerChecked(url) }
        }
        .fileImporter(isPresented: $isPickingDisk, allowedContentTypes: FileInspector.openPanelTypes) { result in
            if case .success(let url) = result { Task { await vm.importDisk(url) } }
        }
        .confirmationDialog("Remove this disk?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), presenting: confirmRemove) { disk in
            Button("Move to Trash", role: .destructive) { vm.removeDisk(disk) }
        } message: { _ in
            Text("The disk file is moved to the Trash.")
        }
        .sheet(item: $resizing) { disk in
            ResizeSheet(vm: vm, disk: disk, newSize: $newSize)
        }
    }
}

private struct ResizeSheet: View {
    let vm: VMInstance
    let disk: DiskConfiguration
    @Binding var newSize: Int
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Resize Disk").font(.title2.weight(.semibold))
            ResourceSlider(title: "New size", symbol: "internaldrive", value: $newSize, range: disk.sizeGiB...max(disk.sizeGiB + 8, 2048), step: 8, format: { "\($0) GB" })
            Text("Disks can only grow. Afterwards, extend the partition inside the guest (Disk Utility, GParted or diskpart).")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Resize") {
                    working = true
                    Task {
                        do {
                            try await DiskImageService.resize(at: vm.bundle.diskURL(for: disk), toGiB: newSize, currentGiB: disk.sizeGiB)
                            if let index = vm.config.disks.firstIndex(where: { $0.id == disk.id }) {
                                vm.config.disks[index].sizeGiB = newSize
                            }
                            vm.refreshFileState()
                        } catch {
                            vm.lastError = error.localizedDescription
                        }
                        working = false
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || newSize <= disk.sizeGiB)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

private struct NetworkSection: View {
    @Binding var config: VMConfiguration

    private var modes: [NetworkMode] {
        config.engine == .apple ? NetworkMode.allCases : [.nat, .none]
    }

    var body: some View {
        Section("Network") {
            Picker("Mode", selection: $config.network.mode) {
                ForEach(modes) { Text($0.displayName).tag($0) }
            }
            if config.network.mode == .bridged {
                Picker("Interface", selection: Binding(get: { config.network.bridgeInterface ?? "" }, set: { config.network.bridgeInterface = $0.isEmpty ? nil : $0 })) {
                    Text("Automatic").tag("")
                    ForEach(VZBridgedNetworkInterface.networkInterfaces, id: \.identifier) { interface in
                        Text(interface.localizedDisplayName ?? interface.identifier).tag(interface.identifier)
                    }
                }
                Text("Bridging requires Orbit to be signed with Apple's networking entitlement.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if config.network.mode != .none {
                LabeledContent("MAC address") {
                    HStack {
                        Text(config.network.macAddress).font(.body.monospaced()).textSelection(.enabled)
                        Button {
                            config.network.macAddress = NetworkConfiguration.randomMACAddress()
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderless)
                        .help("Generate a new address")
                    }
                }
            }
            if config.engine == .qemu && config.network.mode == .nat {
                PortForwardEditor(forwards: $config.network.portForwards)
            }
        }
    }
}

private struct PortForwardEditor: View {
    @Binding var forwards: [PortForward]

    var body: some View {
        ForEach($forwards) { $forward in
            HStack {
                Picker("", selection: $forward.isUDP) {
                    Text("TCP").tag(false)
                    Text("UDP").tag(true)
                }
                .labelsHidden()
                .frame(width: 70)
                TextField("Host", value: $forward.hostPort, format: .number.grouping(.never))
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("Guest", value: $forward.guestPort, format: .number.grouping(.never))
                Button(role: .destructive) {
                    forwards.removeAll { $0.id == forward.id }
                } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
            }
        }
        Button("Add Port Forward", systemImage: "plus") {
            forwards.append(PortForward(hostPort: 2222, guestPort: 22))
        }
    }
}

private struct SharingSection: View {
    @Binding var config: VMConfiguration
    @State private var isPicking = false
    @State private var rosettaInstalling = false

    var body: some View {
        Section("Sharing") {
            ForEach($config.sharedFolders) { $folder in
                HStack {
                    Label(folder.name, systemImage: "folder.fill")
                        .help(folder.path)
                    Spacer()
                    Toggle("Read only", isOn: $folder.isReadOnly)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                    Button(role: .destructive) {
                        config.sharedFolders.removeAll { $0.id == folder.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button("Add Shared Folder…", systemImage: "folder.badge.plus") { isPicking = true }
            if !config.sharedFolders.isEmpty {
                Text(mountHint).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if config.guestOS != .macOS && config.engine == .apple {
                Toggle(isOn: $config.clipboardSharing) {
                    Text("Clipboard sharing")
                    Text("Needs spice-vdagent in the guest.")
                }
            }
            if config.guestOS == .linux && config.engine == .apple {
                rosettaRow
            }
            Toggle("Sound output", isOn: $config.audioOutput)
            if config.engine == .apple {
                Toggle("Microphone input", isOn: $config.audioInput)
            }
        }
        .fileImporter(isPresented: $isPicking, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                config.sharedFolders += urls.map { SharedFolder(path: $0.path) }
            }
        }
    }

    private var mountHint: String {
        switch (config.guestOS, config.engine) {
        case (.macOS, _): "Appears in Finder under My Shared Files."
        case (_, .apple): "sudo mount -t virtiofs share /mnt"
        case (_, .qemu): "sudo mount -t 9p -o trans=virtio share /mnt"
        }
    }

    @ViewBuilder
    private var rosettaRow: some View {
        switch HostInfo.rosettaAvailability {
        case .installed:
            Toggle(isOn: $config.rosetta) {
                Text("Rosetta for Linux")
                Text("Mount with: sudo mount -t virtiofs rosetta /mnt/rosetta")
            }
        case .notInstalled:
            LabeledContent("Rosetta for Linux") {
                Button(rosettaInstalling ? "Installing…" : "Install Rosetta") {
                    rosettaInstalling = true
                    Task {
                        try? await VZLinuxRosettaDirectoryShare.installRosetta()
                        rosettaInstalling = false
                        config.rosetta = HostInfo.rosettaAvailability == .installed
                    }
                }
                .disabled(rosettaInstalling)
            }
        default:
            EmptyView()
        }
    }
}

private struct AdvancedSection: View {
    @Binding var config: VMConfiguration
    @State private var extraArgs = ""

    var body: some View {
        Section("Advanced") {
            Toggle(isOn: $config.suspendOnQuit) {
                Text("Suspend when Orbit quits")
                Text("Saves memory to disk and resumes instantly next time.")
            }
            .disabled(config.engine == .qemu)
            Toggle("Boot from installer first", isOn: $config.bootFromInstaller)
                .disabled(config.installerMedia == nil)
            if config.engine == .qemu {
                Toggle(isOn: $config.qemu.tpm) {
                    Text("TPM 2.0")
                    Text("Required by Windows 11. Uses swtpm.")
                }
                if !config.architecture.isNative {
                    Picker("Translation cache", selection: $config.qemu.tcgCacheMiB) {
                        ForEach([256, 512, 1024, 2048], id: \.self) { Text("\($0) MB").tag($0) }
                    }
                }
                TextField("Extra QEMU arguments", text: $extraArgs, axis: .vertical)
                    .font(.body.monospaced())
                    .onAppear { extraArgs = config.qemu.extraArguments.joined(separator: " ") }
                    .onSubmit { config.qemu.extraArguments = extraArgs.split(separator: " ").map(String.init) }
                    .onChange(of: extraArgs) { config.qemu.extraArguments = extraArgs.split(separator: " ").map(String.init) }
            }
        }
    }
}
