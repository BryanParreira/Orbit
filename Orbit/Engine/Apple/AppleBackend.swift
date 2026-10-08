//
// Adapted from UTM (https://github.com/utmapp/UTM), Services/UTMAppleVirtualMachine.swift
// Copyright © 2021 osy. Licensed under the Apache License, Version 2.0.
// Modifications Copyright © 2026 Orbit.
//

import Foundation
import ScreenCaptureKit
import Virtualization

/// Runs a guest with Apple's Virtualization.framework.
///
/// The VM runs on the main queue: `VZVirtualMachineView` requires it, and the guest itself
/// executes in Apple's out-of-process XPC service, so the main thread only handles callbacks.
@MainActor
final class AppleBackend: NSObject, VMBackend {
    private let bundle: VMBundle
    private var config: VMConfiguration

    private(set) var virtualMachine: VZVirtualMachine?
    private(set) var state: VMState = .stopped {
        didSet { if oldValue != state { onStateChange?(state, nil) } }
    }
    var onStateChange: ((VMState, Error?) -> Void)?

    /// Why save/restore is unavailable for the current configuration, if it is.
    private(set) var suspendUnsupportedReason: String?
    var supportsSuspend: Bool { suspendUnsupportedReason == nil && overlayDirectory == nil }
    var hasEmbeddedDisplay: Bool { true }

    /// Clones used by a disposable run, deleted when it stops.
    private var overlayDirectory: URL?
    private var spiceAgent: VZSpiceAgentPortAttachment?

    init(config: VMConfiguration, bundle: VMBundle) {
        self.config = config
        self.bundle = bundle
    }

    func update(config: VMConfiguration) {
        let foldersChanged = config.sharedFolders != self.config.sharedFolders
        self.config = config
        // shared folders can change while the guest runs
        if foldersChanged, let vm = virtualMachine, state == .running || state == .paused {
            let tag = AppleConfigurationBuilder.shareTag(for: config.guestOS)
            let device = vm.directorySharingDevices.compactMap { $0 as? VZVirtioFileSystemDevice }.first { $0.tag == tag }
            device?.share = AppleConfigurationBuilder.directoryShare(for: config.sharedFolders.filter { FileManager.default.fileExists(atPath: $0.path) })
        }
    }

    // MARK: - Lifecycle

    func start(options: StartOptions) async throws {
        guard state == .stopped else { return }
        state = .starting
        do {
            let hasSavedState = FileManager.default.fileExists(atPath: bundle.savedStateURL.path)
            let disposable = options.contains(.disposable)
            if disposable {
                try prepareOverlay()
            }
            let restoring = hasSavedState && !disposable && !options.contains(.recovery) && !options.contains(.coldBoot)
            if hasSavedState && !restoring && !disposable {
                // a cold boot invalidates the saved RAM image
                try? FileManager.default.removeItem(at: bundle.savedStateURL)
            }

            var vm = try makeVirtualMachine()
            if restoring {
                state = .restoring
                do {
                    try await vm.restoreMachineStateFrom(url: bundle.savedStateURL)
                    try await vm.resume()
                    try? FileManager.default.removeItem(at: bundle.savedStateURL)
                    state = .running
                    return
                } catch {
                    // state is stale (config or host changed): drop it and cold boot
                    try? FileManager.default.removeItem(at: bundle.savedStateURL)
                    vm = try makeVirtualMachine()
                }
            }
            if config.guestOS == .macOS {
                let startOptions = VZMacOSVirtualMachineStartOptions()
                startOptions.startUpFromMacOSRecovery = options.contains(.recovery)
                try await vm.start(options: startOptions)
            } else {
                try await vm.start()
            }
            state = .running
        } catch {
            cleanUp()
            state = .stopped
            throw error
        }
    }

    func requestStop() async throws {
        guard let vm = virtualMachine, state == .running || state == .paused else { return }
        if state == .paused {
            try await resume()
        }
        if vm.canRequestStop {
            try vm.requestStop()
        } else {
            try await forceStop()
        }
    }

    func forceStop() async throws {
        guard let vm = virtualMachine else { return }
        state = .stopping
        do {
            try await vm.stop()
        } catch {
            cleanUp()
            state = .stopped
            throw error
        }
        cleanUp()
        state = .stopped
    }

    func pause() async throws {
        guard let vm = virtualMachine, state == .running else { return }
        state = .pausing
        do {
            try await vm.pause()
            state = .paused
        } catch {
            state = .running
            throw error
        }
    }

    func resume() async throws {
        guard let vm = virtualMachine, state == .paused else { return }
        state = .resuming
        do {
            try await vm.resume()
            state = .running
        } catch {
            state = .paused
            throw error
        }
    }

