import SwiftUI

/// First-run screen: one click from a template to a booting VM.
struct WelcomeView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 14) {
                    OrbitMark(size: 88)
                    Text("Welcome to Orbit")
                        .font(.system(size: 34, weight: .semibold))
                    Text("Virtual machines at native speed on \(HostInfo.chipName).\nPick a system. Orbit downloads, configures and boots it.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }
                .padding(.top, 8)

                TemplateGrid { template in
                    router.pendingTemplateID = template.id
                    router.isShowingWizard = true
                }
                .frame(maxWidth: 820)

                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        QuietLink("Import a UTM or Orbit machine…") { router.isShowingImporter = true }
                        Text("or drop an ISO anywhere in this window.")
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text("New to virtual machines?").foregroundStyle(.secondary)
                        QuietLink("Read the guide") { NSWorkspace.shared.open(HelpLinks.guide) }
                    }
                }
                .font(.callout)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Templates grouped by engine: native first, compatibility second.
struct TemplateGrid: View {
    let onChoose: (OSTemplate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            group("Native · Apple Virtualization", OSTemplate.all.filter { $0.engine == .apple })
            group("Compatibility · QEMU", OSTemplate.all.filter { $0.engine == .qemu })
        }
    }

    private func group(_ title: String, _ templates: [OSTemplate]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                ForEach(templates) { template in
                    Button { onChoose(template) } label: { TemplateCard(template: template) }
                        .buttonStyle(.plain)
                }
            }
        }
    }
}

struct TemplateCard: View {
    let template: OSTemplate
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            OSArtwork(template: template, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(template.name).font(.body.weight(.semibold))
                Text(template.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(radius: 14, hovering: hovering)
        .offset(y: hovering ? -1 : 0)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(.rect)
    }
}

/// Understated text link in the ink color.
struct QuietLink: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).underline(true, color: .primary.opacity(0.3))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}
