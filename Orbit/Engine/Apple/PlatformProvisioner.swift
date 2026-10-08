import Foundation
import Virtualization

/// Creates the per-machine firmware and identity files an Apple-engine VM needs.
@MainActor
enum PlatformProvisioner {
    struct RestoreImageInfo {
        let url: URL
        let version: String
        let build: String
    }

    /// Latest macOS restore image Apple signs for this Mac.
    static func latestRestoreImage() async throws -> RestoreImageInfo {
        let image = try await VZMacOSRestoreImage.latestSupported
        return RestoreImageInfo(url: image.url, version: image.operatingSystemVersion.displayString, build: image.buildVersion)
    }

    /// Write hardware model, machine identifier and auxiliary storage for a macOS guest.
    /// - Returns: minimum CPU count and memory the restore image requires.
    @discardableResult
    static func provisionMac(bundle: VMBundle, ipsw: URL) async throws -> (cpus: Int, memoryMiB: Int) {
        #if arch(arm64)
        let image = try await VZMacOSRestoreImage.image(from: ipsw)
        guard let requirements = image.mostFeaturefulSupportedConfiguration else {
            throw VMError.invalidConfiguration("This restore image (macOS \(image.operatingSystemVersion.displayString)) is not supported on this Mac.")
        }
        guard requirements.hardwareModel.isSupported else {
            throw VMError.invalidConfiguration("This Mac cannot virtualize macOS \(image.operatingSystemVersion.displayString). Try a newer restore image or update macOS.")
        }
        try requirements.hardwareModel.dataRepresentation.write(to: bundle.hardwareModelURL)
        try VZMacMachineIdentifier().dataRepresentation.write(to: bundle.machineIdentifierURL)
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: bundle.auxiliaryStorageURL, hardwareModel: requirements.hardwareModel, options: [.allowOverwrite])
        return (requirements.minimumSupportedCPUCount, Int(requirements.minimumSupportedMemorySize / 1_048_576))
        #else
        throw VMError.unsupported("macOS guests on Intel Macs")
        #endif
    }

    /// Write a machine identifier and blank EFI variable store for a Linux guest.
    static func provisionGeneric(bundle: VMBundle) throws {
        try VZGenericMachineIdentifier().dataRepresentation.write(to: bundle.genericMachineIdentifierURL)
        _ = try VZEFIVariableStore(creatingVariableStoreAt: bundle.efiVariablesURL, options: [.allowOverwrite])
    }

    /// New identity for a duplicated VM so both copies can run side by side.
    static func regenerateIdentity(bundle: VMBundle, guestOS: GuestOS) throws {
        if guestOS == .macOS {
            #if arch(arm64)
            try VZMacMachineIdentifier().dataRepresentation.write(to: bundle.machineIdentifierURL)
            #endif
        } else if FileManager.default.fileExists(atPath: bundle.genericMachineIdentifierURL.path) {
            try VZGenericMachineIdentifier().dataRepresentation.write(to: bundle.genericMachineIdentifierURL)
        }
    }
}

extension OperatingSystemVersion {
    var displayString: String {
        patchVersion == 0 ? "\(majorVersion).\(minorVersion)" : "\(majorVersion).\(minorVersion).\(patchVersion)"
    }
}
