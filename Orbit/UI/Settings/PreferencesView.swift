import SwiftUI
import Virtualization

struct PreferencesView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralPreferences() }
            Tab("Storage", systemImage: "internaldrive") { StoragePreferences() }
            Tab("Engines", systemImage: "cpu") { EnginePreferences() }
            Tab("Updates", systemImage: "arrow.down.circle") { UpdatePreferences() }
            Tab("About", systemImage: "info.circle") { AboutPreferences() }
        }
        .frame(width: 600, height: 480)
    }
}

private struct GeneralPreferences: View {
    @Environment(VMLibrary.self) private var library
    @AppStorage(PreferenceKey.showMenuBarExtra) private var showMenuBarExtra = true
    @AppStorage(PreferenceKey.captureSystemKeys) private var captureSystemKeys = true
    @State private var isPicking = false

    var body: some View {
        Form {
            Section("Library") {
                LabeledContent("Location") {
                    HStack {
                        Text(library.rootURL.path(percentEncoded: false))
                            .lineLimit(1).truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Button("Change…") { isPicking = true }
                        Button("Show") { NSWorkspace.shared.open(library.rootURL) }
                    }
                }
                if let free = HostInfo.freeSpaceBytes(at: library.rootURL) {
                    LabeledContent("Free space", value: free.formattedBytes)
                }
                LabeledContent("Instant snapshots") {
                    Text(HostInfo.supportsCloning(at: library.rootURL) ? "Yes (APFS)" : "No: volume is not APFS, snapshots will copy")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Behavior") {
                Toggle("Show Orbit in the menu bar", isOn: $showMenuBarExtra)
                Toggle("Send system shortcuts (⌘Tab, ⌘Space) to guests", isOn: $captureSystemKeys)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isPicking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { library.moveLibrary(to: url) }
        }
    }
}

/// Everything Orbit keeps on this Mac, in plain view, with sizes, and anything it left behind.
private struct StoragePreferences: View {
    @Environment(VMLibrary.self) private var library
    @State private var machinesBytes: Int64?
    @State private var installerBytes: Int64?
    @State private var leftovers: [VMLibrary.Leftover]?
    @State private var confirmClean = false

    private var leftoverBytes: Int64 { leftovers?.reduce(0) { $0 + $1.bytes } ?? 0 }

    var body: some View {
        Form {
            Section {
                LabeledContent("Virtual machines") {
                    Text(machinesBytes.map { "\($0.formattedBytes) · \(library.vms.count) machine\(library.vms.count == 1 ? "" : "s")" } ?? "Calculating…")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Downloaded installers") {
                    Text(installerBytes?.formattedBytes ?? "Calculating…").foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.open(library.rootURL) }
                }
            } header: {
                Text("On this Mac")
            } footer: {
                Text("Disks only use space for what guests have written. Installers are kept so the next machine starts faster.")
            }

            Section {
                if let leftovers {
                    if leftovers.isEmpty {
                        Label("Nothing to clean up.", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(leftovers) { item in
                            LabeledContent {
                                Text(item.bytes.formattedBytes).monospacedDigit().foregroundStyle(.secondary)
                            } label: {
                                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Text(item.reason)
                            }
                        }
                        HStack {
                            Text("\(leftovers.count) item\(leftovers.count == 1 ? "" : "s") · \(leftoverBytes.formattedBytes)")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Clean Up…") { confirmClean = true }
                        }
                    }
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Looking for leftovers…").foregroundStyle(.secondary) }
                }
            } header: {
                Text("Clean up")
            } footer: {
                Text("Only Orbit's own leftovers are listed: unused downloads, unfinished imports and temporary files from machines that didn't stop cleanly. Working machines are never touched.")
            }

            Section("What Orbit stores") {
                StorageRow(symbol: "folder", title: "Library", detail: library.rootURL.path(percentEncoded: false))
                StorageRow(symbol: "gearshape", title: "Settings", detail: "~/Library/Preferences/com.orbitvm.Orbit.plist")
                StorageRow(symbol: "clock.arrow.circlepath", title: "Update cache", detail: "~/Library/Caches/com.orbitvm.Orbit")
                StorageRow(symbol: "hourglass", title: "While running", detail: "Temporary files in your private temp folder, removed when machines stop")
                Text("Orbit never partitions or formats your Mac's disks, installs no background services or system extensions, and never asks for an administrator password. Each virtual disk is an ordinary file inside its machine's package. Deleting a machine removes all of it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .confirmationDialog("Remove \(leftovers?.count ?? 0) leftover item\((leftovers?.count ?? 0) == 1 ? "" : "s")?", isPresented: $confirmClean) {
            Button("Remove \(leftoverBytes.formattedBytes)", role: .destructive) {
                library.remove(leftovers ?? [])
                Task { await refresh() }
            }
        } message: {
            Text("They're deleted permanently. Downloads come back automatically if a new machine needs them.")
        }
    }

    private func refresh() async {
        leftovers = nil
        installerBytes = await VMLibrary.allocatedSize(of: library.installersURL)
        let total = await VMLibrary.allocatedSize(of: library.rootURL)
        machinesBytes = max(0, total - (installerBytes ?? 0))
        leftovers = await library.leftovers()
    }
}

private struct StorageRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        LabeledContent {
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}

private struct EnginePreferences: View {
    @AppStorage(PreferenceKey.qemuDirectory) private var qemuDirectory = ""

    var body: some View {
        Form {
            Section("Apple Virtualization") {
                LabeledContent("Chip", value: HostInfo.chipName)
                LabeledContent("Cores", value: "\(HostInfo.totalCPUs) (\(HostInfo.performanceCores) performance)")
                LabeledContent("Memory", value: HostInfo.memoryMiB.formattedMemory)
                LabeledContent("Nested virtualization", value: HostInfo.supportsNestedVirtualization ? "Supported" : "Requires M3 or newer")
                LabeledContent("Rosetta for Linux", value: rosettaLabel)
            }
            Section("QEMU") {
                QEMUInstallPrompt()
                if let binary = HostInfo.qemuBinary(for: .arm64) ?? HostInfo.qemuBinary(for: .x86_64) {
                    LabeledContent("Found at", value: binary.deletingLastPathComponent().path)
                }
                TextField("Custom bin directory", text: $qemuDirectory, prompt: Text("/opt/homebrew/bin"))
            }
        }
        .formStyle(.grouped)
    }

    private var rosettaLabel: String {
        switch HostInfo.rosettaAvailability {
        case .installed: "Installed"
        case .notInstalled: "Not installed"
        default: "Not supported"
        }
    }
}

private struct UpdatePreferences: View {
    @State private var updater = AppUpdater.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Version") {
                    Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Last checked") {
                    Text(updater.lastCheck.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    CheckForUpdatesButton()
                }
            }
            Section {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
                Toggle(isOn: $updater.automaticallyDownloads) {
                    Text("Download and install automatically")
                    Text("Updates install the next time Orbit quits. Running machines are suspended first.")
                }
                .disabled(!updater.automaticallyChecks)
            }
            .disabled(!updater.isConfigured)
            if !updater.isConfigured {
                Text("Updates are off in this development build.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutPreferences: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
            Text("Orbit").font(.title.weight(.bold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .foregroundStyle(.secondary)
            Text("Virtualization engine adapted from UTM by osy and contributors, licensed under the Apache License 2.0.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Link("github.com/utmapp/UTM", destination: URL(string: "https://github.com/utmapp/UTM")!)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
