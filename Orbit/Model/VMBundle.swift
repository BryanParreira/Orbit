import Foundation

/// On-disk layout of a `.orbitvm` package.
///
/// ```
/// Name.orbitvm/
///   config.json
///   Disk-<id>.asif | .img | .qcow2
///   HardwareModel, MachineIdentifier, AuxiliaryStorage   (macOS guests)
///   GenericMachineIdentifier, EFIVariables               (Linux guests)
///   SavedState.vzvmsave                                   (suspended)
///   Screenshot.png
///   Snapshots/<uuid>/{snapshot.json, ...cloned files}
/// ```
struct VMBundle: Hashable {
    static let fileExtension = "orbitvm"

    let url: URL

    var configURL: URL { url.appendingPathComponent("config.json") }
    var hardwareModelURL: URL { url.appendingPathComponent("HardwareModel") }
    var machineIdentifierURL: URL { url.appendingPathComponent("MachineIdentifier") }
    var auxiliaryStorageURL: URL { url.appendingPathComponent("AuxiliaryStorage") }
    var genericMachineIdentifierURL: URL { url.appendingPathComponent("GenericMachineIdentifier") }
    var efiVariablesURL: URL { url.appendingPathComponent("EFIVariables") }
    var savedStateURL: URL { url.appendingPathComponent("SavedState.vzvmsave") }
    var screenshotURL: URL { url.appendingPathComponent("Screenshot.png") }
    var snapshotsURL: URL { url.appendingPathComponent("Snapshots", isDirectory: true) }
    var logURL: URL { url.appendingPathComponent("Console.log") }

    func diskURL(for disk: DiskConfiguration) -> URL {
        disk.isExternal ? URL(fileURLWithPath: disk.path) : url.appendingPathComponent(disk.path)
    }

    /// Files whose contents together form the machine's persistent state.
    /// Snapshots and disposable runs clone exactly these.
    func stateFiles(for config: VMConfiguration) -> [URL] {
        var files = config.disks.filter { !$0.isRemovable && !$0.isExternal && !$0.isReadOnly }.map(diskURL(for:))
        files += [auxiliaryStorageURL, efiVariablesURL, savedStateURL]
        return files.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func loadConfiguration() throws -> VMConfiguration {
        let data = try Data(contentsOf: configURL)
        return try JSONDecoder.orbit.decode(VMConfiguration.self, from: data)
    }

    func save(_ config: VMConfiguration) throws {
        let data = try JSONEncoder.orbit.encode(config)
        try data.write(to: configURL, options: .atomic)
    }
}

extension JSONEncoder {
    static var orbit: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var orbit: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
