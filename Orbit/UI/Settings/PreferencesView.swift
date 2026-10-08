import SwiftUI
import Virtualization

struct PreferencesView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralPreferences() }
            Tab("Engines", systemImage: "cpu") { EnginePreferences() }
            Tab("Updates", systemImage: "arrow.down.circle") { UpdatePreferences() }
            Tab("About", systemImage: "info.circle") { AboutPreferences() }
        }
        .frame(width: 560, height: 420)
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