    func restart() async throws {
        guard virtualMachine != nil else { return }
        try await forceStop()
        try await start(options: .coldBoot)
    }

    func suspend() async throws {
        guard let vm = virtualMachine, state == .running || state == .paused else { throw VMError.notRunning }
        if let reason = suspendUnsupportedReason {
            throw VMError.unsupported(reason)
        }
        if state == .running {
            try await pause()
        }
        state = .saving
        do {
            try await vm.saveMachineStateTo(url: bundle.savedStateURL)
        } catch {
            try? FileManager.default.removeItem(at: bundle.savedStateURL)
            state = .paused
            throw error
        }
        // stopping flushes every disk write, so the saved RAM and the disks agree
        try await vm.stop()
        cleanUp()
        state = .stopped
    }

    // MARK: - macOS installation

    /// Install macOS from a local restore image into this (stopped) VM.
    func installMacOS(from ipsw: URL, progress: @escaping (Double) -> Void) async throws {
        guard state == .stopped else { return }
        state = .installing
        var observation: NSKeyValueObservation?
        defer {
            observation?.invalidate()
            cleanUp()
            state = .stopped
        }
        let vm = try makeVirtualMachine()
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
        observation = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { p, _ in
            let fraction = p.fractionCompleted
            Task { @MainActor in progress(fraction) }
        }
        do {
            try await installer.install()
        } catch let error as NSError where error.domain == VZErrorDomain && error.code == VZError.Code.restoreImageCatalogLoadFailed.rawValue {
            throw VMError.invalidConfiguration("Device support is out of date. Open Software Update on this Mac and install any updates.")
        }
        if vm.state == .running {
            try? await vm.stop()
        }
    }

    // MARK: - Display helpers

    /// Snapshot of the guest framebuffer, if a display view is attached.
    weak var displayView: VZVirtualMachineView?

    /// Snapshot of the guest display.
    ///
    /// `VZVirtualMachineView` composites a remote layer from the VM process, so `cacheDisplay`
    /// returns black. ScreenCaptureKit's `currentProcess` content captures our own windows
    /// without asking for Screen Recording permission.
    func screenshot() async -> NSImage? {
        guard let view = displayView, let window = view.window, view.bounds.width > 0 else { return nil }
        let windowID = CGWindowID(window.windowNumber)
        let viewRect = view.convert(view.bounds, to: nil)
        let windowHeight = window.frame.height
        let scale = window.backingScaleFactor
        do {
            let content = try await SCShareableContent.currentProcess
            guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let configuration = SCStreamConfiguration()
            // window coordinates are bottom-up, capture coordinates top-down
            configuration.sourceRect = CGRect(x: viewRect.minX, y: windowHeight - viewRect.maxY, width: viewRect.width, height: viewRect.height)
            configuration.width = Int(viewRect.width * scale)
            configuration.height = Int(viewRect.height * scale)
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return NSImage(cgImage: image, size: viewRect.size)
        } catch {
            return nil
        }
    }

    // MARK: - Private

    private func makeVirtualMachine() throws -> VZVirtualMachine {
        var builder = AppleConfigurationBuilder(config: config, bundle: bundle, overlayDirectory: overlayDirectory)
        let vzConfig = try builder.build()
        try vzConfig.validate()
        spiceAgent = builder.spiceAgent
        do {
            try vzConfig.validateSaveRestoreSupport()
            suspendUnsupportedReason = nil
        } catch {
            suspendUnsupportedReason = error.localizedDescription
        }
        let vm = VZVirtualMachine(configuration: vzConfig)
        vm.delegate = self
        virtualMachine = vm
        return vm
    }

    private func prepareOverlay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-disposable-\(UUID().uuidString)")
        let files = bundle.stateFiles(for: config).filter { $0 != bundle.savedStateURL }
        try FileCloner.clone(files, into: directory)
        overlayDirectory = directory
    }

    private func cleanUp() {
        virtualMachine?.delegate = nil
        virtualMachine = nil
        spiceAgent = nil
        if let overlayDirectory {
            try? FileManager.default.removeItem(at: overlayDirectory)
        }
        overlayDirectory = nil
    }

    /// Remove clones a crashed process left behind.
    static func removeStaleOverlays() {
        let temp = FileManager.default.temporaryDirectory
        let items = (try? FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent.hasPrefix("orbit-disposable-") {
            try? FileManager.default.removeItem(at: item)
        }
    }
}

extension AppleBackend: VZVirtualMachineDelegate {
    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated {
            guard virtualMachine === self.virtualMachine, state != .installing else { return }
            cleanUp()
            state = .stopped
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        MainActor.assumeIsolated {
            guard virtualMachine === self.virtualMachine, state != .installing else { return }
            cleanUp()
            state = .stopped
            onStateChange?(.stopped, error)
        }
    }
}
