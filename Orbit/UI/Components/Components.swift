import SwiftUI

// MARK: - Theme

/// Restrained, monochrome palette: graphite surfaces, one neutral ink, color only for status.
enum Theme {
    /// App-wide tint: graphite in light mode, silver in dark mode.
    static let ink = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.80, alpha: 1)
            : NSColor(white: 0.20, alpha: 1)
    })

    static let hairline = Color.primary.opacity(0.08)
    static let surface = Color.primary.opacity(0.035)
    static let surfaceHover = Color.primary.opacity(0.06)

    static let cardRadius: CGFloat = 14
    static let heroRadius: CGFloat = 20
}

extension View {
    /// Quiet card: faint fill, hairline border, no shadow.
    func surface(radius: CGFloat = Theme.cardRadius, hovering: Bool = false) -> some View {
        background(hovering ? Theme.surfaceHover : Theme.surface, in: .rect(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline)
            }
    }
}

extension VMState {
    /// The only color in the UI.
    var tint: Color {
        switch self {
        case .running: .green
        case .paused: .yellow
        case .stopped: .secondary
        default: .secondary
        }
    }
}

extension VMConfiguration {
    var symbol: String {
        OSTemplate.template(id: templateID)?.symbol ?? guestOS.symbol
    }

    /// Real OS logo; an emulated PC that was told it runs Windows or Linux gets that logo.
    var logo: String? {
        if let template = OSTemplate.template(id: templateID), let logo = template.logo { return logo }
        return guestOS.logo
    }

    var specLine: String {
        "\(cpuCount) CPU · \(memoryMiB.formattedMemory) · \(totalDiskGiB) GB"
    }
}

extension Int {
    /// MiB → "8 GB" / "512 MB".
    var formattedMemory: String {
        self >= 1024 ? (self % 1024 == 0 ? "\(self / 1024) GB" : String(format: "%.1f GB", Double(self) / 1024)) : "\(self) MB"
    }
}

// MARK: - Artwork

/// Monochrome glyph tile used as a VM's icon.
struct OSArtwork: View {
    let symbol: String
    let logo: String?
    var size: CGFloat = 40

    init(config: VMConfiguration, size: CGFloat = 40) {
        self.symbol = config.symbol
        self.logo = config.logo
        self.size = size
    }

    init(template: OSTemplate, size: CGFloat = 40) {
        self.symbol = template.symbol
        self.logo = template.logo
        self.size = size
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        shape
            .fill(LinearGradient(colors: [Color.primary.opacity(0.13), Color.primary.opacity(0.05)], startPoint: .top, endPoint: .bottom))
            .overlay {
                Group {
                    if let logo {
                        Image(logo)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: size * 0.5, height: size * 0.5)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: size * 0.44, weight: .medium))
                    }
                }
                .foregroundStyle(.primary.opacity(0.88))
            }
            .overlay { shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5) }
            .frame(width: size, height: size)
    }
}

/// Orbit's mark: a planet with a tilted ring and a moon that slowly travels along it.
struct OrbitMark: View {
    var size: CGFloat = 64
    var animated = true

    var body: some View {
        TimelineView(.animation(paused: !animated)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let angle = animated ? t.truncatingRemainder(dividingBy: 12) / 12 * 2 * .pi : 0.4
            Canvas { ctx, canvas in
                let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
                let r = canvas.width * 0.2
                let ringW = canvas.width * 0.46, ringH = canvas.width * 0.13
                let tilt = Angle.degrees(-18)
                func ringPoint(_ a: Double) -> CGPoint {
                    let x = cos(a) * ringW, y = sin(a) * ringH
                    return CGPoint(x: c.x + x * cos(tilt.radians) - y * sin(tilt.radians),
                                   y: c.y + x * sin(tilt.radians) + y * cos(tilt.radians))
                }
                var ring = Path()
                ring.addEllipse(in: CGRect(x: -ringW, y: -ringH, width: ringW * 2, height: ringH * 2))
                let transform = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: tilt.radians)
                let moon = ringPoint(angle)
                let moonBehind = sin(angle) < 0
                let style = StrokeStyle(lineWidth: canvas.width * 0.022, lineCap: .round)
                ctx.stroke(ring.applying(transform), with: .color(.primary.opacity(0.35)), style: style)
                let moonR = canvas.width * 0.045
                let moonPath = Path(ellipseIn: CGRect(x: moon.x - moonR, y: moon.y - moonR, width: moonR * 2, height: moonR * 2))
                if moonBehind { ctx.fill(moonPath, with: .color(.primary.opacity(0.5))) }
                let planet = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                ctx.fill(planet, with: .linearGradient(Gradient(colors: [.primary.opacity(0.9), .primary.opacity(0.45)]),
                                                       startPoint: CGPoint(x: c.x - r, y: c.y - r), endPoint: CGPoint(x: c.x + r, y: c.y + r)))
                // front half of the ring passes over the planet
                var front = ctx
                front.clip(to: Path(CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)).applying(.identity))
                front.clipToLayer { layer in
                    layer.fill(Path(CGRect(x: -canvas.width, y: 0, width: canvas.width * 3, height: canvas.height)).applying(transform),
                               with: .color(.black))
                }
                front.stroke(ring.applying(transform), with: .color(.primary.opacity(0.8)), style: style)
                if !moonBehind { ctx.fill(moonPath, with: .color(.primary)) }
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Status

struct StatusDot: View {
    let state: VMState

    var body: some View {
        Circle()
            .fill(state.tint)
            .frame(width: 7, height: 7)
            .overlay {
                if state.isBusy || state == .installing {
                    Circle().stroke(Color.secondary.opacity(0.6), lineWidth: 1.5).scaleEffect(1.9)
                        .phaseAnimator([0.2, 1]) { view, phase in view.opacity(phase) }
                }
            }
    }
}

struct StatusPill: View {
    let state: VMState
    var detail: String?

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(state: state)
            Text(detail ?? state.label)
                .font(.callout.weight(.medium))
                .monospacedDigit()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
    }
}

// MARK: - Stats

/// Quiet stat: caption, value, optional usage bar.
struct SpecTile: View {
    let symbol: String
    let caption: String
    let value: String
    var detail: String?
    var usage: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(caption, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Text(value)
                .font(.system(.title3, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let usage {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 3)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule().fill(Color.primary.opacity(0.55)).frame(width: max(3, geo.size.width * min(1, usage)))
                        }
                    }
            }
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .padding(14)
        .surface()
    }
}

/// Slider with a "recommended" reset and live value.
struct ResourceSlider: View {
    let title: String
    let symbol: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    var recommended: Int?
    var format: (Int) -> String = { "\($0)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if let recommended, recommended != value {
                    Button("Reset") { value = recommended }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Recommended: \(format(recommended))")
                }
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 52, alignment: .trailing)
            }
            Slider(value: Binding(get: { Double(value) }, set: { value = Int(($0 / Double(step)).rounded()) * step }),
                   in: Double(range.lowerBound)...Double(max(range.upperBound, range.lowerBound + step)),
                   step: Double(step))
        }
    }
}

/// Section with a small uppercase header, used by the detail page.
struct Card<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title)
                Spacer()
                accessory
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

/// Live-updating "1h 3m".
struct UptimeText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Duration.seconds(context.date.timeIntervalSince(since)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))
                .monospacedDigit()
        }
    }
}
