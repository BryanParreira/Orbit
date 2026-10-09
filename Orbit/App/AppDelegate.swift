import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppUpdater.shared.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // VMs keep running from the menu bar
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // settings edits are saved after a short debounce; flush any still pending
        MainActor.assumeIsolated { VMLibrary.shared.vms.forEach { $0.saveNow() } }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls {
                await LibraryDropHandler.handle(url, library: .shared)
            }
        }
    }

    /// Suspend (or shut down) running guests before quitting so nothing is lost.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let (running, busy) = MainActor.assumeIsolated {
            (VMLibrary.shared.vms.filter { $0.state.isActive },
             VMLibrary.shared.vms.filter { $0.installStatus != nil && !$0.state.isActive })
        }
        guard !running.isEmpty || !busy.isEmpty else { return .terminateNow }

        // macOS shutting down, restarting or logging out: never block it with a question
        if !Self.isSystemQuit {
            let suspendable = MainActor.assumeIsolated { running.filter { $0.config.suspendOnQuit && $0.canSuspend } }
            let alert = NSAlert()
            if running.isEmpty {
                alert.messageText = busy.count == 1 ? "“\(MainActor.assumeIsolated { busy[0].config.name })” is still being set up." : "Machines are still being set up."
                alert.informativeText = "Quitting cancels the download or installation. You can start it again later."
                alert.addButton(withTitle: "Quit")
            } else {
                alert.messageText = running.count == 1 ? "“\(MainActor.assumeIsolated { running[0].config.name })” is running." : "\(running.count) virtual machines are running."
                var info = suspendable.count == running.count
                    ? "Orbit will save their state and resume them exactly where they left off next time."
                    : "Machines that support it will be suspended; the rest will be asked to shut down."
                if !busy.isEmpty { info += " Downloads and installations in progress are cancelled." }
                alert.informativeText = info
                alert.addButton(withTitle: suspendable.count == running.count ? "Suspend and Quit" : "Stop and Quit")
            }
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }

        Task { @MainActor in
            busy.forEach { $0.cancelInstallation() }
            await withTaskGroup(of: Void.self) { group in
                for vm in running {
                    group.addTask { await vm.stopForQuit() }
                }
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// True when the quit comes from macOS shutting down, restarting or logging out.
    private static var isSystemQuit: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication,
              let reason = event.attributeDescriptor(forKeyword: kAEQuitReason)?.typeCodeValue else { return false }
        let systemReasons: [OSType] = [OSType(kAEShutDown), OSType(kAERestart), OSType(kAEReallyLogOut), OSType(kAELogOut)]
        return systemReasons.contains(reason)
    }
}
