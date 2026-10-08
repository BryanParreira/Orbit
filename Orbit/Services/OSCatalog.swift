import Foundation

/// How the installer for a template is obtained.
enum InstallerSource: Hashable {
    /// Apple's latest restore image supported by this Mac, via Virtualization.
    case macOSRestoreImage
    /// Resolved at download time from the distro's mirror index, so versions never go stale.
    case resolver(ISOResolver)
    /// No direct link (licensing); user picks a file, we link the official page.
    case manual(downloadPage: URL)
    /// Bring your own image.
    case custom
}

struct OSTemplate: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let guestOS: GuestOS
    let engine: VMEngineKind
    let architecture: GuestArchitecture
    let symbol: String
    let defaultDiskGiB: Int
    let source: InstallerSource
    var recommendsRosetta = false

    static let all: [OSTemplate] = [
        OSTemplate(id: "macos", name: "macOS", subtitle: "Latest version for this Mac", guestOS: .macOS, engine: .apple, architecture: .arm64,
                   symbol: "apple.logo", defaultDiskGiB: 96, source: .macOSRestoreImage),
        OSTemplate(id: "ubuntu", name: "Ubuntu", subtitle: "Desktop LTS · ARM64", guestOS: .linux, engine: .apple, architecture: .arm64,
                   symbol: "circle.hexagongrid.fill", defaultDiskGiB: 64, source: .resolver(.ubuntuDesktop), recommendsRosetta: true),
        OSTemplate(id: "fedora", name: "Fedora", subtitle: "Workstation · ARM64", guestOS: .linux, engine: .apple, architecture: .arm64,
                   symbol: "f.circle.fill", defaultDiskGiB: 64, source: .resolver(.fedoraWorkstation), recommendsRosetta: true),
        OSTemplate(id: "debian", name: "Debian", subtitle: "Stable netinst · ARM64", guestOS: .linux, engine: .apple, architecture: .arm64,
                   symbol: "tornado", defaultDiskGiB: 48, source: .resolver(.debianNetinst), recommendsRosetta: true),
        OSTemplate(id: "alpine", name: "Alpine", subtitle: "Tiny & fast · ARM64", guestOS: .linux, engine: .apple, architecture: .arm64,
                   symbol: "mountain.2.fill", defaultDiskGiB: 16, source: .resolver(.alpineVirt)),
        OSTemplate(id: "windows-arm", name: "Windows 11", subtitle: "ARM64 · via QEMU + HVF", guestOS: .windows, engine: .qemu, architecture: .arm64,
                   symbol: "square.grid.2x2.fill", defaultDiskGiB: 80,
                   source: .manual(downloadPage: URL(string: "https://www.microsoft.com/software-download/windows11arm64")!)),
        OSTemplate(id: "linux-custom", name: "Other Linux", subtitle: "Any ARM64 ISO · native", guestOS: .linux, engine: .apple, architecture: .arm64,
                   symbol: "terminal.fill", defaultDiskGiB: 64, source: .custom, recommendsRosetta: true),
        OSTemplate(id: "emulated", name: "Emulated PC", subtitle: "x86-64 · any OS, slower", guestOS: .other, engine: .qemu, architecture: .x86_64,
                   symbol: "cpu.fill", defaultDiskGiB: 64, source: .custom),
    ]

    static func template(id: String?) -> OSTemplate? {
        all.first { $0.id == id }
    }
}

enum ISOResolver: Hashable {
    case ubuntuDesktop
    case fedoraWorkstation
    case debianNetinst
    case alpineVirt

    struct Resolved {
        let url: URL
        let version: String
    }

    func resolve() async throws -> Resolved {
        switch self {
        case .ubuntuDesktop:
            let root = URL(string: "https://cdimage.ubuntu.com/releases/")!
            // newest LTS: even year, .04
            let series = try await Self.links(at: root, matching: #"^(\d\d)\.04/$"#)
                .compactMap { Int($0.prefix(2)) }
                .filter { $0.isMultiple(of: 2) }
                .sorted(by: >)
            for year in series {
                let dir = root.appendingPathComponent("\(year).04/release/")
                let isos = try? await Self.links(at: dir, matching: #"^ubuntu-[\d.]+-desktop-arm64\.iso$"#)
                if let best = isos?.max(by: Self.versionOrder) {
                    return Resolved(url: dir.appendingPathComponent(best), version: Self.version(in: best))
                }
            }
        case .fedoraWorkstation:
            let root = URL(string: "https://dl.fedoraproject.org/pub/fedora/linux/releases/")!
            let releases = try await Self.links(at: root, matching: #"^\d+/$"#).compactMap { Int($0.dropLast()) }.sorted(by: >)
            for release in releases.prefix(3) {
                let dir = root.appendingPathComponent("\(release)/Workstation/aarch64/iso/")
                if let iso = try? await Self.links(at: dir, matching: #"^Fedora-Workstation-Live-.*\.aarch64\.iso$"#).first {
                    return Resolved(url: dir.appendingPathComponent(iso), version: "\(release)")
                }
            }
        case .debianNetinst:
            let dir = URL(string: "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/")!
            if let iso = try await Self.links(at: dir, matching: #"^debian-[\d.]+-arm64-netinst\.iso$"#).max(by: Self.versionOrder) {
                return Resolved(url: dir.appendingPathComponent(iso), version: Self.version(in: iso))
            }
        case .alpineVirt:
            let dir = URL(string: "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/")!
            if let iso = try await Self.links(at: dir, matching: #"^alpine-virt-[\d.]+-aarch64\.iso$"#).max(by: Self.versionOrder) {
                return Resolved(url: dir.appendingPathComponent(iso), version: Self.version(in: iso))
            }
        }
        throw URLError(.resourceUnavailable)
    }

    /// `href` targets in an Apache/nginx directory index that match `pattern`.
    private static func links(at url: URL, matching pattern: String) async throws -> [String] {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let html = String(data: data, encoding: .utf8) else {
            throw URLError(.badServerResponse)
        }
        let href = try NSRegularExpression(pattern: #"href="([^"?/][^"?]*)""#)
        let filter = try NSRegularExpression(pattern: pattern)
        let names = href.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match -> String? in
            Range(match.range(at: 1), in: html).map { String(html[$0]) }
        }
        return Array(Set(names.filter { filter.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }))
    }

    private static func version(in name: String) -> String {
        name.firstMatch(of: /\d+(\.\d+)+/).map { String($0.output.0) } ?? name
    }

    private static func versionOrder(_ a: String, _ b: String) -> Bool {
        version(in: a).compare(version(in: b), options: .numeric) == .orderedAscending
    }
}

extension OSTemplate {
    /// Monochrome brand mark in the asset catalog (Simple Icons, CC0), nil to use `symbol`.
    var logo: String? {
        switch id {
        case "macos": "logo-apple"
        case "ubuntu": "logo-ubuntu"
        case "fedora": "logo-fedora"
        case "debian": "logo-debian"
        case "alpine": "logo-alpine"
        case "windows-arm": "logo-windows"
        case "linux-custom": "logo-linux"
        default: nil
        }
    }
}

extension GuestOS {
    var logo: String? {
        switch self {
        case .macOS: "logo-apple"
        case .linux: "logo-linux"
        case .windows: "logo-windows"
        case .other: nil
        }
    }
}
