import SwiftUI

/// Offers to install QEMU through Homebrew.
struct QEMUInstallPrompt: View {
    @State private var installer = QEMUInstaller.shared
    @State private var refresh = 0

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: HostInfo.isQEMUInstalled ? "checkmark.circle.fill" : "shippingbox.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(HostInfo.isQEMUInstalled ? "QEMU is ready" : "QEMU is required").font(.headline)
                if installer.isRunning || !installer.lastLine.isEmpty {
                    Text(installer.lastLine)
                        .font(.caption.monospaced())
                        .foregroundStyle(installer.failed ? Color.red : .secondary)
                        .lineLimit(2)
                } else {
                    Text("Windows and non-ARM guests run on QEMU. Orbit can install it with Homebrew.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !HostInfo.isQEMUInstalled {
                if installer.isRunning {
                    ProgressView().controlSize(.small)
                } else if installer.brewURL != nil {
                    Button("Install") { installer.install() }
                } else {
                    Link("Get Homebrew", destination: URL(string: "https://brew.sh")!)
                }
            }
        }
        .id(refresh)
        .onChange(of: installer.isRunning) { refresh += 1 }
    }
}
