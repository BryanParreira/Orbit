import SwiftUI

/// The installer's steps for this system, numbered, with the disk to choose spelled out.
struct InstallGuideView: View {
    let name: String
    let guide: InstallGuide

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Installing \(name)").font(.headline)
                Text("The installer is \(name)'s own. These are the choices to make.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 11) {
                ForEach(Array(guide.steps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.primary.opacity(0.08)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title).font(.callout.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                            if let detail = step.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            if let more = guide.moreInfo {
                Link(destination: more) {
                    Label("Full instructions from the project", systemImage: "arrow.up.right.square")
                }
                .font(.callout)
            }
        }
        .padding(18)
        .frame(width: 380, alignment: .leading)
    }
}

/// "Setup Steps", for a machine whose installer is attached.
struct InstallGuideButton: View {
    let vm: VMInstance
    var label = true
    @State private var isShowing = false

    var body: some View {
        if let guide = InstallGuide.guide(for: vm.config) {
            Button {
                isShowing.toggle()
            } label: {
                if label {
                    Label("Setup Steps", systemImage: "list.number")
                } else {
                    Label("Setup Steps", systemImage: "list.number").labelStyle(.iconOnly)
                }
            }
            .help("What to choose in the installer, and which disk is this machine's")
            .popover(isPresented: $isShowing, arrowEdge: .bottom) {
                InstallGuideView(name: OSTemplate.template(id: vm.config.templateID)?.name ?? vm.config.name, guide: guide)
            }
        }
    }
}
