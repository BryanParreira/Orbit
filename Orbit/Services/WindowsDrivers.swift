import Foundation

/// VirtIO drivers for Windows on ARM, on a small disc that Windows setup installs from by itself.
///
/// Windows has no driver for QEMU's virtual network card, balloon or random-number device, so a
/// fresh install can't go online. Orbit takes the ARM64 drivers from the virtio-win project,
/// puts them on a disc with an answer file, and attaches it next to the Windows installer.
/// Setup reads the answer file and installs the drivers before its network screen.
///
/// The answer file only adds steps; every setup page (language, edition, disk, account) still
/// shows. Built with the system's own `tar`, so nothing is mounted.
enum WindowsDrivers {
    static let version = "0.1.302"
    static let source = URL(string: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso")!
    /// The project publishes no checksum for the ISO, so Orbit accepts exactly this build and nothing else.
    static let sha256 = "303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d"
    /// Name of the disc in a machine's package; also how the configuration recognizes it.
    static let discName = "Orbit Windows Drivers.iso"

    enum Failure: LocalizedError {
        case noDrivers

        var errorDescription: String? {
            "The driver download didn't contain the Windows on ARM drivers Orbit expected."
        }
    }

    /// Build the drivers disc into `package` and return it. The finished disc is kept in `cache`
    /// (a few MB) so the next Windows machine doesn't download the 900 MB driver ISO again.
    /// - Parameter download: Fetches `source` and returns the local file, which is deleted afterwards.
    @MainActor
    static func prepareDisc(in package: URL, cache: URL, download: (URL) async throws -> URL) async throws -> URL {
        let disc = package.appendingPathComponent(discName)
        let cached = cache.appendingPathComponent("Orbit Windows Drivers \(version).iso")
        if !FileManager.default.fileExists(atPath: cached.path) {
            let iso = try await download(source)
            defer { try? FileManager.default.removeItem(at: iso) }
            guard try await ChecksumVerifier.sha256(of: iso) == sha256 else {
                throw ChecksumVerifier.Failure.mismatch(iso.lastPathComponent)
            }
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try await buildDisc(from: iso, to: cached)
        }
        try await FileCloner.cloneInBackground(cached, to: disc)
        return disc
    }

    /// A disc with only the answer file, for when the drivers can't be downloaded: setup still
    /// accepts the virtual hardware (no TPM needed) and can finish without a network.
    @MainActor
    static func answerOnlyDisc(in package: URL) async throws -> URL {
        let disc = package.appendingPathComponent(discName)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-drivers-\(UUID().uuidString.prefix(8))")
        defer { removeTree(work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data(answerFile.utf8).write(to: work.appendingPathComponent("autounattend.xml"))
        try await writeDisc(from: work, to: disc)
        return disc
    }

    /// Extract the Windows 11 ARM64 drivers from the virtio-win ISO and write the drivers disc.
    nonisolated static func buildDisc(from iso: URL, to destination: URL) async throws {
        let tar = URL(fileURLWithPath: "/usr/bin/tar")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-drivers-\(UUID().uuidString.prefix(8))")
        defer { removeTree(work) }
        let extracted = work.appendingPathComponent("extracted")
        let staging = work.appendingPathComponent("disc")
        let drivers = staging.appendingPathComponent("OrbitDrivers")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: drivers, withIntermediateDirectories: true)

        // The ISO stores the Windows 11 files as links to the identical Server 2025 copies, so
        // both are extracted for the links to resolve. Debug symbols aren't needed.
        try await DiskImageService.run(tar, ["-xf", iso.path, "-C", extracted.path, "--exclude", "*.pdb",
                                             "*/w11/ARM64/*", "*/2k25/ARM64/*", "NetKVM/2k25/amd64/Readme.md"])
        let fm = FileManager.default
        for component in try fm.contentsOfDirectory(atPath: extracted.path).sorted() {
            let folder = extracted.appendingPathComponent(component).appendingPathComponent("w11/ARM64")
            guard let files = try? fm.contentsOfDirectory(atPath: folder.path), files.contains(where: { $0.hasSuffix(".inf") }) else { continue }
            let target = drivers.appendingPathComponent(component)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for file in files {
                try fm.copyItem(at: folder.appendingPathComponent(file), to: target.appendingPathComponent(file))
            }
        }
        guard fm.fileExists(atPath: drivers.appendingPathComponent("NetKVM/netkvm.inf").path) else { throw Failure.noDrivers }

        try Data(installScript.utf8).write(to: drivers.appendingPathComponent("install.cmd"))
        try Data(answerFile.utf8).write(to: staging.appendingPathComponent("autounattend.xml"))
        try await writeDisc(from: staging, to: destination)
    }

    /// Write the contents of `folder` as an ISO 9660 disc (Joliet names, which Windows reads).
    nonisolated private static func writeDisc(from folder: URL, to destination: URL) async throws {
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: temp) }
        try await DiskImageService.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-cf", temp.path, "--format", "iso9660",
                                             "--options", "iso9660:joliet,iso9660:volume-id=ORBIT_DRIVERS,iso9660:!rockridge",
                                             "-C", folder.path, "."])
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    /// Files from the ISO are read-only; make them deletable first.
    nonisolated private static func removeTree(_ url: URL) {
        let fm = FileManager.default
        if let items = fm.enumerator(atPath: url.path) {
            for case let item as String in items {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.appendingPathComponent(item).path)
            }
        }
        try? fm.removeItem(at: url)
    }

    /// Runs inside Windows during setup (as SYSTEM), from whichever drive letter the disc got.
    static let installScript = """
        @echo off\r
        rem Orbit: installs the VirtIO drivers on this disc so the network, memory balloon and\r
        rem other virtual devices work. Runs once during Windows setup.\r
        rem Log: %SystemRoot%\\Temp\\orbit-drivers.log\r
        pnputil /add-driver "%~dp0*.inf" /subdirs /install >> "%SystemRoot%\\Temp\\orbit-drivers.log" 2>&1\r
        exit /b 0\r

        """

    /// Windows setup finds this on the disc by itself. It only adds steps:
    /// - windowsPE: skips the TPM, Secure Boot and memory checks, which the virtual hardware
    ///   meets but setup can misjudge;
    /// - specialize (before the first screen of the new system): installs the drivers, and lets
    ///   setup continue without a network if one still isn't available.
    static let answerFile = """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <settings pass="windowsPE">
            <component name="Microsoft-Windows-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
              <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                  <Order>1</Order>
                  <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                  <Order>2</Order>
                  <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                  <Order>3</Order>
                  <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
              </RunSynchronous>
            </component>
          </settings>
          <settings pass="specialize">
            <component name="Microsoft-Windows-Deployment" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
              <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                  <Order>1</Order>
                  <Description>Install Orbit's VirtIO drivers</Description>
                  <Path>cmd.exe /c for %d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist %d:\\OrbitDrivers\\install.cmd call %d:\\OrbitDrivers\\install.cmd</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                  <Order>2</Order>
                  <Description>Allow finishing setup offline</Description>
                  <Path>reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
              </RunSynchronous>
            </component>
          </settings>
        </unattend>

        """
}
