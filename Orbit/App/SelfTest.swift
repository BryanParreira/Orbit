#if DEBUG
import SwiftUI

/// End-to-end smoke test of the real pipeline, run with `-OrbitSelfTest YES`.
/// Writes progress to /tmp/orbit-selftest.log.
///
/// It opens a display window, which takes keyboard focus: do not type while it runs,
/// or the keystrokes go to the guest. Delete the "SelfTest" VMs afterwards.
@MainActor
enum SelfTest {
    private static let logURL = URL(fileURLWithPath: "/tmp/orbit-selftest.log")

    static func runIfRequested(library: VMLibrary, openWindow: OpenWindowAction) {
        if let name = UserDefaults.standard.string(forKey: "OrbitStartVM"), let vm = library.vms.first(where: { $0.config.name == name }) {
            AppRouter.shared.selection = vm.id
            Task { await VMActions.startAndShow(vm, openWindow: openWindow) }
        }
        if let name = UserDefaults.standard.string(forKey: "OrbitShowInspector"), let vm = library.vms.first(where: { $0.config.name == name }) {
            AppRouter.shared.selection = vm.id
            AppRouter.shared.isShowingInspector = true
        }
        if let template = UserDefaults.standard.string(forKey: "OrbitShowWizard") {
            AppRouter.shared.pendingTemplateID = template.isEmpty || template == "choose" ? nil : template
            AppRouter.shared.isShowingWizard = true
        }
        guard let mode = UserDefaults.standard.string(forKey: "OrbitSelfTest") else { return }
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        let file = UserDefaults.standard.string(forKey: "OrbitSelfTestFile").map(URL.init(fileURLWithPath:))
        Task {
            switch mode {
            case "disk": await runDiskImport(file, library: library, openWindow: openWindow)
            case "qemu": await runQEMU(file, library: library)
            case "demo": await runDemo(file, library: library, openWindow: openWindow)
            default: await run(library: library, openWindow: openWindow)
            }
        }
    }

    private static func log(_ message: String) {
        let line = "[\(Date.now.formatted(date: .omitted, time: .standard))] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }
    }

    private static func waitFor(_ what: String, timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                log("TIMEOUT waiting for \(what)")
                return false
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return true
    }

    /// Boot a disk made by another tool: dropped file → wizard draft → conversion → boot.
    private static func runDiskImport(_ file: URL?, library: VMLibrary, openWindow: OpenWindowAction) async {
        guard let file else { log("FAIL no -OrbitSelfTestFile"); return }
        do {
            log("inspect: \(FileInspector.inspect(file))")
            var draft = try NewVMWizard.draft(for: file, library: library)
            draft.memoryMiB = 1024
            draft.cpuCount = 2
            log("draft template=\(draft.template.id) engine=\(draft.engine) disk=\(draft.existingDiskFormat.map { "\($0)" } ?? "-") valid=\(draft.isValid)")
            let vm = try await VMCreator.create(draft, in: library)
            AppRouter.shared.selection = vm.id
            var last = ""
            let ok = await waitFor("running", timeout: 300) {
                if let s = vm.installStatus, s != last { last = s; log("status: \(s)") }
                return vm.state == .running || vm.lastError != nil
            }
            if let error = vm.lastError { log("FAIL \(error)"); return }
            guard ok else { return }
            log("PASS running from imported disk \(vm.config.primaryDisk?.path ?? "-") (\(vm.config.primaryDisk?.sizeGiB ?? 0) GB)")
            openWindow(id: SceneID.display, value: vm.id)
            try? await Task.sleep(for: .seconds(15))
            await vm.captureScreenshot()
            log("screenshot: \(vm.screenshot != nil)")
            await vm.forceStop()
            log("stopped: \(vm.state.label)")
        } catch {
            log("FAIL \(error.localizedDescription)")
        }
        log("DONE")
    }

    /// Showcase library for README screenshots: a running Alpine VM plus idle Ubuntu and Windows.
    private static func runDemo(_ iso: URL?, library: VMLibrary, openWindow: OpenWindowAction) async {
        guard let iso else { log("FAIL no -OrbitSelfTestFile"); return }
        do {
            for id in ["ubuntu", "windows-arm"] {
                guard let template = OSTemplate.template(id: id) else { continue }
                var draft = VMDraft(template: template, name: template.id == "ubuntu" ? "Ubuntu Desktop" : "Windows 11")
                draft.installer = .none
                draft.startWhenReady = false
                _ = try await VMCreator.create(draft, in: library)
            }
            var draft = VMDraft(template: OSTemplate.template(id: "alpine")!, name: "Alpine Linux")
            draft.installer = .local(iso)
            draft.memoryMiB = 2048
            let vm = try await VMCreator.create(draft, in: library)
            vm.config.notes = "Build box for CI experiments. Mount the shared folder with: mount -t virtiofs share /mnt"
            AppRouter.shared.selection = vm.id
            _ = await waitFor("running", timeout: 120) { vm.state == .running || vm.lastError != nil }
            openWindow(id: SceneID.display, value: vm.id)
            try? await Task.sleep(for: .seconds(14))
            await vm.captureScreenshot()
            await vm.takeSnapshot(named: "Clean install")
            await vm.captureScreenshot()
            log("PASS demo ready, state=\(vm.state.label) error=\(vm.lastError ?? "-")")
            for _ in 0..<6 {
                try? await Task.sleep(for: .seconds(5))
                log("watch: \(vm.state.label)")
            }
        } catch {
            log("FAIL \(error.localizedDescription)")
        }
        log("DONE")
    }

