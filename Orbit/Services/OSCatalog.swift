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
        // Native: Apple Virtualization
        OSTemplate(id: "macos", name: "macOS", subtitle: "Latest version for this Mac", guestOS: .macOS, engine: .apple, architecture: .arm64,
                   symbol: "apple.logo", defaultDiskGiB: 96, source: .macOSRestoreImage),
        OSTemplate(id: "ubuntu", name: "Ubuntu", subtitle: "Desktop LTS · ARM64", guestOS: .linux, engine: .apple, architecture: .arm64,
                   symbol: "circle.hexagongrid.fill", defaultDiskGiB: 64, source: .resolver(.ubuntuDesktop), recommendsRosetta: true),
        OSTemplate(id: "ubuntu-server", name: "Ubuntu Server", subtitle: "LTS · ARM64 · no desktop", guestOS: .linux, engine: .apple, architecture: .arm64,
                   symbol: "server.rack", defaultDiskGiB: 32, source: .resolver(.ubuntuServer), recommendsRosetta: true),
        OSTemplate(id: "fedora", name: "Fedora", subtitle: "Workstation · ARM64", guestOS: .linux, engine: .apple, architecture: .arm64,
                   symbol: "f.circle.fill", defaultDiskGiB: 64, source: .resolver(.fedoraWorkstation), recommendsRosetta: true),
        OSTemplate(id: "debian", name: "Debian", subtitle: "Stable netinst · ARM64", guestOS: .linux, engine: .apple, architecture: .arm64,
                   symbol: "tornado", defaultDiskGiB: 48, source: .resolver(.debianNetinst), recommendsRosetta: true),
        OSTemplate(id: "kali", name: "Kali Linux", subtitle: "Security testing · ARM64", guestOS: .linux, engine: .apple, architecture: .arm64,
                   symbol: "shield.lefthalf.filled", defaultDiskGiB: 64, source: .resolver(.kaliInstaller), recommendsRosetta: true),
        OSTemplate(id: "rocky", name: "Rocky Linux", subtitle: "Enterprise · RHEL-compatible", guestOS: .linux, engine: .apple, architecture: .arm64,
                   symbol: "mountain.2", defaultDiskGiB: 32, source: .resolver(.rockyMinimal), recommendsRosetta: true),
        OSTemplate(id: "alma", name: "AlmaLinux", subtitle: "Enterprise · RHEL-compatible", guestOS: .linux, engine: .apple, architecture: .arm64,
                   symbol: "leaf", defaultDiskGiB: 32, source: .resolver(.almaMinimal), recommendsRosetta: true),
        OSTemplate(id: "opensuse", name: "openSUSE", subtitle: "Tumbleweed rolling · ARM64", guestOS: .linux, engine: .apple, architecture: .arm64,
                   symbol: "tortoise", defaultDiskGiB: 48, source: .resolver(.openSUSETumbleweed), recommendsRosetta: true),
        OSTemplate(id: "nixos", name: "NixOS", subtitle: "Declarative · ARM64", guestOS: .linux, engine: .apple, architecture: .arm64,
                   symbol: "snowflake", defaultDiskGiB: 32, source: .resolver(.nixosMinimal), recommendsRosetta: true),
        OSTemplate(id: "alpine", name: "Alpine", subtitle: "Tiny & fast · ARM64", guestOS: .linux, engine: .apple, architecture: .arm64,
                   symbol: "mountain.2.fill", defaultDiskGiB: 16, source: .resolver(.alpineVirt)),
        OSTemplate(id: "linux-custom", name: "Other Linux", subtitle: "Any ARM64 ISO · native", guestOS: .linux, engine: .apple, architecture: .arm64,
                   symbol: "terminal.fill", defaultDiskGiB: 64, source: .custom, recommendsRosetta: true),
        // Compatibility: QEMU
        OSTemplate(id: "windows-arm", name: "Windows 11", subtitle: "ARM64 · via QEMU + HVF", guestOS: .windows, engine: .qemu, architecture: .arm64,
                   symbol: "square.grid.2x2.fill", defaultDiskGiB: 80,
                   source: .manual(downloadPage: URL(string: "https://www.microsoft.com/software-download/windows11arm64")!)),
        OSTemplate(id: "freebsd", name: "FreeBSD", subtitle: "ARM64 · via QEMU + HVF", guestOS: .other, engine: .qemu, architecture: .arm64,
                   symbol: "ladybug", defaultDiskGiB: 32, source: .resolver(.freeBSD)),
        OSTemplate(id: "emulated", name: "Emulated PC", subtitle: "x86-64 · any OS, slower", guestOS: .other, engine: .qemu, architecture: .x86_64,
                   symbol: "cpu.fill", defaultDiskGiB: 64, source: .custom),
    ]

    static func template(id: String?) -> OSTemplate? {
        all.first { $0.id == id }
    }
}

