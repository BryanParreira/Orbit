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
            Task {
                await VMActions.startAndShow(vm, openWindow: openWindow)
                if UserDefaults.standard.bool(forKey: "OrbitShowGallery") { AppRouter.shared.selection = AppRouter.galleryID }
            }
        }
        if let name = UserDefaults.standard.string(forKey: "OrbitShowDelete"), let vm = library.vms.first(where: { $0.config.name == name }) {
            AppRouter.shared.selection = vm.id
            AppRouter.shared.deleting = vm
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
            case "boot": await runBootTests(library: library, openWindow: openWindow)
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

    /// Every system the way a user gets it: resolve the newest release, download, verify, create
    /// the machine in a chosen folder, boot it, and save screenshots of the guest.
    ///
    /// `-OrbitBootTemplates "alpine,debian,emulated=/path/x86.iso"` (an `=path` uses that file
    /// instead of downloading), `-OrbitBootDir /Volumes/Drive/OrbitBootTest` (holds `isos/`,
    /// `machines/` and `shots/`). Run the app in the background (`open -g`): if Orbit becomes the
    /// active app while a guest runs, the run stops so no keystroke can reach a test guest.
    private static func runBootTests(library: VMLibrary, openWindow: OpenWindowAction) async {
        let defaults = UserDefaults.standard
        guard let dir = defaults.string(forKey: "OrbitBootDir").map({ URL(fileURLWithPath: $0, isDirectory: true) }) else {
            log("FAIL no -OrbitBootDir"); return
        }
        let isos = dir.appendingPathComponent("isos"), machines = dir.appendingPathComponent("machines"), shots = dir.appendingPathComponent("shots")
        for folder in [isos, machines, shots] { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let seconds = defaults.integer(forKey: "OrbitBootSeconds") > 0 ? defaults.integer(forKey: "OrbitBootSeconds") : 90
        let entries = (defaults.string(forKey: "OrbitBootTemplates") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var results: [String] = []
        for entry in entries where !entry.isEmpty {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            let id = parts[0]
            guard let template = OSTemplate.template(id: id) else { log("FAIL \(id): unknown template"); continue }
            log("== \(template.name)")
            let result = await bootTest(template, file: parts.count > 1 ? URL(fileURLWithPath: parts[1]) : nil,
                                        isos: isos, machines: machines, shots: shots, seconds: seconds, library: library, openWindow: openWindow)
            log("\(result.hasPrefix("PASS") ? "PASS" : "FAIL") \(template.name): \(result)")
            results.append("\(template.name): \(result)")
            if NSApp.isActive && !UserDefaults.standard.bool(forKey: "OrbitBootIgnoreFocus") { log("STOP Orbit became the active app"); break }
        }
        log("SUMMARY\n" + results.joined(separator: "\n"))
        log("DONE")
    }

    private static func bootTest(_ template: OSTemplate, file: URL?, isos: URL, machines: URL, shots: URL, seconds: Int,
                                 library: VMLibrary, openWindow: OpenWindowAction) async -> String {
        var vm: VMInstance?
        defer {
            if let vm { Task { @MainActor in try? await library.delete(vm, permanently: true, removeInstaller: false) } }
        }
        do {
            // 1. installer, as a user would get it
            let installer: URL
            if let file {
                installer = file
            } else if case .resolver(let resolver) = template.source {
                let resolved = try await resolver.resolve()
                log("resolved \(resolved.version): \(resolved.url.absoluteString)")
                let task = DownloadTask(source: resolved.url, destination: isos.appendingPathComponent(resolved.url.lastPathComponent))
                let progress = Task { @MainActor in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(30))
                        log("download \(Int(task.fraction * 100))%")
                    }
                }
                defer { progress.cancel() }
                installer = try await task.run()
                if let checksum = resolved.checksumURL {
                    try await ChecksumVerifier.verify(installer, against: checksum)
                    log("checksum verified")
                } else {
                    return "no checksum published"
                }
            } else if template.source == .macOSRestoreImage {
                let latest = try await PlatformProvisioner.latestRestoreImage()
                log("resolved macOS \(latest.version): \(latest.url.absoluteString)")
                let task = DownloadTask(source: latest.url, destination: isos.appendingPathComponent(latest.url.lastPathComponent))
                installer = try await task.run()
            } else {
                return "needs a file (\(template.id)=/path)"
            }

            // 2. create it in the chosen folder and boot
            var draft = VMDraft(template: template, name: "SelfTest \(template.name)")
            draft.installer = .local(installer)
            draft.location = UserDefaults.standard.bool(forKey: "OrbitBootNoLocation") ? nil : machines
            draft.memoryMiB = min(draft.memoryMiB, 4096)
            draft.cpuCount = min(4, HostInfo.maxCPUs)
            // "-OrbitBootForward 2222:22" forwards Mac port 2222 to the guest's port 22
            let forward = UserDefaults.standard.string(forKey: "OrbitBootForward")?.split(separator: ":").compactMap { Int($0) }
            draft.startWhenReady = forward == nil
            guard draft.isValid else { return "draft invalid" }
            let machine = try await VMCreator.create(draft, in: library)
            vm = machine
            if let forward, forward.count == 2 {
                _ = await waitFor("created", timeout: 300) { machine.installStatus == nil }
                machine.config.network.portForwards = [PortForward(hostPort: forward[0], guestPort: forward[1])]
                machine.saveNow()
                await machine.start()
                log("FORWARD Mac port \(forward[0]) → guest port \(forward[1])")
            }
            var last = ""
            let timeout: Double = template.guestOS == .macOS ? 3600 : 300
            _ = await waitFor("running", timeout: timeout) {
                if let s = machine.installStatus, s != last { last = s; log("status: \(s)") }
                return (machine.state == .running && machine.installStatus == nil) || machine.lastError != nil
            }
            if let error = machine.lastError { return "error: \(error)" }
            guard machine.state == .running else { return "not running: \(machine.state.label)" }
            if machine.hasEmbeddedDisplay { openWindow(id: SceneID.display, value: machine.id) }

            // 3. let it boot, watching that nothing goes wrong and that no keystroke could reach it
            let started = Date()
            var captured = 0
            while Date().timeIntervalSince(started) < Double(seconds) {
                try? await Task.sleep(for: .seconds(1))
                if NSApp.isActive && !UserDefaults.standard.bool(forKey: "OrbitBootIgnoreFocus") {
                    await machine.forceStop(); return "stopped: Orbit became the active app"
                }
                if machine.state != .running { return "guest stopped by itself after \(Int(Date().timeIntervalSince(started))) s: \(machine.lastError ?? machine.state.label)" }
                if let error = machine.lastError { return "error while running: \(error)" }
                let elapsed = Int(Date().timeIntervalSince(started))
                if let control = UserDefaults.standard.string(forKey: "OrbitAppleControlDir"), machine.config.engine == .apple {
                    await driveAppleGuest(machine, control: URL(fileURLWithPath: control, isDirectory: true), tick: elapsed)
                }
                if elapsed >= (captured + 1) * (seconds / 3) {
                    captured += 1
                    await saveScreenshot(machine, to: shots.appendingPathComponent("\(template.id)-\(elapsed)s.png"))
                }
            }
            let summary = "running \(seconds) s, \(captured) screenshots"
            await machine.forceStop()
            return "PASS " + summary
        } catch {
            let ns = error as NSError
            return "error: \(ErrorMessages.message(for: error) ?? error.localizedDescription) [\(ns.domain) \(ns.code)]"
        }
    }

    /// Apple-engine guests have no QMP: type into the display view the way real key presses
    /// arrive. Same folder protocol as QEMU's (`keys.txt` in, `screen.png` out).
    private static func driveAppleGuest(_ vm: VMInstance, control: URL, tick: Int) async {
        try? FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        guard let view = vm.appleBackend?.displayView, let window = view.window else { return }
        let keys = control.appendingPathComponent("keys.txt")
        if let text = try? String(contentsOf: keys, encoding: .utf8) {
            try? FileManager.default.removeItem(at: keys)
            for line in text.split(whereSeparator: \.isNewline).map(String.init) {
                for (code, chars, shift) in macKeys(line) {
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: shift ? .shift : [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                        context: nil, characters: chars, charactersIgnoringModifiers: chars.lowercased(),
                                                        isARepeat: false, keyCode: code) {
                            if type == .keyDown { view.keyDown(with: event) } else { view.keyUp(with: event) }
                        }
                        try? await Task.sleep(for: .milliseconds(40))
                    }
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        if tick % 5 == 0 {
            await vm.captureScreenshot()
            try? FileManager.default.removeItem(at: control.appendingPathComponent("screen.png"))
            try? FileManager.default.copyItem(at: vm.bundle.screenshotURL, to: control.appendingPathComponent("screen.png"))
        }
    }

    /// macOS virtual key codes: "ret", "tab", "spc", "esc", "up"/"down"/"left"/"right", "bksp",
    /// or "text:..." for letters, digits, space, "-", "." and "/".
    private static func macKeys(_ line: String) -> [(UInt16, String, Bool)] {
        let named: [String: (UInt16, String)] = ["ret": (36, "\r"), "tab": (48, "\t"), "spc": (49, " "), "esc": (53, "\u{1b}"),
                                                 "bksp": (51, "\u{7f}"), "left": (123, ""), "right": (124, ""), "down": (125, ""), "up": (126, "")]
        if let key = named[line] { return [(key.0, key.1, false)] }
        guard line.hasPrefix("text:") else { return [] }
        let letters: [Character: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
                                            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
                                            "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
                                            "j": 38, "k": 40, "n": 45, "m": 46, ".": 47, "/": 44, " ": 49]
        return line.dropFirst(5).compactMap { c in
            letters[Character(c.lowercased())].map { ($0, String(c), c.isUppercase) }
        }
    }

    private static func saveScreenshot(_ vm: VMInstance, to url: URL) async {
        if let qemu = vm.backend as? QEMUBackend {
            do { try await qemu.screendump(to: url) } catch { log("screendump failed: \(error.localizedDescription)") }
            return
        }
        await vm.captureScreenshot()
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.copyItem(at: vm.bundle.screenshotURL, to: url)
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
