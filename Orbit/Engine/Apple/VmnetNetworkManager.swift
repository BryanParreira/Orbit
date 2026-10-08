//
// Adapted from UTM (https://github.com/utmapp/UTM), Services/UTMAppleVmnetNetworkManager.swift
// Copyright © 2025 osy. Licensed under the Apache License, Version 2.0.
// Modifications Copyright © 2026 Orbit.
//

import Foundation
import Virtualization
import vmnet

/// Shares one vmnet network per mode between all running VMs so guests can see each other.
@MainActor
final class VmnetNetworkManager {
    static let shared = VmnetNetworkManager()

    private struct Entry {
        weak var attachment: VZVmnetNetworkDeviceAttachment?
    }

    private var entries: [UInt32: Entry] = [:]

    func attachment(for mode: vmnet_mode_t) throws -> VZVmnetNetworkDeviceAttachment {
        if let attachment = entries[mode.rawValue]?.attachment {
            return attachment
        }
        let network = try createNetwork(mode: mode)
        defer { Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(network)).release() }
        let attachment = VZVmnetNetworkDeviceAttachment(network: network)
        entries[mode.rawValue] = Entry(attachment: attachment)
        return attachment
    }

    /// A fixed subnet outside the ranges NAT and QEMU draw from keeps guest addresses stable.
    private func preferredSubnet(for mode: vmnet_mode_t) -> in_addr? {
        switch mode {
        case .VMNET_SHARED_MODE: in_addr(s_addr: inet_addr("192.168.96.1"))
        case .VMNET_HOST_MODE: in_addr(s_addr: inet_addr("192.168.160.1"))
        default: nil
        }
    }

    private func createNetwork(mode: vmnet_mode_t) throws -> vmnet_network_ref {
        if let subnet = preferredSubnet(for: mode), let network = try? createNetwork(mode: mode, subnet: subnet) {
            return network
        }
        return try createNetwork(mode: mode, subnet: nil)
    }

    private func createNetwork(mode: vmnet_mode_t, subnet: in_addr?) throws -> vmnet_network_ref {
        var status = vmnet_return_t.VMNET_SUCCESS
        guard let configuration = vmnet_network_configuration_create(mode, &status) else {
            throw VMError.invalidConfiguration("Could not create the virtual network (vmnet error \(status.rawValue)).")
        }
        defer { Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(configuration)).release() }
        if var subnet {
            var mask = in_addr(s_addr: inet_addr("255.255.255.0"))
            status = vmnet_network_configuration_set_ipv4_subnet(configuration, &subnet, &mask)
            guard status == .VMNET_SUCCESS else {
                throw VMError.invalidConfiguration("Could not configure the virtual network (vmnet error \(status.rawValue)).")
            }
        }
        guard let network = vmnet_network_create(configuration, &status) else {
            throw VMError.invalidConfiguration("Could not create the virtual network (vmnet error \(status.rawValue)).")
        }
        return network
    }
}
