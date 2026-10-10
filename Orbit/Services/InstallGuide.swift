import Foundation

/// What to choose in each system's own installer, shown in Orbit while the installer is attached.
///
/// Installers ask questions Orbit can't answer for you without modifying the official images.
/// These steps say which choice to make and, above all, which disk is the machine's: the only
/// disk a guest ever sees is its own virtual disk (and the read-only installer).
struct InstallGuide {
    struct Step: Identifiable {
        let id = UUID()
        let title: String
        var detail: String?
    }

    let steps: [Step]
    /// Where the installer's own full instructions are.
    var moreInfo: URL?

    static func guide(for config: VMConfiguration) -> InstallGuide? {
        let size = config.primaryDisk.map { "\($0.sizeGiB) GB" } ?? "virtual"
        let disk = "This machine's \(size) virtual disk. It's the only disk the guest can see: your Mac's drives are never visible to it."
        func s(_ title: String, _ detail: String? = nil) -> Step { Step(title: title, detail: detail) }

        switch config.templateID {
        case "ubuntu":
            return InstallGuide(steps: [
                s("Choose your language, accessibility and keyboard", "Next, Next, Next."),
                s("Internet: Use wired connection", "It's already connected through Orbit."),
                s("Install Ubuntu, then Interactive installation", "Then Default selection for apps."),
                s("Erase disk and install Ubuntu", disk),
                s("Create your account and choose your time zone, then Install"),
                s("When it's done: Restart now", "If it asks you to remove the installation medium, press Return. Then click Eject next to “Installer attached” in Orbit."),
            ], moreInfo: URL(string: "https://ubuntu.com/tutorials/install-ubuntu-desktop"))
        case "ubuntu-server":
            return InstallGuide(steps: [
                s("Language, keyboard, then Ubuntu Server", "Keep the defaults with Return."),
                s("Network, proxy and mirror: keep the defaults", "The network is set up automatically through Orbit."),
                s("Storage: Use an entire disk", disk + " Then Done, and Continue to confirm."),
                s("Your name, server name, username and password"),
                s("Install OpenSSH server", "Optional: lets you log in from Terminal with a port forward."),
                s("When it says Reboot Now, choose it", "Then click Eject next to “Installer attached” in Orbit."),
            ], moreInfo: URL(string: "https://ubuntu.com/tutorials/install-ubuntu-server"))
        case "debian", "kali":
            let name = config.templateID == "kali" ? "Kali" : "Debian"
            return InstallGuide(steps: [
                s("Graphical install (or Install for the text version)"),
                s("Language, location and keyboard"),
                s("Hostname: any name. Domain name: leave empty"),
                s("Your name, username and password"),
                s("Partition disks: Guided – use entire disk"),
                s("Select disk: Virtual disk 1 (vda)", disk),
                s("All files in one partition, then Finish partitioning, then Yes"),
                s("Software selection: keep the defaults", name == "Kali" ? "Kali downloads its tools now; this is the longest step." : "Debian downloads packages now; this is the longest step."),
                s("Install the GRUB boot loader: Yes, on /dev/vda"),
                s("Installation complete: Continue", "Then click Eject next to “Installer attached” in Orbit."),
            ], moreInfo: URL(string: config.templateID == "kali" ? "https://www.kali.org/docs/installation/hard-disk-install/" : "https://www.debian.org/releases/stable/arm64/"))
        case "fedora":
            return InstallGuide(steps: [
                s("Install Fedora (or Install to Hard Drive)"),
                s("Language and keyboard"),
                s("Installation destination: the virtual disk, automatic partitioning", disk),
                s("Install, then Restart when it's done", "Then click Eject next to “Installer attached” in Orbit. Fedora asks for your account on first start."),
            ], moreInfo: URL(string: "https://docs.fedoraproject.org/en-US/fedora/latest/getting-started/"))
        case "rocky", "alma":
            return InstallGuide(steps: [
                s("Wait for the installer", "It checks its own disc first; the screen stays dark for up to 3 minutes."),
                s("Language, then Continue"),
                s("Installation Destination: select the virtual disk, then Done", disk),
                s("Root password and/or User creation"),
                s("Begin Installation, then Reboot System", "Then click Eject next to “Installer attached” in Orbit."),
            ])
        case "opensuse":
            return InstallGuide(steps: [
                s("Installation, then language, keyboard and license"),
                s("Online repositories: Yes"),
                s("System role: Desktop (KDE or GNOME) or Server"),
                s("Suggested partitioning: keep it", disk),
                s("Time zone and your user"),
                s("Install, then confirm Install", "When it restarts, click Eject next to “Installer attached” in Orbit."),
            ])
        case "alpine":
            return InstallGuide(steps: [
                s("Log in as root (no password)"),
                s("Type setup-alpine and press Return", "Answer the questions; the defaults are fine."),
                s("Which disk: vda, then sys", disk),
                s("Type reboot", "Then click Eject next to “Installer attached” in Orbit."),
            ], moreInfo: URL(string: "https://wiki.alpinelinux.org/wiki/Installation"))
        case "nixos":
            return InstallGuide(steps: [
                s("NixOS installs from the command line", "Follow the manual's “Manual installation” section; the disk is /dev/vda."),
                s("Partition /dev/vda, then nixos-generate-config and nixos-install", disk),
                s("Type reboot", "Then click Eject next to “Installer attached” in Orbit."),
            ], moreInfo: URL(string: "https://nixos.org/manual/nixos/stable/#sec-installation-manual"))
        case "freebsd":
            return InstallGuide(steps: [
                s("Install, then keymap and hostname"),
                s("Partitioning: Auto (ZFS) or Auto (UFS)"),
                s("Choose the disk vtbd0", "Not da0: that's the read-only installer. " + disk),
                s("Root password, network (DHCP), time zone, user"),
                s("Exit, then Reboot", "Then click Eject next to “Installer attached” in Orbit."),
            ], moreInfo: URL(string: "https://docs.freebsd.org/en/books/handbook/bsdinstall/"))
        case "windows-arm":
            return InstallGuide(steps: [
                s("Orbit starts setup for you", "It answers “Press any key to boot from CD” on the first start."),
                s("Language, then keyboard, then Install Windows 11"),
                s("Product key: I don't have a product key", "Windows works unactivated; you can activate later."),
                s("Edition: Windows 11 Pro (or Home)"),
                s("Where to install: Disk 0, then Next", disk),
                s("After the restarts: region, keyboard, network (already online), account"),
                s("When you reach the desktop", "Click Eject next to “Installer attached” in Orbit."),
            ])
        default:
            guard config.installerMedia != nil, config.guestOS == .linux else { return nil }
            return InstallGuide(steps: [
                s("Follow the installer"),
                s("When it asks for a disk, choose the virtual disk (vda)", disk + " The installer itself is a separate read-only disk; don't install onto it."),
                s("When it's done, restart", "Then click Eject next to “Installer attached” in Orbit."),
            ])
        }
    }
}
