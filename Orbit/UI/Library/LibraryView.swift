import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(VMLibrary.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(\.openWindow) private var openWindow
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var router = router
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            if let id = router.selection, let vm = library.vm(with: id) {
                VMDetailView(vm: vm)
                    .id(vm.id)
                    .focusedSceneValue(\.selectedVM, vm)
            } else if library.isRootUnavailable {
                ContentUnavailableView {
                    Label("Library Unavailable", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("Orbit can't reach \(library.rootURL.path(percentEncoded: false)). If it's on an external drive, connect it. You can also choose another location in Settings.")
                } actions: {
                    Button("Try Again") { library.reload() }
                    SettingsLink { Text("Open Settings") }
                }
            } else if library.vms.isEmpty {
                WelcomeView()
            } else {
                ContentUnavailableView {
                    Label {
                        Text("Select a Virtual Machine")
                    } icon: {
                        Image("MenuBarIcon").resizable().scaledToFit().frame(width: 64)
                    }
                } description: {
                    Text("Or press ⌘N to create a new one.")
                }
            }
        }
        .sheet(isPresented: $router.isShowingWizard) {
            NewVMWizard(initialFile: router.pendingFile, initialTemplateID: router.pendingTemplateID)
                .environment(library)
                .environment(router)
                .tint(Theme.ink)
                .onDisappear {
                    router.pendingFile = nil
                    router.pendingTemplateID = nil
                }
        }
        .fileImporter(isPresented: $router.isShowingImporter,
                      allowedContentTypes: LibraryDropHandler.importTypes,
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                for url in urls { await LibraryDropHandler.handle(url, library: library) }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            LibraryDropHandler.load(providers) { url in
                Task { await LibraryDropHandler.handle(url, library: library) }
            }
            return true
        }
        .overlay {
            if isDropTargeted {
                DropOverlay()
            }
        }
        .onAppear {
            router.openWindowAction = openWindow
            if router.selection == nil { router.selection = library.vms.first?.id }
            #if DEBUG
            SelfTest.runIfRequested(library: library, openWindow: openWindow)
            #endif
        }
    }
}

private struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 20))
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 40, weight: .light))
                    Text("Drop to create or import").font(.title3.weight(.semibold))
                    Text("ISO, IPSW, Orbit or UTM machine").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .allowsHitTesting(false)
    }
}

/// Routes files dropped on Orbit or opened from Finder.
@MainActor
enum LibraryDropHandler {
    static let importTypes: [UTType] = FileInspector.openPanelTypes

    /// Route any file brought to Orbit by what it really contains.
    static func handle(_ url: URL, library: VMLibrary) async {
        let router = AppRouter.shared
        switch FileInspector.inspect(url) {
        case .orbitPackage, .utmPackage:
            if let existing = library.vms.first(where: { $0.bundle.url.standardizedFileURL == url.standardizedFileURL }) {
                router.selection = existing.id
                return
            }
            do {
                let vm = try await library.importPackage(at: url)
                router.selection = vm.id
                router.showLibrary()
            } catch {
                presentError(error)
            }
        case .ipsw, .iso, .diskImage:
            router.pendingFile = url
            router.pendingTemplateID = nil
            // the wizard is a sheet on the library window, which may be closed
            router.showLibrary()
            router.isShowingWizard = true
        case .unsupported(let reason):
            presentError(VMError.invalidConfiguration(reason))
        }
    }

    static func load(_ providers: [NSItemProvider], perform: @escaping @MainActor (URL) -> Void) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in perform(url) }
            }
        }
    }

    static func presentError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
