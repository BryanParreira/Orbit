//
// Adapted from UTM (https://github.com/utmapp/UTM), Configuration/UTMAppleConfiguration*.swift
// Copyright © 2021 osy. Licensed under the Apache License, Version 2.0.
// Modifications Copyright © 2026 Orbit.
//

import Foundation
import Virtualization

/// Translates an Orbit `VMConfiguration` into a `VZVirtualMachineConfiguration`.
@MainActor
struct AppleConfigurationBuilder {
    let config: VMConfiguration
    let bundle: VMBundle
    /// Disposable runs: state files are looked up here (APFS clones) instead of in the bundle.
    var overlayDirectory: URL?

    /// Set during `build()` when clipboard sharing is wired up.
    private(set) var spiceAgent: VZSpiceAgentPortAttachment?

    init(config: VMConfiguration, bundle: VMBundle, overlayDirectory: URL? = nil) {
        self.config = config
        self.bundle = bundle
        self.overlayDirectory = overlayDirectory
    }

    private func resolve(_ url: URL) -> URL {
        guard let overlayDirectory else { return url }
        let candidate = overlayDirectory.appendingPathComponent(url.lastPathComponent)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : url
    }

    mutating func build() throws -> VZVirtualMachineConfiguration {
        let vz = VZVirtualMachineConfiguration()
        let isMac = config.guestOS == .macOS

        vz.cpuCount = min(max(config.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount), VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        let memory = UInt64(config.memoryMiB) * 1_048_576
        vz.memorySize = min(max(memory, VZVirtualMachineConfiguration.minimumAllowedMemorySize), VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        // Platform + boot
        if isMac {
            vz.platform = try macPlatform()
            vz.bootLoader = VZMacOSBootLoader()
        } else {
            vz.platform = try genericPlatform()
            let efi = VZEFIBootLoader()
            let varsURL = resolve(bundle.efiVariablesURL)
            guard FileManager.default.fileExists(atPath: varsURL.path) else {
                throw VMError.missingFile("EFIVariables")
            }
            efi.variableStore = VZEFIVariableStore(url: varsURL)
            vz.bootLoader = efi
        }

        vz.storageDevices = try storageDevices()
        vz.networkDevices = try networkDevices()

        // Display
        if isMac {
            let graphics = VZMacGraphicsDeviceConfiguration()
            graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: config.display.widthPixels,
                                                                   heightInPixels: config.display.heightPixels,
                                                                   pixelsPerInch: config.display.pixelsPerInch)]
            vz.graphicsDevices = [graphics]
            vz.keyboards = [VZMacKeyboardConfiguration()]
            // trackpad gives native gestures; USB pointer is the fallback for older guests
            vz.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
        } else {
            let graphics = VZVirtioGraphicsDeviceConfiguration()
            graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: config.display.widthPixels,
                                                                      heightInPixels: config.display.heightPixels)]
            vz.graphicsDevices = [graphics]
            vz.keyboards = [VZUSBKeyboardConfiguration()]
            vz.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        }

        // Audio
        if config.audioOutput || config.audioInput {
            let sound = VZVirtioSoundDeviceConfiguration()
            if config.audioOutput {
                let output = VZVirtioSoundDeviceOutputStreamConfiguration()
                output.sink = VZHostAudioOutputStreamSink()
                sound.streams.append(output)
            }
            if config.audioInput {
                let input = VZVirtioSoundDeviceInputStreamConfiguration()
                input.source = VZHostAudioInputStreamSource()
                sound.streams.append(input)
            }
            vz.audioDevices = [sound]
        }

        vz.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        vz.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        vz.directorySharingDevices = try directorySharingDevices()

        // Clipboard via SPICE agent (Linux guests running spice-vdagent)
        if !isMac && config.clipboardSharing {
            let agent = VZSpiceAgentPortAttachment()
            agent.sharesClipboard = true
            let port = VZVirtioConsolePortConfiguration()
            port.name = VZSpiceAgentPortAttachment.spiceAgentPortName
            port.attachment = agent
            let console = VZVirtioConsoleDeviceConfiguration()
            console.ports[0] = port
            vz.consoleDevices = [console]
            spiceAgent = agent
        }

        vz.usbControllers = [VZXHCIControllerConfiguration()]

        if #available(macOS 27, *) {
            // names the VM in system prompts such as USB device access
            vz.label = String(config.name.prefix(64))
        }
        return vz
    }

    // MARK: - Platform

    private func macPlatform() throws -> VZMacPlatformConfiguration {
        #if arch(arm64)
        let platform = VZMacPlatformConfiguration()
        guard let modelData = try? Data(contentsOf: bundle.hardwareModelURL),
              let model = VZMacHardwareModel(dataRepresentation: modelData) else {
            throw VMError.missingFile("HardwareModel")
        }
        guard model.isSupported else {
            throw VMError.invalidConfiguration("This Mac cannot run the macOS version this virtual machine was created for.")
        }
        guard let idData = try? Data(contentsOf: bundle.machineIdentifierURL),
              let identifier = VZMacMachineIdentifier(dataRepresentation: idData) else {
            throw VMError.missingFile("MachineIdentifier")
        }
        platform.hardwareModel = model
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: resolve(bundle.auxiliaryStorageURL))
        return platform
        #else
        throw VMError.unsupported("macOS guests on Intel Macs")
        #endif
    }

    private func genericPlatform() throws -> VZGenericPlatformConfiguration {
        let platform = VZGenericPlatformConfiguration()
        if let data = try? Data(contentsOf: bundle.genericMachineIdentifierURL),
           let identifier = VZGenericMachineIdentifier(dataRepresentation: data) {
            platform.machineIdentifier = identifier
        }
        if config.nestedVirtualization && VZGenericPlatformConfiguration.isNestedVirtualizationSupported {
            platform.isNestedVirtualizationEnabled = true
        }
        return platform
    }

    // MARK: - Storage

    private func storageDevices() throws -> [VZStorageDeviceConfiguration] {
        // UTM: cached mode prevents filesystem corruption seen with Linux on virtio-blk
        let isLinux = config.guestOS == .linux
        let sync: VZDiskImageSynchronizationMode = switch config.diskPerformance {
        case .safe: .full
        case .balanced: .fsync
        case .fast: .none
        }
        var devices: [VZStorageDeviceConfiguration] = []
        for disk in config.disks {
            let url = disk.isRemovable ? bundle.diskURL(for: disk) : resolve(bundle.diskURL(for: disk))
            guard FileManager.default.fileExists(atPath: url.path) else {
                if disk.isRemovable { continue } // ejected or moved installer: just boot without it
                throw VMError.missingFile(url.lastPathComponent)
            }
            if disk.isRemovable {
                let attachment = try VZDiskImageStorageDeviceAttachment(url: url, readOnly: true)
                devices.append(VZUSBMassStorageDeviceConfiguration(attachment: attachment))
                continue
            }
            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: url,
                readOnly: disk.isReadOnly,
                cachingMode: isLinux && disk.interface == .virtio ? .cached : .automatic,
                synchronizationMode: sync)
            switch disk.interface {
            case .nvme where config.guestOS != .macOS:
                devices.append(VZNVMExpressControllerDeviceConfiguration(attachment: attachment))
            case .usb:
                devices.append(VZUSBMassStorageDeviceConfiguration(attachment: attachment))
            default:
                let block = VZVirtioBlockDeviceConfiguration(attachment: attachment)
                let serial = "orbit-\(disk.id.uuidString.prefix(8))"
                if (try? VZVirtioBlockDeviceConfiguration.validateBlockDeviceIdentifier(serial)) != nil {
                    block.blockDeviceIdentifier = serial
                }
                devices.append(block)
            }
        }
        return devices
    }

    // MARK: - Network

    private func networkDevices() throws -> [VZNetworkDeviceConfiguration] {
        let network = config.network
        let device = VZVirtioNetworkDeviceConfiguration()
        if let mac = VZMACAddress(string: network.macAddress) {
            device.macAddress = mac
        }
        switch network.mode {
        case .none:
            return []
        case .nat:
            device.attachment = VZNATNetworkDeviceAttachment()
        case .bridged:
            let interfaces = VZBridgedNetworkInterface.networkInterfaces
            guard let interface = interfaces.first(where: { $0.identifier == network.bridgeInterface }) ?? interfaces.first else {
                throw VMError.invalidConfiguration("No network interface is available for bridging.")
            }
            device.attachment = VZBridgedNetworkDeviceAttachment(interface: interface)
        case .hostOnly:
            device.attachment = try VmnetNetworkManager.shared.attachment(for: .VMNET_HOST_MODE)
        }
        return [device]
    }

    // MARK: - Sharing

    private func directorySharingDevices() throws -> [VZDirectorySharingDeviceConfiguration] {
        var devices: [VZDirectorySharingDeviceConfiguration] = []
        // always present (possibly empty) so folders can be added while the guest runs
        let folders = config.sharedFolders.filter { FileManager.default.fileExists(atPath: $0.path) }
        let fs = VZVirtioFileSystemDeviceConfiguration(tag: Self.shareTag(for: config.guestOS))
        fs.share = Self.directoryShare(for: folders)
        devices.append(fs)
        if config.guestOS == .linux && config.rosetta && VZLinuxRosettaDirectoryShare.availability == .installed {
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
            fs.share = try VZLinuxRosettaDirectoryShare()
            devices.append(fs)
        }
        return devices
    }

    static func shareTag(for os: GuestOS) -> String {
        os == .macOS ? VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag : "share"
    }

    static func directoryShare(for folders: [SharedFolder]) -> VZDirectoryShare {
        var directories: [String: VZSharedDirectory] = [:]
        for folder in folders {
            var name = folder.name
            var suffix = 2
            while directories[name] != nil {
                name = "\(folder.name)-\(suffix)"
                suffix += 1
            }
            directories[name] = VZSharedDirectory(url: URL(fileURLWithPath: folder.path), readOnly: folder.isReadOnly)
        }
        return VZMultipleDirectoryShare(directories: directories)
    }
}
