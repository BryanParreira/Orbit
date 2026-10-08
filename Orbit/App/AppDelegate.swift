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

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls {
                await LibraryDropHandler.handle(url, library: .shared)
            }
        }
    }

    /// Suspend (or shut down) running guests before quitting so nothing is lost.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = MainActor.assumeIsolated { VMLibrary.shared.vms.filter { $0.state.isActive } }
        guard !running.isEmpty else { return .terminateNow }

        let suspendable = MainActor.assumeIsolated { running.filter { $0.config.suspendOnQuit && $0.canSuspend } }
        let alert = NSAlert()
        alert.messageText = running.count == 1 ? "“\(MainActor.assumeIsolated { running[0].config.name })” is running." : "\(running.count) virtual machines are running."
        alert.informativeText = suspendable.count == running.count
            ? "Orbit will save their state and resume them exactly where they left off next time."
            : "Machines that support it will be suspended; the rest will be asked to shut down."
        alert.addButton(withTitle: suspendable.count == running.count ? "Suspend and Quit" : "Stop and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for vm in running {
                    group.addTask { await vm.stopForQuit() }
                }
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