enum ISOResolver: Hashable {
    case ubuntuDesktop
    case ubuntuServer
    case fedoraWorkstation
    case debianNetinst
    case alpineVirt
    case kaliInstaller
    case rockyMinimal
    case almaMinimal
    case openSUSETumbleweed
    case nixosMinimal
    case freeBSD

    struct Resolved {
        let url: URL
        let version: String
        /// Published SHA-256 list the download is verified against.
        let checksumURL: URL?
    }

    func resolve() async throws -> Resolved {
        switch self {
        case .ubuntuDesktop, .ubuntuServer:
            let flavor = self == .ubuntuDesktop ? "desktop" : "live-server"
            let root = URL(string: "https://cdimage.ubuntu.com/releases/")!
            // newest LTS: even year, .04
            let series = try await Self.links(at: root, matching: #"^(\d\d)\.04/$"#)
                .compactMap { Int($0.prefix(2)) }
                .filter { $0.isMultiple(of: 2) }
                .sorted(by: >)
            for year in series {
                let dir = root.appendingPathComponent("\(year).04/release/")
                let isos = try? await Self.links(at: dir, matching: "^ubuntu-[\\d.]+-\(flavor)-arm64\\.iso$")
                if let best = isos?.max(by: Self.versionOrder) {
                    return Resolved(url: dir.appendingPathComponent(best), version: Self.version(in: best),
                                    checksumURL: dir.appendingPathComponent("SHA256SUMS"))
                }
            }
        case .fedoraWorkstation:
            let root = URL(string: "https://dl.fedoraproject.org/pub/fedora/linux/releases/")!
            let releases = try await Self.links(at: root, matching: #"^\d+/$"#).compactMap { Int($0.dropLast()) }.sorted(by: >)
            for release in releases.prefix(3) {
                let dir = root.appendingPathComponent("\(release)/Workstation/aarch64/iso/")
                guard let names = try? await Self.links(at: dir, matching: #"^Fedora-Workstation-.*aarch64.*(\.iso|CHECKSUM)$"#),
                      let iso = names.first(where: { $0.hasSuffix(".iso") }) else { continue }
                return Resolved(url: dir.appendingPathComponent(iso), version: "\(release)",
                                checksumURL: names.first { $0.hasSuffix("CHECKSUM") }.map(dir.appendingPathComponent))
            }
        case .debianNetinst:
            let dir = URL(string: "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/")!
            if let iso = try await Self.links(at: dir, matching: #"^debian-[\d.]+-arm64-netinst\.iso$"#).max(by: Self.versionOrder) {
                return Resolved(url: dir.appendingPathComponent(iso), version: Self.version(in: iso), checksumURL: dir.appendingPathComponent("SHA256SUMS"))
            }
        case .alpineVirt:
            let dir = URL(string: "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/")!
            if let iso = try await Self.links(at: dir, matching: #"^alpine-virt-[\d.]+-aarch64\.iso$"#).max(by: Self.versionOrder) {
                return Resolved(url: dir.appendingPathComponent(iso), version: Self.version(in: iso), checksumURL: dir.appendingPathComponent(iso + ".sha256"))
            }
        case .kaliInstaller:
            let dir = URL(string: "https://cdimage.kali.org/current/")!
            if let iso = try await Self.links(at: dir, matching: #"^kali-linux-[\d.]+-installer-arm64\.iso$"#).max(by: Self.versionOrder) {
                return Resolved(url: dir.appendingPathComponent(iso), version: Self.version(in: iso), checksumURL: dir.appendingPathComponent("SHA256SUMS"))
            }
        case .rockyMinimal, .almaMinimal:
            let isRocky = self == .rockyMinimal
            let root = URL(string: isRocky ? "https://download.rockylinux.org/pub/rocky/" : "https://repo.almalinux.org/almalinux/")!
            let majors = try await Self.links(at: root, matching: #"^\d+/$"#).compactMap { Int($0.dropLast()) }.sorted(by: >)
            for major in majors.prefix(2) {
                let dir = root.appendingPathComponent("\(major)/isos/aarch64/")
                let pattern = isRocky ? #"^Rocky-[\d.]+-aarch64-minimal\.iso$"# : #"^AlmaLinux-[\d.]+-aarch64-minimal\.iso$"#
                if let iso = try? await Self.links(at: dir, matching: pattern).max(by: Self.versionOrder) {
                    let sums = isRocky ? dir.appendingPathComponent(iso + ".CHECKSUM") : dir.appendingPathComponent("CHECKSUM")
                    return Resolved(url: dir.appendingPathComponent(iso), version: Self.version(in: iso), checksumURL: sums)
                }
            }
        case .openSUSETumbleweed:
            // "Current" is a moving alias; its checksum file names the dated snapshot, which is what
            // gets cached so a newer snapshot is never mistaken for an old download
            let dir = URL(string: "https://download.opensuse.org/ports/aarch64/tumbleweed/iso/")!
            let current = dir.appendingPathComponent("openSUSE-Tumbleweed-NET-aarch64-Current.iso")
            let sums = current.appendingPathExtension("sha256")
            let (data, _) = try await URLSession.shared.data(from: sums)
            let text = String(decoding: data, as: UTF8.self)
            if let snapshot = text.firstMatch(of: /openSUSE-Tumbleweed-NET-aarch64-Snapshot(\d+)-Media\.iso/) {
                return Resolved(url: dir.appendingPathComponent(String(snapshot.output.0)), version: String(snapshot.output.1), checksumURL: sums)
            }
        case .nixosMinimal:
            // stable channels are YY.05 and YY.11; use the newest one that exists
            let year = Calendar.current.component(.year, from: .now) % 100
            for (y, m) in [(year, "11"), (year, "05"), (year - 1, "11"), (year - 1, "05")] {
                let channel = URL(string: "https://channels.nixos.org/nixos-\(y).\(m)/latest-nixos-minimal-aarch64-linux.iso")!
                var request = URLRequest(url: channel)
                request.httpMethod = "HEAD"
                guard let (_, response) = try? await URLSession.shared.data(for: request),
                      let http = response as? HTTPURLResponse, http.statusCode == 200, let final = http.url else { continue }
                // the redirect target carries the exact version in its name
                return Resolved(url: final, version: "\(y).\(m)", checksumURL: channel.appendingPathExtension("sha256"))
            }
        case .freeBSD:
            let root = URL(string: "https://download.freebsd.org/releases/ISO-IMAGES/")!
            let releases = try await Self.links(at: root, matching: #"^\d+\.\d+/$"#).map { String($0.dropLast()) }
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            for release in releases.prefix(3) {
                let dir = root.appendingPathComponent("\(release)/")
                let iso = "FreeBSD-\(release)-RELEASE-arm64-aarch64-disc1.iso"
                guard let names = try? await Self.links(at: dir, matching: #"aarch64"#), names.contains(iso) else { continue }
                return Resolved(url: dir.appendingPathComponent(iso), version: release,
                                checksumURL: dir.appendingPathComponent("CHECKSUM.SHA256-FreeBSD-\(release)-RELEASE-arm64-aarch64"))
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
        let href = try NSRegularExpression(pattern: #"href="(?:\./)?([^"?/][^"?]*)""#)
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
        case "ubuntu-server": "logo-ubuntu"
        case "kali": "logo-kali"
        case "rocky": "logo-rocky"
        case "alma": "logo-alma"
        case "opensuse": "logo-opensuse"
        case "nixos": "logo-nixos"
        case "freebsd": "logo-freebsd"
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
