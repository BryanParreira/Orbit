import SwiftUI

struct SidebarView: View {
    @Environment(VMLibrary.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""

    private var filtered: [VMInstance] {
        guard !search.isEmpty else { return library.vms }
        return library.vms.filter { $0.config.name.localizedCaseInsensitiveContains(search) || $0.config.guestOS.displayName.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        @Bindable var router = router
        let running = filtered.filter { $0.state.isActive }
        let idle = filtered.filter { !$0.state.isActive }
        List(selection: $router.selection) {
            if search.isEmpty {
                Label {
                    HStack {
                        Text("All Machines")
                        Spacer()
                        Text("\(library.vms.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "square.grid.2x2")
                }
                .tag(AppRouter.galleryID)
            }
            if !running.isEmpty {
                Section("Running") {
                    ForEach(running) { vm in SidebarRow(vm: vm).tag(vm.id) }
                }
            }
            if !idle.isEmpty {
                Section(running.isEmpty ? "Virtual Machines" : "Stopped") {
                    ForEach(idle) { vm in SidebarRow(vm: vm).tag(vm.id) }
                }
            }
        }
        .listStyle(.sidebar)
        // ⌘⌫ / Delete opens the delete sheet for the selected machine
        .onDeleteCommand {
            if let id = router.selection, let vm = library.vm(with: id) {
                VMActions.confirmDelete(vm, library: library)
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let vm = library.vm(with: id) {
                VMActionsMenu(vm: vm)
            }
        } primaryAction: { ids in
            // double-click / Return: boot and show
            if let id = ids.first, let vm = library.vm(with: id) {
                Task { await VMActions.startAndShow(vm, openWindow: openWindow) }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search")
        .animation(.snappy, value: running.map(\.id))
        .safeAreaInset(edge: .bottom) { HostFooter() }
        .toolbar {
            ToolbarItem {
                Button {
                    router.isShowingWizard = true
                } label: {
                    Label("New Virtual Machine", systemImage: "plus")
                }
                .help("New Virtual Machine (⌘N)")
            }
        }
    }
}

struct SidebarRow: View {
    let vm: VMInstance

    var body: some View {
        HStack(spacing: 10) {
            OSArtwork(config: vm.config, size: 32)
                .overlay(alignment: .bottomTrailing) {
                    if vm.state.isActive {
                        StatusDot(state: vm.state)
                            .padding(2)
                            .background(.background, in: .circle)
                            .offset(x: 3, y: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.config.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Group {
                    if let status = vm.installStatus {
                        Text(status)
                    } else if vm.state.isActive {
                        Text(vm.state.label)
                    } else if vm.hasSavedState {
                        Text("Suspended")
                    } else {
                        Text(vm.config.specLine)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Host capacity at a glance: how much of the Mac running guests use.
private struct HostFooter: View {
    @Environment(VMLibrary.self) private var library

    var body: some View {
        let running = library.vms.filter { $0.state.isActive }
        let usedMemory = running.reduce(0) { $0 + $1.config.memoryMiB }
        let fraction = min(1, Double(usedMemory) / Double(max(1, HostInfo.memoryMiB)))
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(HostInfo.chipName).font(.caption.weight(.semibold))
                Spacer()
                Text(running.isEmpty ? "Idle" : "\(running.count) running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Capsule()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 3)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule().fill(Color.primary.opacity(0.55)).frame(width: max(3, geo.size.width * fraction))
                    }
                }
                .animation(.snappy, value: fraction)
            Text("\(usedMemory.formattedMemory) of \(HostInfo.memoryMiB.formattedMemory) memory in use")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