    /// QEMU engine: HVF-accelerated ARM64 guest controlled over QMP, no window.
    private static func runQEMU(_ iso: URL?, library: VMLibrary) async {
        guard let iso else { log("FAIL no -OrbitSelfTestFile"); return }
        guard let template = OSTemplate.template(id: "linux-custom") else { return }
        var draft = VMDraft(template: template, name: "SelfTest QEMU")
        draft.engine = .qemu
        draft.installer = .local(iso)
        draft.memoryMiB = 1024
        draft.cpuCount = 2
        draft.diskGiB = 8
        draft.startWhenReady = false
        do {
            let vm = try await VMCreator.create(draft, in: library)
            _ = await waitFor("ready", timeout: 30) { vm.installStatus == nil }
            vm.config.qemu.extraArguments = ["-display", "none"]
            log("disk=\(vm.config.primaryDisk?.path ?? "-")")
            await vm.start()
            log("start: \(vm.state.label) error=\(vm.lastError ?? "-")")
            guard vm.state == .running else { return }
            try? await Task.sleep(for: .seconds(8))
            log("after 8s: \(vm.state.label)")
            await vm.pause()
            log("pause: \(vm.state.label)")
            await vm.resume()
            log("resume: \(vm.state.label)")
            await vm.forceStop()
            _ = await waitFor("stopped", timeout: 10) { vm.state == .stopped }
            log("stopped: \(vm.state.label) error=\(vm.lastError ?? "-")")
            let log2 = (try? String(contentsOf: vm.bundle.logURL, encoding: .utf8)) ?? ""
            log("qemu log: \(log2.isEmpty ? "(empty)" : log2.prefix(300).description)")
            vm.config.qemu.extraArguments = ["-display", "none", "-not-a-real-flag"]
            vm.lastError = nil
            let t0 = Date()
            await vm.start()
            log("bad start: state=\(vm.state.label) after \(String(format: "%.1f", Date().timeIntervalSince(t0)))s error=\(vm.lastError ?? "-")")
        } catch {
            log("FAIL \(error.localizedDescription)")
        }
        log("DONE")
    }

    private static func run(library: VMLibrary, openWindow: OpenWindowAction) async {
        guard let template = OSTemplate.template(id: "alpine") else { return }
        var draft = VMDraft(template: template, name: "SelfTest Alpine")
        draft.memoryMiB = 1024
        draft.cpuCount = 2
        draft.diskGiB = 8
        log("creating")
        let vm: VMInstance
        do {
            vm = try await VMCreator.create(draft, in: library)
        } catch {
            log("FAIL create: \(error.localizedDescription)")
            return
        }
        log("bundle \(vm.bundle.url.path) disk=\(vm.config.primaryDisk?.path ?? "-")")
        AppRouter.shared.selection = vm.id
        var lastStatus = ""
        let started = await waitFor("running", timeout: 600) {
            if let s = vm.installStatus, s != lastStatus {
                lastStatus = s
                log("status: \(s)")
            }
            return vm.state == .running || vm.lastError != nil
        }
        if let error = vm.lastError { log("FAIL start: \(error)"); return }
        guard started else { return }
        log("PASS running, installer=\(vm.config.installerMedia?.path ?? "none")")
        openWindow(id: SceneID.display, value: vm.id)
        try? await Task.sleep(for: .seconds(20))
        await vm.captureScreenshot()
        log("screenshot: \(vm.screenshot.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "none"), canSuspend=\(vm.canSuspend)")

        if vm.canSuspend {
            await vm.suspend()
            log("after suspend: state=\(vm.state.label) savedState=\(vm.hasSavedState) error=\(vm.lastError ?? "-")")
            await vm.takeSnapshot(named: "suspended")
            log("snapshots=\(vm.snapshots.count) withMemory=\(vm.snapshots.first?.includesMemory ?? false)")
            let t0 = Date()
            await vm.start()
            log("resume took \(String(format: "%.2f", Date().timeIntervalSince(t0)))s state=\(vm.state.label) savedState=\(vm.hasSavedState) error=\(vm.lastError ?? "-")")
            openWindow(id: SceneID.display, value: vm.id)
            try? await Task.sleep(for: .seconds(5))
        } else {
            log("suspend unsupported: \(vm.appleBackend?.suspendUnsupportedReason ?? "?")")
        }
        await vm.pause()
        log("pause: \(vm.state.label)")
        await vm.resume()
        log("resume: \(vm.state.label)")
        await vm.forceStop()
        log("stopped: \(vm.state.label) error=\(vm.lastError ?? "-")")

        do {
            let copy = try await library.duplicate(vm)
            log("duplicate ok: \(copy.bundle.url.lastPathComponent)")
            await copy.start(options: .disposable)
            log("disposable run: \(copy.state.label) error=\(copy.lastError ?? "-")")
            try? await Task.sleep(for: .seconds(3))
            func overlays() -> Int {
                ((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []).filter { $0.hasPrefix("orbit-disposable-") }.count
            }
            log("overlays before restart: \(overlays())")
            await copy.restart()
            log("after restart: \(copy.state.label) disposable=\(copy.isDisposableRun) overlays=\(overlays()) error=\(copy.lastError ?? "-")")
            await vm.restart()
            log("restart of stopped vm is a no-op: \(vm.state.label)")
            await copy.forceStop()
            log("disposable stopped, overlays left=\(overlays())")
        } catch {
            log("FAIL duplicate: \(error.localizedDescription)")
        }
        log("DONE")
    }
}
#endif
