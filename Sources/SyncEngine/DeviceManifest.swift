import Foundation
import StickiesFormat

/// What one Mac claims to hold, without the content.
///
/// A peer reads manifests first and fetches only the records whose vectors say
/// it is behind. On a shared folder that saves reading every note on every pass;
/// on a slower transport it is the difference between a sync and a download.
public struct DeviceManifest: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        public let id: StickyID
        public let version: VersionVector
        public let isDeletion: Bool

        public init(id: StickyID, version: VersionVector, isDeletion: Bool) {
            self.id = id
            self.version = version
            self.isDeletion = isDeletion
        }
    }

    public var device: DeviceID
    public var deviceName: String
    public var entries: [Entry]

    /// Carries no publication time, deliberately.
    ///
    /// It did until 0.6.0, and it was never read for anything — but it changed
    /// on every pass, which meant the manifest's bytes changed on every pass.
    /// Once the manifest is sealed there is no way to compare "what it says"
    /// without decrypting, so a timestamp nobody reads would have re-uploaded the
    /// file every thirty seconds and woken every other Mac for it, undoing #49.
    /// The file's own modification time answers "when did this Mac last publish"
    /// more honestly anyway.
    public init(device: DeviceID, deviceName: String, entries: [Entry]) {
        self.device = device
        self.deviceName = deviceName
        self.entries = entries
    }

    public subscript(id: StickyID) -> Entry? {
        entries.first { $0.id == id }
    }
}

extension DeviceManifest {
    /// 2 since the publication time was dropped.
    static let currentFormatVersion = 2

    enum Key {
        static let formatVersion = "FormatVersion"
        static let device = "Device"
        static let deviceName = "DeviceName"
        static let entries = "Entries"
        static let uuid = "UUID"
        static let version = "Version"
        static let isDeletion = "IsDeletion"
    }

    public var plist: PlistValue {
        .dictionary([
            Key.formatVersion: .integer(Self.currentFormatVersion),
            Key.device: .string(device.rawValue),
            Key.deviceName: .string(deviceName),
            // Sorted so a manifest republished with no changes is byte-identical
            // and the underlying file syncer has nothing to carry.
            Key.entries: .array(
                entries.sorted { $0.id < $1.id }.map { entry in
                    .dictionary([
                        Key.uuid: .string(entry.id.rawValue),
                        Key.version: entry.version.plist,
                        Key.isDeletion: .bool(entry.isDeletion),
                    ])
                }
            ),
        ])
    }

    public init(plist: PlistValue) throws {
        guard let entry = plist.dictionaryValue else {
            throw SyncRecord.RecordError.malformed("manifest is not a dictionary")
        }
        guard let formatVersion = entry[Key.formatVersion]?.intValue else {
            throw SyncRecord.RecordError.malformed("manifest is missing \(Key.formatVersion)")
        }
        guard formatVersion <= Self.currentFormatVersion else {
            throw SyncRecord.RecordError.unsupportedFormatVersion(
                found: formatVersion,
                supported: Self.currentFormatVersion
            )
        }
        guard let device = entry[Key.device]?.stringValue else {
            throw SyncRecord.RecordError.malformed("manifest is missing \(Key.device)")
        }

        self.init(
            device: DeviceID(rawValue: device),
            deviceName: entry[Key.deviceName]?.stringValue ?? device,
            entries: try (entry[Key.entries]?.arrayValue ?? []).map { value in
                guard let row = value.dictionaryValue,
                      let raw = row[Key.uuid]?.stringValue,
                      let id = StickyID(rawValue: raw),
                      let versionPlist = row[Key.version]
                else {
                    throw SyncRecord.RecordError.malformed("manifest entry is malformed")
                }
                return Entry(
                    id: id,
                    version: try VersionVector(plist: versionPlist),
                    isDeletion: row[Key.isDeletion]?.boolValue ?? false
                )
            }
        )
    }

    public func serialized() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist.propertyList, format: .xml, options: 0)
    }

    public init(data: Data) throws {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw SyncRecord.RecordError.malformed(error.localizedDescription)
        }
        try self.init(plist: try PlistValue(propertyList: object))
    }
}
