import Foundation

/// Converts a UTM `.utm` package into an Orbit VM. Disk images are APFS-cloned, so the
/// import is instant and the original UTM VM keeps working.
@MainActor
enum UTMImporter {
    static func importPackage(at url: URL, into library: VMLibrary) async throws -> VMInstance {
        let plistURL = url.appendingPathComponent("config.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw VMError.invalidConfiguration("This UTM package has no readable config.plist.")
        }
        let dataDir = url.appendingPathComponent("Data", isDirectory: true)
        guard !PackageValidator.isSymbolicLink(dataDir) else {
            throw VMError.invalidConfiguration("This UTM package's Data folder is a link to somewhere else on this Mac, so it can't be imported.")
        }
        let info = root["Information"] as? [String: Any] ?? [:]
        let system = root["System"] as? [String: Any] ?? [:]
        let isApple = (root["Backend"] as? String) == "Apple"

        let name = library.uniqueName(info["Name"] as? String ?? url.deletingPathExtension().lastPathComponent)
        let cpus = (system["CPUCount"] as? Int).flatMap { $0 > 0 ? $0 : nil } ?? HostInfo.recommendedCPUs
        let memory = system["MemorySize"] as? Int ?? 4096

        var guestOS: GuestOS = .linux
        var arch: GuestArchitecture = .arm64
        if isApple {
            let boot = system["Boot"] as? [String: Any] ?? [:]
            guestOS = (boot["OperatingSystem"] as? String) == "macOS" ? .macOS : .linux
        } else {
            arch = (system["Architecture"] as? String) == "x86_64" ? .x86_64 : .arm64
            guestOS = .other
        }

        var config = VMConfiguration(name: name, engine: isApple ? .apple : .qemu, guestOS: guestOS,
                                     architecture: arch, cpuCount: cpus, memoryMiB: memory)
        config.notes = info["Notes"] as? String ?? ""
        config.templateID = guestOS == .macOS ? "macos" : (arch == .x86_64 ? "emulated" : "linux-custom")
        config.bootFromInstaller = false

        let bundle = try library.makeBundle(named: name)
        do {
            // Discs stay in the UTM package (read-only, checked to be real files inside it)
            var discs: [DiskConfiguration] = []
            // Drives
            for drive in root["Drive"] as? [[String: Any]] ?? [] {
                guard let imageName = drive["ImageName"] as? String, PackageValidator.isContainedName(imageName) else { continue }
                let source = dataDir.appendingPathComponent(imageName)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                // cloning follows a link, which would copy whatever file it names into the machine
                guard !PackageValidator.isSymbolicLink(source) else {
                    throw VMError.invalidConfiguration("The UTM package's drive “\(imageName)” is a link to a file outside the package, so it wasn't imported.")
                }
                let isCD = (drive["ImageType"] as? String) == "CD" || (drive["External"] as? Bool) == true
                if isCD {
                    discs.append(DiskConfiguration(path: source.path, sizeGiB: 0, isReadOnly: true, interface: .usb, isRemovable: true))
                    continue
                }
                let format: DiskFormat = if case .diskImage(let f) = FileInspector.inspect(source) { f } else { .raw }
                try await DiskImageSafety.check(source, format: format, qemuImg: HostInfo.qemuImg())
                try await FileCloner.cloneInBackground(source, to: bundle.url.appendingPathComponent(imageName))
                let interface: DiskInterface = switch drive["Interface"] as? String {
                case "NVMe": .nvme
                case "USB": .usb
                default: (drive["Nvme"] as? Bool) == true ? .nvme : .virtio
                }
                // virtual size, not file size: qcow2 and sparse images are much smaller than the disk they hold
                let size = await FileInspector.virtualSizeGiB(of: source, format: format)
                config.disks.append(DiskConfiguration(path: imageName, sizeGiB: size,
                                                      isReadOnly: drive["ReadOnly"] as? Bool ?? false, interface: interface))
            }

            // Network
            if let network = (root["Network"] as? [[String: Any]])?.first {
                if let mac = network["MacAddress"] as? String { config.network.macAddress = mac.lowercased() }
                if (network["Mode"] as? String) == "Bridged" { config.network.mode = .bridged }
                config.network.bridgeInterface = network["BridgeInterface"] as? String
            } else {
                config.network.mode = .none
            }

            if isApple {
                try importApplePlatform(system: system, dataDir: dataDir, bundle: bundle, config: &config, root: root)
            } else {
                let efi = dataDir.appendingPathComponent("efi_vars.fd")
                if FileManager.default.fileExists(atPath: efi.path), !PackageValidator.isSymbolicLink(efi) {
                    try FileCloner.clone(efi, to: bundle.url.appendingPathComponent("EFIVariables.fd"))
                }
            }
            PackageValidator.sanitize(&config, imported: true)
            config.disks += discs
            if let screenshot = ["screenshot.png", "Screenshot.png"].map({ dataDir.appendingPathComponent($0) })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) && !PackageValidator.isSymbolicLink($0) }) {
                try? FileCloner.clone(screenshot, to: bundle.screenshotURL)
            }
            return try library.register(bundle: bundle, config: config)
        } catch {
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
        }
    }

    private static func importApplePlatform(system: [String: Any], dataDir: URL, bundle: VMBundle, config: inout VMConfiguration, root: [String: Any]) throws {
        let boot = system["Boot"] as? [String: Any] ?? [:]
        if config.guestOS == .macOS {
            let mac = system["MacPlatform"] as? [String: Any] ?? [:]
            guard let model = mac["HardwareModel"] as? Data, let identifier = mac["MachineIdentifier"] as? Data,
                  let aux = mac["AuxiliaryStoragePath"] as? String else {
                throw VMError.invalidConfiguration("The UTM macOS VM is missing its platform data.")
            }
            try model.write(to: bundle.hardwareModelURL)
            try identifier.write(to: bundle.machineIdentifierURL)
            guard PackageValidator.isContainedName(aux), !PackageValidator.isSymbolicLink(dataDir.appendingPathComponent(aux)) else {
                throw VMError.invalidConfiguration("The UTM package refers to a file outside itself.")
            }
            try FileCloner.clone(dataDir.appendingPathComponent(aux), to: bundle.auxiliaryStorageURL)
        } else {
            if let generic = system["GenericPlatform"] as? [String: Any], let identifier = generic["machineIdentifier"] as? Data {
                try identifier.write(to: bundle.genericMachineIdentifierURL)
            }
            if let efi = boot["EfiVariableStoragePath"] as? String, PackageValidator.isContainedName(efi),
               !PackageValidator.isSymbolicLink(dataDir.appendingPathComponent(efi)) {
                try FileCloner.clone(dataDir.appendingPathComponent(efi), to: bundle.efiVariablesURL)
            } else {
                try PlatformProvisioner.provisionGeneric(bundle: bundle)
            }
        }
        if let display = (root["Display"] as? [[String: Any]])?.first {
            config.display.widthPixels = display["WidthPixels"] as? Int ?? config.display.widthPixels
            config.display.heightPixels = display["HeightPixels"] as? Int ?? config.display.heightPixels
            config.display.pixelsPerInch = display["PixelsPerInch"] as? Int ?? config.display.pixelsPerInch
            config.display.dynamicResolution = display["DynamicResolution"] as? Bool ?? true
        }
        let virtualization = root["Virtualization"] as? [String: Any] ?? [:]
        config.audioOutput = virtualization["Audio"] as? Bool ?? true
        config.audioInput = virtualization["AudioInput"] as? Bool ?? false
        config.rosetta = virtualization["Rosetta"] as? Bool ?? false
        config.clipboardSharing = virtualization["ClipboardSharing"] as? Bool ?? false
    }
}
