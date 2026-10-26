import Foundation

public struct ConfirmedSnapshot: Codable, Equatable, Sendable {
    public var version = 1
    public let peripheralID: UUID
    public let manufacturer: String
    public let model: String
    public let firmware: String
    public let modes: [ListeningMode]
    public let devices: [PairedAudioDevice]
    public let eq: [EQSetting]
    public let lastMode: UInt8
    public let lastSeen: Date
    public let battery: Int?
    public let controllerAddress: Data?
    public let multipoint: Bool?

    public func validate(for expectedID: UUID) throws {
        guard version == 1, peripheralID == expectedID,
              manufacturer == "Bose Corporation", model.hasPrefix("884367-"),
              !firmware.isEmpty, firmware.utf8.count <= 128,
              !modes.isEmpty, modes.count <= 4,
              Set(modes.map(\.index)).count == modes.count,
              modes.contains(where: { $0.index == 0 }), modes.contains(where: { $0.index == 1 }),
              modes.contains(where: { $0.index == lastMode }),
              modes.allSatisfy({ $0.index < 4 && $0.rawCNC <= 10 && $0.name.utf8.count <= 32 && ($0.index < 2 || $0.configured) }),
              eq.count == 3, Set(eq.map(\.band)).count == 3,
              eq.allSatisfy({ $0.minimum == -10 && $0.maximum == 10 && (-10...10).contains($0.value) }),
              devices.count <= 42, Set(devices.map(\.address)).count == devices.count,
              devices.allSatisfy({ $0.address.count == 6 && $0.name.utf8.count <= 246 }),
              battery == nil || (0...100).contains(battery!),
              controllerAddress == nil || devices.contains(where: { $0.address == controllerAddress }) else {
            throw SnapshotError.invalid
        }
    }
}

public enum SnapshotError: Error { case invalid, tooLarge }

/// Snapshot values are presentation data only; connection and capability gates
/// are deliberately not stored here. An invalid/foreign snapshot is never loaded.
public struct ConfirmedSnapshotStore {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
    public func load(for peripheralID: UUID) -> ConfirmedSnapshot? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= 262_144 else { return nil }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(ConfirmedSnapshot.self, from: Data(contentsOf: fileURL))
            try snapshot.validate(for: peripheralID)
            return snapshot
        } catch { return nil }
    }
    public func save(_ snapshot: ConfirmedSnapshot) throws {
        try snapshot.validate(for: snapshot.peripheralID)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        guard data.count <= 262_144 else { throw SnapshotError.tooLarge }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: fileURL, options: .atomic)
        #endif
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        var target = fileURL; try target.setResourceValues(flags)
        var folder = directory; try folder.setResourceValues(flags)
    }
}
