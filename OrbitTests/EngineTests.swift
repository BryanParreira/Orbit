import Foundation
import Testing
@testable import Orbit

struct EngineTests {
    private func bundle() -> VMBundle {
        VMBundle(url: FileManager.default.temporaryDirectory.appendingPathComponent("arg-test.orbitvm"))
    }

    @Test func nativeGuestsUseHVF() {
        var config = VMConfiguration(name: "Win", engine: .qemu, guestOS: .windows, architecture: .arm64, cpuCount: 4, memoryMiB: 8192)
        config.disks = []
        let args = QEMUArgumentBuilder(config: config, bundle: bundle(), qmpSocket: "/tmp/q", dataDirectory: URL(fileURLWithPath: "/share")).build()
        #expect(args.contains("hvf"))
        #expect(args.contains("host"))
        #expect(args.contains("ramfb"))
        #expect(args.contains("virt"))
        #expect(args.contains("unix:/tmp/q,server=on,wait=off"))
    }

    @Test func foreignGuestsUseMultiThreadedTCG() {
        var config = VMConfiguration(name: "PC", engine: .qemu, guestOS: .linux, architecture: .x86_64, cpuCount: 4, memoryMiB: 4096)
        config.qemu.tcgCacheMiB = 1024
        let args = QEMUArgumentBuilder(config: config, bundle: bundle(), qmpSocket: "/tmp/q", dataDirectory: URL(fileURLWithPath: "/share")).build()
        #expect(args.contains("tcg,thread=multi,tb-size=1024"))
        #expect(args.contains("q35"))
        #expect(!args.contains("hvf"))
    }

    @Test func portForwardsAndDiskCacheMapThrough() {
        var config = VMConfiguration(name: "S", engine: .qemu, guestOS: .linux, architecture: .arm64, cpuCount: 2, memoryMiB: 2048)
        config.network.portForwards = [PortForward(hostPort: 2222, guestPort: 22)]
        config.diskPerformance = .fast
        let args = QEMUArgumentBuilder(config: config, bundle: bundle(), qmpSocket: "/tmp/q", dataDirectory: URL(fileURLWithPath: "/share")).build()
        #expect(args.contains { $0.contains("hostfwd=tcp::2222-:22") })
    }

    @Test func configurationDecodesOlderFiles() throws {
        let json = #"{"name":"Old","engine":"apple","guestOS":"linux","cpuCount":2,"memoryMiB":2048}"#
        let config = try JSONDecoder.orbit.decode(VMConfiguration.self, from: Data(json.utf8))
        #expect(config.name == "Old")
        #expect(config.diskPerformance == .balanced)
        #expect(config.disks.isEmpty)
    }

    @Test func everyTemplateHasAMatchingLogo() {
        for template in OSTemplate.all where template.id != "emulated" {
            #expect(template.logo != nil, "\(template.id) has no logo")
        }
    }

    @Test func smartDefaultsStayInsideHostLimits() {
        for os in GuestOS.allCases {
            let memory = HostInfo.recommendedMemoryMiB(for: os)
            #expect(memory <= HostInfo.maxMemoryMiB)
            #expect(memory >= 2048)
        }
        #expect(HostInfo.recommendedCPUs <= HostInfo.maxCPUs)
    }
}
