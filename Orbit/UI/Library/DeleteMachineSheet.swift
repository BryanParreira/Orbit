import SwiftUI

/// Shows exactly what deleting a machine removes and how much space it frees, before it happens.
struct DeleteMachineSheet: View {
    let vm: VMInstance
    @Environment(VMLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var plan: VMLibrary.DeletionPlan?
    @State private var removeInstaller = true
    @State private var working = false

    private var freed: Int64 {
        guard let plan else { return 0 }
        return plan.packageBytes + (removeInstaller ? plan.installerBytes : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                OSArtwork(config: vm.config, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Delete “\(vm.config.name)”?")
                        .font(.title3.weight(.semibold))
                    Text(vm.state.isActive ? "It's running and will be shut down first." : "Everything the machine uses on this Mac is removed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                row(symbol: "internaldrive", title: "Machine",
                    detail: "Disks, snapshots, saved memory, firmware and screenshots",
                    bytes: plan?.packageBytes)
                if let installer = plan?.installer {
                    Divider().padding(.leading, 44)
                    HStack(spacing: 12) {
                        Toggle("", isOn: $removeInstaller).labelsHidden().toggleStyle(.checkbox)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Downloaded installer").font(.callout.weight(.medium))
                            Text("\(installer.lastPathComponent). No other machine uses it.")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text((plan?.installerBytes ?? 0).formattedBytes).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(12)
                }
            }
            .surface(radius: 12)

            HStack {
                Text("Frees")
                Spacer()
                Text(plan == nil ? "Calculating…" : freed.formattedBytes)
                    .font(.headline.monospacedDigit())
            }

            Text("Files you added yourself, like installer images you chose or shared folders, are never deleted.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Move to Trash") { delete(permanently: false) }
                    .help("Recoverable from the Trash, but it keeps using space until you empty the Trash.")
                Button(role: .destructive) {
                    delete(permanently: true)
                } label: {
                    Text("Delete").padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.defaultAction)
                .help("Removes it for good and frees the space now. This can't be undone.")
            }
            .controlSize(.large)
            .disabled(working || plan == nil)
        }
        .padding(24)
        .frame(width: 460)
        .task { plan = await library.deletionPlan(for: vm) }
    }

    private func row(symbol: String, title: String, detail: String, bytes: Int64?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(bytes?.formattedBytes ?? "…").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private func delete(permanently: Bool) {
        working = true
        Task {
            do {
                try await library.delete(vm, permanently: permanently, removeInstaller: removeInstaller)
                if AppRouter.shared.selection == vm.id {
                    AppRouter.shared.selection = AppRouter.galleryID
                }
                dismiss()
            } catch {
                vm.report(error)
                working = false
            }
        }
    }
}
