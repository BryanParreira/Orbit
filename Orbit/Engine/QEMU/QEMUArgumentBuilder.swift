import Foundation

/// Builds a QEMU command line tuned for Apple Silicon hosts.
struct QEMUArgumentBuilder {
    let config: VMConfiguration
    let bundle: VMBundle
    let qmpSocket: String
    let dataDirectory: URL
    var tpmSocket: String?
    /// Start from the installer before the disk. The backend turns this off once Windows is on
    /// the disk, so a still-attached installer doesn't ask "Press any key" on every start.
    var bootsFromInstaller = true
    var overlayDirectory: URL?

    var efiVariablesURL: URL { bundle.url.appendingPathComponent("EFIVariables.fd") }

    private var isArm: Bool { config.architecture == .arm64 }
    private var isNative: Bool { config.architecture.isNative }

    func firmwareCodeURL() -> URL {
        dataDirectory.appendingPathComponent(isArm ? "edk2-aarch64-code.fd" : "edk2-x86_64-code.fd")
    }

    func firmwareVarsTemplateURL() -> URL {
        dataDirectory.appendingPathComponent(isArm ? "edk2-arm-vars.fd" : "edk2-i386-vars.fd")
    }

    func build() -> [String] {
        var args: [String] = ["-name", config.name]

        // Machine + acceleration
        let machine = config.qemu.machine ?? (isArm ? "virt" : "q35")
        args += ["-machine", machine]
        if isNative {
            args += ["-accel", "hvf", "-cpu", "host"]
        } else {
            // multi-threaded TCG + large translation cache: the biggest wins for emulated guests
            args += ["-accel", "tcg,thread=multi,tb-size=\(config.qemu.tcgCacheMiB)", "-cpu", "max"]
        }
        args += ["-smp", "cpus=\(config.cpuCount),sockets=1,cores=\(config.cpuCount),threads=1"]
        args += ["-m", "\(config.memoryMiB)"]
        // Windows keeps the hardware clock in local time; others use UTC
        if config.guestOS == .windows {
            args += ["-rtc", "base=localtime"]
        }

        // UEFI firmware
        args += ["-drive", "if=pflash,format=raw,unit=0,readonly=on,file=\(q(firmwareCodeURL().path))"]
        args += ["-drive", "if=pflash,format=raw,unit=1,file=\(q(resolve(efiVariablesURL).path))"]

        // Display: QEMU's native Cocoa window with HiDPI scaling
        #if DEBUG
        // self-tests: QEMU's window activates itself, which would send the user's typing to the guest
        let headless = UserDefaults.standard.bool(forKey: "OrbitHeadlessQEMU")
        #else
        let headless = false
        #endif
        args += ["-display", headless ? "none" : "cocoa,zoom-to-fit=on,zoom-interpolation=on,show-cursor=on"]
        switch (config.guestOS, isArm) {
        // Windows, FreeBSD and other non-Linux ARM systems draw their console on the firmware's
        // linear framebuffer: virtio-gpu has none, so their screen would freeze at the boot logo
        case (.windows, true), (.other, true): args += ["-device", "ramfb"]
        case (_, true): args += ["-device", "virtio-gpu-pci"]
        case (.linux, false): args += ["-device", "virtio-vga"]
        default: args += ["-vga", "std"]
        }

        // Input
        args += ["-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0", "-device", "usb-tablet,bus=xhci.0"]

        // Disks
        let cache = switch config.diskPerformance {
        case .safe: "writethrough"
        case .balanced: "writeback"
        case .fast: "unsafe"
        }
        var index = 0
        for disk in config.disks {
            let url = disk.isRemovable ? bundle.diskURL(for: disk) : resolve(bundle.diskURL(for: disk))
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let id = "drive\(index)"
            index += 1
            if disk.isRemovable {
                args += ["-drive", "if=none,id=\(id),media=cdrom,readonly=on,file=\(q(url.path))"]
                // only the installer boots; a drivers disc next to it is just data
                let boot = bootsFromInstaller && disk.id == config.installerMedia?.id ? ",bootindex=0" : ""
                if isArm {
                    args += ["-device", "usb-storage,bus=xhci.0,drive=\(id),removable=on\(boot)"]
                } else {
                    args += ["-device", "ide-cd,drive=\(id)\(boot)"]
                }
                continue
            }
            let format = url.pathExtension == "qcow2" ? "qcow2" : "raw"
            let ro = disk.isReadOnly ? ",readonly=on" : ""
            args += ["-drive", "if=none,id=\(id),format=\(format),file=\(q(url.path)),cache=\(cache),discard=unmap,detect-zeroes=unmap\(ro)"]
            let boot = ",bootindex=\(index)"
            switch disk.interface {
            case .nvme: args += ["-device", "nvme,drive=\(id),serial=orbit\(index)\(boot)"]
            case .usb: args += ["-device", "usb-storage,bus=xhci.0,drive=\(id)\(boot)"]
            case .virtio: args += ["-device", "virtio-blk-pci,drive=\(id)\(boot)"]
            }
        }

        // Network: user-mode NAT with port forwards (vmnet modes need root for QEMU)
        if config.network.mode == .none {
            args += ["-nic", "none"]
        } else {
            var netdev = "user,id=net0"
            for forward in config.network.portForwards {
                netdev += ",hostfwd=\(forward.isUDP ? "udp" : "tcp")::\(forward.hostPort)-:\(forward.guestPort)"
            }
            args += ["-netdev", netdev, "-device", "virtio-net-pci,netdev=net0,mac=\(config.network.macAddress)"]
        }

        // Audio
        if config.audioOutput {
            args += ["-audiodev", "coreaudio,id=audio0", "-device", "intel-hda", "-device", "hda-output,audiodev=audio0"]
        }

        // Paravirtual helpers
        args += ["-device", "virtio-rng-pci", "-device", "virtio-balloon-pci"]

        // Shared folders over 9p
        for (i, folder) in config.sharedFolders.enumerated() where FileManager.default.fileExists(atPath: folder.path) {
            let ro = folder.isReadOnly ? ",readonly=on" : ""
            args += ["-virtfs", "local,path=\(q(folder.path)),mount_tag=share\(i == 0 ? "" : "\(i)"),security_model=mapped-xattr,id=fs\(i)\(ro)"]
        }

        // TPM 2.0 (Windows 11)
        if let tpmSocket {
            args += ["-chardev", "socket,id=chrtpm,path=\(q(tpmSocket))", "-tpmdev", "emulator,id=tpm0,chardev=chrtpm"]
            // ppi=off on ARM: its small RAM window isn't page-aligned for Apple Silicon's 16 KB pages,
            // and HVF refuses to map it (HV_BAD_ARGUMENT). Physical presence is a PC feature anyway.
            args += ["-device", isArm ? "tpm-tis-device,tpmdev=tpm0,ppi=off" : "tpm-tis,tpmdev=tpm0"]
        }

        // Control channel
        args += ["-qmp", "unix:\(q(qmpSocket)),server=on,wait=off"]
        args += ["-monitor", "none", "-serial", "none"]

        args += config.qemu.extraArguments
        return args
    }

    /// QEMU splits option values on commas; a literal comma is written twice. Without this a
    /// file named "x,readonly=off" would inject options.
    private func q(_ value: String) -> String {
        value.replacingOccurrences(of: ",", with: ",,")
    }

    private func resolve(_ url: URL) -> URL {
        guard let overlayDirectory else { return url }
        let candidate = overlayDirectory.appendingPathComponent(url.lastPathComponent)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : url
    }
}
