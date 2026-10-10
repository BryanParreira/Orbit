import AppKit
import SwiftUI
import Testing
@testable import Orbit

/// Every template the wizard offers has setup steps, and they name the right disk.
@MainActor
struct InstallGuideTests {
    @Test(arguments: OSTemplate.all.map(\.id).filter { $0 != "macos" && $0 != "emulated" })
    func everySystemHasSteps(_ id: String) throws {
        var config = VMConfiguration(name: id, engine: .apple, guestOS: .linux, cpuCount: 2, memoryMiB: 2048)
        config.templateID = id
        config.disks = [DiskConfiguration(path: "disk.img", sizeGiB: 64),
                        DiskConfiguration(path: "/tmp/installer.iso", sizeGiB: 0, isReadOnly: true, interface: .usb, isRemovable: true)]
        let guide = try #require(InstallGuide.guide(for: config))
        #expect(guide.steps.count >= 3)
        #expect(guide.steps.contains { ($0.detail ?? "").contains("64 GB virtual disk") }, "says which disk is the machine's")
    }

    /// Renders the guide to a PNG when ORBIT_SNAPSHOT_DIR is set, for a visual check.
    @Test func rendersForReview() throws {
        guard let dir = ProcessInfo.processInfo.environment["ORBIT_SNAPSHOT_DIR"] else { return }
        var config = VMConfiguration(name: "Kali", engine: .apple, guestOS: .linux, cpuCount: 2, memoryMiB: 2048)
        config.templateID = "kali"
        config.disks = [DiskConfiguration(path: "disk.img", sizeGiB: 64)]
        let guide = try #require(InstallGuide.guide(for: config))
        let view = InstallGuideView(name: "Kali Linux", guide: guide)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("install-guide.png"))
    }
}
