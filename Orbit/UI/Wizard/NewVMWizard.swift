import SwiftUI
import UniformTypeIdentifiers

/// Two steps instead of UTM's six: pick a system, review smart defaults, create.
struct NewVMWizard: View {
    /// A file brought in from elsewhere: installer image or existing disk.
    var initialFile: URL?
    var initialTemplateID: String?

    @Environment(VMLibrary.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var draft: VMDraft?
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let current = draft {
                    // `current` keeps the outgoing step valid while Back animates it away
                    ConfigureStep(draft: Binding(get: { draft ?? current }, set: { draft = $0 }))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    ChooseStep { template in
                        withAnimation(.snappy) { draft = VMDraft(template: template, name: library.uniqueName(template.name)) }
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 780)
        .frame(minHeight: 520, idealHeight: 640, maxHeight: 640)
        .onAppear(perform: applyInitialState)
        .alert("Could not create the virtual machine", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private var footer: some View {
        HStack {
            if draft != nil && initialFile == nil {
                Button("Back") { withAnimation(.snappy) { draft = nil } }
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            if let draft {
                Button {
                    create(draft)
                } label: {
                    if isCreating {
                        ProgressView().controlSize(.small).padding(.horizontal, 14)
                    } else {
                        Text(draft.installer == .download ? "Download & Create" : "Create")
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isCreating || !draft.isValid)
            }
        }
        .controlSize(.large)
        .padding(16)
    }

    private func applyInitialState() {
        if let url = initialFile {
            do {
                draft = try Self.draft(for: url, library: library)
            } catch {
                self.error = error.localizedDescription
            }
        } else if let template = OSTemplate.template(id: initialTemplateID) {
            draft = VMDraft(template: template, name: library.uniqueName(template.name))
        }
        #if DEBUG
        if let folder = UserDefaults.standard.string(forKey: "OrbitWizardLocation") {
            draft?.location = URL(fileURLWithPath: folder, isDirectory: true)
        }
        #endif
    }

    /// Pre-filled draft for a file dropped on Orbit or opened from Finder.
    static func draft(for url: URL, library: VMLibrary) throws -> VMDraft {
        var template = guessTemplate(for: url)
        switch FileInspector.inspect(url) {
        case .ipsw:
            template = OSTemplate.template(id: "macos")!
            var draft = VMDraft(template: template, name: library.uniqueName(template.name))
            draft.installer = .local(url)
            return draft
        case .iso:
            return installerDraft(url, template: template, library: library)
        case .diskImage(.raw) where url.pathExtension.lowercased() == "iso":
            // a raw boot image someone named .iso
            return installerDraft(url, template: template, library: library)
        case .diskImage(let format):
            if template.guestOS == .macOS { template = OSTemplate.template(id: "linux-custom")! }
            let name = url.deletingPathExtension().lastPathComponent
            var draft = VMDraft(template: template, name: library.uniqueName(name))
            draft.existingDisk = url
            draft.existingDiskFormat = format
            draft.installer = .none
            return draft
        case .unsupported(let reason):
            throw VMError.invalidConfiguration(reason)
        case .orbitPackage, .utmPackage:
            throw VMError.invalidConfiguration("“\(url.lastPathComponent)” is a virtual machine. Use File → Import to add it.")
        }
    }

    private func create(_ draft: VMDraft) {
        isCreating = true
        Task {
            do {
                let vm = try await VMCreator.create(draft, in: library)
                router.selection = vm.id
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isCreating = false
        }
    }

    private static func installerDraft(_ url: URL, template: OSTemplate, library: VMLibrary) -> VMDraft {
        let template = template.guestOS == .macOS ? OSTemplate.template(id: "linux-custom")! : template
        var draft = VMDraft(template: template, name: library.uniqueName(template.name))
        draft.installer = .local(url)
        return draft
    }

    static func guessTemplate(for url: URL) -> OSTemplate {
        let name = url.lastPathComponent.lowercased()
        let id: String = switch true {
        case url.pathExtension.lowercased() == "ipsw": "macos"
        case name.contains("ubuntu"): "ubuntu"
        case name.contains("fedora"): "fedora"
        case name.contains("debian"): "debian"
        case name.contains("alpine"): "alpine"
        case name.contains("win") && (name.contains("arm") || name.contains("a64")): "windows-arm"
        case name.contains("amd64") || name.contains("x86_64") || name.contains("x64") || name.contains("win"): "emulated"
        default: "linux-custom"
        }
        return OSTemplate.template(id: id)!
    }
}

// MARK: - Step 1

private struct ChooseStep: View {
    let onChoose: (OSTemplate) -> Void
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New Virtual Machine").font(.system(size: 24, weight: .semibold))
                    Text("Choose a system. Orbit picks the fastest engine and settings for your \(HostInfo.chipName).")
                        .foregroundStyle(.secondary)
                }
                TemplateGrid(onChoose: onChoose)
                QuietLink("Import an existing UTM or Orbit machine…") {
                    dismiss()
                    router.isShowingImporter = true
                }
                .font(.callout)
            }
            .padding(28)
        }
    }
}

// MARK: - Step 2

private struct ConfigureStep: View {
    @Binding var draft: VMDraft
    @Environment(VMLibrary.self) private var library
    @State private var isPickingInstaller = false
    @State private var isPickingDisk = false
    @State private var isPickingFolder = false
    @State private var isShowingMicrosoft = false
    @State private var fileProblem: String?

    private var maxDiskGiB: Int {
        let free = HostInfo.freeSpaceBytes(at: location).map { Int($0 / 1_073_741_824) } ?? 2048
        return max(16, min(4096, free * 4)) // sparse images can be bigger than free space
    }

    private var isMac: Bool { draft.guestOS == .macOS }

    /// Where the machine will be kept: the folder the user chose, or the library.
    private var location: URL { draft.location ?? library.rootURL }

    private var locationSection: some View {
        Section {
            LabeledContent {
                HStack {
                    if draft.location != nil {
                        Button("Use Library") { draft.location = nil }.buttonStyle(.borderless)
                    }
                    Button("Choose…") { chooseLocation() }
                }
            } label: {
                Text(draft.location?.lastPathComponent ?? "Orbit library")
                Text((location.path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1).truncationMode(.head)
            }
            if let free = HostInfo.freeSpaceBytes(at: location) {
                LabeledContent("Free space", value: free.formattedBytes)
            }
        } header: {
            Text("Location")
        } footer: {
            Text(locationFooter)
        }
    }

    private var locationFooter: String {
        var text = draft.installer == .download
            ? "The machine and the installer it downloads are kept here."
            : "Everything the machine uses is kept here."
        if !HostInfo.supportsCloning(at: location) {
            text += " This drive isn't APFS, so snapshots and duplicates make full copies."
        }
        if draft.location != nil {
            text += " If the drive is disconnected, the machine reappears when you connect it again."
        }
        return text
    }

    private func chooseLocation() {
        guard let folder = VMActions.chooseFolder(message: "Choose where to keep “\(draft.name)”, on this Mac or another drive.",
                                                  prompt: "Choose", startingAt: draft.location) else { return }
        do {
            try library.validateLocation(folder)
            draft.location = folder.standardizedFileURL.path == library.rootURL.standardizedFileURL.path ? nil : folder
            fileProblem = nil
            draft.diskGiB = min(draft.diskGiB, maxDiskGiB)
        } catch {
            fileProblem = error.localizedDescription
        }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    OSArtwork(template: draft.template, size: 52)
                    VStack(alignment: .leading) {
                        TextField("", text: $draft.name, prompt: Text("Name"))
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .font(.title2.weight(.semibold))
                        Text("\(draft.engine.displayName) · \(draft.architecture.displayName)\(draft.architecture.isNative ? "" : " (emulated)")")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if !isMac {
                diskSection
            }
            if draft.existingDisk == nil || !isMac {
                installerSection
            }
            if let note = draft.template.firstBootNote, draft.template.id == "rocky" || draft.template.id == "alma" {
                Section {
                    Label(note, systemImage: "clock").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let fileProblem {
                Section {
                    Label(fileProblem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }

            if draft.template.id == "emulated" || draft.template.id == "linux-custom" {
                Section("Platform") {
                    if draft.template.id == "linux-custom" {
                        Picker("Engine", selection: $draft.engine) {
                            ForEach(VMEngineKind.allCases) { Text($0.displayName).tag($0) }
                        }
                        Text(draft.engine.summary).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("Architecture", selection: $draft.architecture) {
                            ForEach(GuestArchitecture.allCases) { Text($0.displayName).tag($0) }
                        }
                        Picker("Operating system", selection: $draft.guestOS) {
                            ForEach([GuestOS.linux, .windows, .other]) { Text($0.displayName).tag($0) }
                        }
                    }
                }
            }

            Section("Resources") {
                ResourceSlider(title: "CPU cores", symbol: "cpu", value: $draft.cpuCount, range: 1...HostInfo.maxCPUs,
                               recommended: HostInfo.recommendedCPUs)
                ResourceSlider(title: "Memory", symbol: "memorychip", value: $draft.memoryMiB, range: 1024...HostInfo.maxMemoryMiB, step: 512,
                               recommended: HostInfo.recommendedMemoryMiB(for: draft.guestOS), format: { $0.formattedMemory })
                if draft.existingDisk == nil {
                    ResourceSlider(title: "Disk size", symbol: "internaldrive", value: $draft.diskGiB, range: 8...maxDiskGiB, step: 8,
                                   recommended: draft.template.defaultDiskGiB, format: { "\($0) GB" })
                    Text("Disks are sparse: they only use space as the guest writes data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            locationSection

            Section("Extras") {
                if draft.guestOS == .linux && draft.engine == .apple {
                    Toggle(isOn: $draft.rosetta) {
                        Text("Rosetta for x86-64 Linux apps")
                        Text("Run Intel Linux binaries at near-native speed.")
                    }
                    .disabled(HostInfo.rosettaAvailability == .notSupported)
                    Toggle(isOn: $draft.clipboardSharing) {
                        Text("Share clipboard")
                        Text("Copy and paste between Mac and guest. The guest can then read anything you copy.")
                    }
                }
                LabeledContent("Shared folder") {
                    HStack {
                        Text(draft.sharedFolder?.lastPathComponent ?? "None").foregroundStyle(.secondary)
                        if draft.sharedFolder != nil {
                            Button("Remove") { draft.sharedFolder = nil }.buttonStyle(.borderless)
                        }
                        Button("Choose…") { isPickingFolder = true }
                    }
                }
                Toggle("Start when ready", isOn: $draft.startWhenReady)
            }

            if draft.engine == .qemu && !HostInfo.isQEMUInstalled {
                Section {
                    QEMUInstallPrompt()
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingMicrosoft) {
            if case .microsoft(let page) = draft.template.source {
                MicrosoftDownloadSheet(page: page) { draft.installer = .microsoft($0) }
            }
        }
        .fileImporter(isPresented: $isPickingInstaller, allowedContentTypes: FileInspector.openPanelTypes) { result in
            if case .success(let url) = result { useInstaller(url) }
        }
        .fileDialogMessage(isMac ? "Choose a macOS restore image (.ipsw)" : "Choose an installer image (.iso)")
        .fileImporter(isPresented: $isPickingDisk, allowedContentTypes: FileInspector.openPanelTypes) { result in
            if case .success(let url) = result { useDisk(url) }
        }
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { draft.sharedFolder = url }
        }
    }

    // MARK: Validation

    private func useInstaller(_ url: URL) {
        let kind = FileInspector.inspect(url)
        switch (isMac, kind) {
        case (true, .ipsw), (false, .iso), (false, .diskImage(.raw)):
            draft.installer = .local(url)
            fileProblem = nil
        case (true, _):
            fileProblem = "“\(url.lastPathComponent)” is not a macOS restore image. Choose an .ipsw file."
        case (false, .ipsw):
            fileProblem = "That's a macOS restore image. Pick the macOS template to use it."
        case (false, .diskImage(let format)):
            fileProblem = "“\(url.lastPathComponent)” is a \(format.displayName) disk, not an installer. Use it under Disk → Use an existing disk."
        case (false, .unsupported(let reason)):
            fileProblem = reason
        default:
            fileProblem = "“\(url.lastPathComponent)” is not an installer image."
        }
    }

    private func useDisk(_ url: URL) {
        switch FileInspector.inspect(url) {
        case .diskImage(let format):
            draft.existingDisk = url
            draft.existingDiskFormat = format
            if case .download = draft.installer { draft.installer = .none }
            fileProblem = !format.needsQEMUImg(for: draft.engine) || HostInfo.qemuImg().map({ FileManager.default.isExecutableFile(atPath: $0.path) }) == true
                ? nil
                : "Converting \(format.displayName) needs QEMU's qemu-img. Install QEMU from Settings → Engines first."
        case .iso:
            fileProblem = "“\(url.lastPathComponent)” is an installer, not a disk. Use it under Installer."
        case .unsupported(let reason):
            fileProblem = reason
        default:
            fileProblem = "“\(url.lastPathComponent)” is not a disk image."
        }
    }

    // MARK: Sections

    private var diskSection: some View {
        Section("Disk") {
            Picker("Disk", selection: Binding(
                get: { draft.existingDisk == nil ? 0 : 1 },
                set: { choice in
                    if choice == 0 {
                        draft.existingDisk = nil
                        draft.existingDiskFormat = nil
                        fileProblem = nil
                    } else if draft.existingDisk == nil {
                        isPickingDisk = true
                    }
                })) {
                Text("Create a new disk").tag(0)
                Text("Use an existing disk image").tag(1)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if let disk = draft.existingDisk, let format = draft.existingDiskFormat {
                LabeledContent {
                    Button("Change…") { isPickingDisk = true }
                } label: {
                    Text(disk.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text(format.isNative(to: draft.engine)
                         ? "\(format.displayName) · used as is (cloned, your original stays untouched)"
                         : "\(format.displayName) · converted to \(format.importedFormatName(for: draft.engine)) for \(draft.engine.displayName)")
                }
            }
        }
    }

    @ViewBuilder
    private var installerSection: some View {
        Section("Installer") {
            switch draft.template.source {
            case .macOSRestoreImage, .resolver:
                Picker("Source", selection: Binding(
                    get: { draft.installer == .download ? 0 : (draft.installer == .none ? 2 : 1) },
                    set: { choice in
                        switch choice {
                        case 0: draft.installer = .download
                        case 2: draft.installer = .none
                        default:
                            if let localURL { draft.installer = .local(localURL) } else { isPickingInstaller = true }
                        }
                    })) {
                    Text(isMac ? "Download latest macOS from Apple" : "Download latest \(draft.template.name) automatically").tag(0)
                    Text("Use a file on this Mac").tag(1)
                    if draft.existingDisk != nil { Text("None, boot the disk").tag(2) }
                }
                .pickerStyle(.radioGroup)
                if draft.installer == .download {
                    Text(isMac ? "About 15 GB. Kept in your library so the next macOS VM is instant." : "Always fetches the newest release from the official mirror.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if draft.installer != .none {
                    fileRow
                }
            case .manual(let page):
                Link(destination: page) {
                    Label("Get the \(draft.template.name) image from the official site", systemImage: "arrow.up.right.square")
                }
                fileRow
            case .microsoft:
                if case .microsoft(let windows) = draft.installer {
                    LabeledContent("Windows 11") {
                        HStack {
                            Text(windows.fileName).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button("Change…") { isShowingMicrosoft = true }
                        }
                    }
                    Text("Downloaded from Microsoft when you click Create\(windows.hashes.isEmpty ? "" : ", and checked against the checksums Microsoft publishes").")
                        .font(.caption).foregroundStyle(.secondary)
                } else if localURL != nil {
                    fileRow
                } else {
                    Button {
                        isShowingMicrosoft = true
                    } label: {
                        Label("Download Windows 11 from Microsoft…", systemImage: "arrow.down.circle")
                    }
                    LabeledContent("Or use an ISO on this Mac") {
                        Button("Choose…") { isPickingInstaller = true }
                    }
                }
                if draft.guestOS == .windows && draft.architecture == .arm64 {
                    Label("Orbit adds the drivers Windows needs for networking, so setup goes online by itself. They're downloaded once (about 900 MB) and verified.",
                          systemImage: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .custom:
                fileRow
            }
        }
    }

    private var localURL: URL? {
        if case .local(let url) = draft.installer { url } else { nil }
    }

    private var fileRow: some View {
        LabeledContent(isMac ? "Restore image" : "Boot image") {
            HStack {
                Text(localURL?.lastPathComponent ?? "None")
                    .foregroundStyle(localURL == nil ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if localURL != nil && !isMac {
                    Button("Remove") { draft.installer = .none }.buttonStyle(.borderless)
                }
                Button("Choose…") { isPickingInstaller = true }
            }
        }
    }
}

extension VMDraft {
    var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if guestOS == .macOS, installer == .none { return false }
        // nothing to install Windows from yet
        if case .microsoft = template.source, installer == .none { return false }
        if engine == .qemu && !HostInfo.isQEMUInstalled { return false }
        if let format = existingDiskFormat, format.needsQEMUImg(for: engine), HostInfo.qemuImg().map({ FileManager.default.isExecutableFile(atPath: $0.path) }) != true {
            return false
        }
        return true
    }
}
