import AccessoryAccess
import Foundation
import IOKit
import Observation
import Security
import Virtualization

/// A USB device plugged into this Mac that a machine can take over.
struct HostUSBDevice: Identifiable, Hashable {
    /// The device's IORegistry entry, stable while it stays plugged in.
    let id: UInt64
    let name: String
    let vendorID: Int
    let productID: Int
}

/// Hands USB devices plugged into the Mac to running machines (Apple engine, macOS 27 and later).
///
/// A device given to a machine works there as if plugged into it (flash drives, serial adapters,
/// security keys, Bluetooth dongles…) and is unavailable to macOS until the machine lets it go,
/// shuts down, or the device is unplugged. macOS asks the user before Orbit can use a device.
///
/// Needs the `com.apple.developer.accessory-access.usb` entitlement; without it the feature stays
/// hidden and nothing here runs.
@available(macOS 27, *)
@Observable
@MainActor
final class USBPassthrough: NSObject {
    static let shared = USBPassthrough()

    static let entitlement = "com.apple.developer.accessory-access.usb"

    /// Whether this copy of Orbit is signed with the USB entitlement.
    nonisolated static let isAvailable: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return (SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) as? Bool) == true
    }()

    private(set) var devices: [HostUSBDevice] = []
    /// Which machine each device is attached to.
    private(set) var owners: [UInt64: UUID] = [:]
    private(set) var lastError: String?

    @ObservationIgnored private var accessories: [UInt64: AAUSBAccessory] = [:]
    @ObservationIgnored private var attached: [UInt64: VZUSBPassthroughDevice] = [:]
    @ObservationIgnored private var isListening = false

    /// Start watching for USB devices (once; also lists the ones already plugged in).
    func start() {
        guard Self.isAvailable, !isListening else { return }
        isListening = true
        AAUSBAccessoryManager.shared.registerListener(self, matchingCriteria: []) { [weak self] connected, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.lastError = error.localizedDescription
                    self.isListening = false
                    return
                }
                connected.forEach(self.add)
            }
        }
    }

    func owner(of device: HostUSBDevice) -> UUID? {
        guard let owner = owners[device.id] else { return nil }
        // a machine that stopped has released its devices
        if VMLibrary.shared.vm(with: owner)?.state.isActive != true {
            owners[device.id] = nil
            attached[device.id] = nil
            return nil
        }
        return owner
    }

    /// Give `device` to `vm`. macOS asks the user for permission the first time.
    func attach(_ device: HostUSBDevice, to vm: VMInstance) async throws {
        guard let controller = vm.appleBackend?.virtualMachine?.usbControllers.first, vm.state == .running else {
            throw VMError.invalidConfiguration("Start “\(vm.config.name)” before giving it a USB device.")
        }
        if let owner = owner(of: device), owner != vm.id {
            let name = VMLibrary.shared.vm(with: owner)?.config.name ?? "another machine"
            throw VMError.invalidConfiguration("“\(device.name)” is in use by \(name). Disconnect it there first.")
        }
        guard let accessory = accessories[device.id] else {
            throw VMError.invalidConfiguration("“\(device.name)” is no longer connected.")
        }
        let passthrough = try VZUSBPassthroughDevice(configuration: VZUSBPassthroughDeviceConfiguration(device: accessory))
        controller.delegate = self
        try await controller.attach(device: passthrough)
        attached[device.id] = passthrough
        owners[device.id] = vm.id
    }

    /// Give `device` back to macOS.
    func detach(_ device: HostUSBDevice, from vm: VMInstance) async throws {
        defer {
            attached[device.id] = nil
            owners[device.id] = nil
        }
        guard let passthrough = attached[device.id], let controller = vm.appleBackend?.virtualMachine?.usbControllers.first else { return }
        try await controller.detach(device: passthrough)
    }

    private func add(_ accessory: AAUSBAccessory) {
        let id = accessory.registryID
        accessories[id] = accessory
        let descriptor = [UInt8](accessory.deviceDescriptorData)
        // USB device descriptor: idVendor at byte 8, idProduct at byte 10, little-endian
        let vendor = descriptor.count >= 12 ? Int(descriptor[8]) | Int(descriptor[9]) << 8 : 0
        let product = descriptor.count >= 12 ? Int(descriptor[10]) | Int(descriptor[11]) << 8 : 0
        let name = Self.productName(registryID: id) ?? String(format: "USB device %04x:%04x", vendor, product)
        devices.removeAll { $0.id == id }
        devices.append(HostUSBDevice(id: id, name: name, vendorID: vendor, productID: product))
        devices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func remove(registryID id: UInt64) {
        accessories[id] = nil
        attached[id] = nil
        owners[id] = nil
        devices.removeAll { $0.id == id }
    }

    /// The name the device reports, as System Information shows it.
    private static func productName(registryID: UInt64) -> String? {
        guard let matching = IORegistryEntryIDMatching(registryID) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        for key in ["USB Product Name", "kUSBProductString"] {
            if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
               !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

@available(macOS 27, *)
extension USBPassthrough: AAUSBAccessoryListener {
    nonisolated func usbAccessoryDidConnect(_ usbAccessory: AAUSBAccessory) {
        Task { @MainActor in self.add(usbAccessory) }
    }

    nonisolated func usbAccessoryDidDisconnect(_ usbAccessory: AAUSBAccessory) {
        let id = usbAccessory.registryID
        Task { @MainActor in self.remove(registryID: id) }
    }
}

@available(macOS 27, *)
extension USBPassthrough: VZUSBController.Delegate {
    nonisolated func usbController(_ usbController: VZUSBController, usbPassthroughDeviceDidDisconnect device: VZUSBPassthroughDevice) {
        Task { @MainActor in
            if let id = self.attached.first(where: { $0.value === device })?.key {
                self.attached[id] = nil
                self.owners[id] = nil
            }
        }
    }
}
