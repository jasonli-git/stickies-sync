import Foundation
import StickiesFormat

/// One note version as it travels between Macs.
///
/// Carries its whole version vector rather than a delta: a Mac that has been
/// offline for a month, or that has never seen a peer before, must be able to
/// place a record without replaying anything. The vector is small — one integer
/// per Mac that has ever touched the note.
public struct SyncRecord: Hashable, Sendable {
    public var id: StickyID
    /// The device whose change produced this version. Not necessarily the device
    /// that published the file — a record propagates unchanged through a Mac
    /// that merely relays it.
    public var origin: DeviceID
    public var version: VersionVector
    public var isDeletion: Bool
    /// `nil` exactly when `isDeletion` is true.
    public var note: StickyNote?
    /// Informational, and deliberately not used for ordering (#4) — except as
    /// the "last writer" in the conflict tiebreak, where determinism comes from
    /// the device identifier that follows it.
    public var recordedAt: Date

    public init(
        id: StickyID,
        origin: DeviceID,
        version: VersionVector,
        isDeletion: Bool,
        note: StickyNote?,
        recordedAt: Date
    ) {
        self.id = id
        self.origin = origin
        self.version = version
        self.isDeletion = isDeletion
        self.note = note
        self.recordedAt = recordedAt
    }
}

extension SyncRecord {
    static let currentFormatVersion = 1

    enum Key {
        static let formatVersion = "FormatVersion"
        static let uuid = "UUID"
        static let origin = "Origin"
        static let version = "Version"
        static let isDeletion = "IsDeletion"
        static let note = "Note"
        static let recordedAt = "RecordedAt"
    }

    public enum RecordError: Error, Equatable, CustomStringConvertible {
        case malformed(String)
        case unsupportedFormatVersion(found: Int, supported: Int)

        public var description: String {
            switch self {
            case .malformed(let detail): "sync record is malformed: \(detail)"
            case .unsupportedFormatVersion(let found, let supported):
                "sync record format version \(found) is newer than the supported version \(supported)"
            }
        }
    }

    public var plist: PlistValue {
        var entry: [String: PlistValue] = [
            Key.formatVersion: .integer(Self.currentFormatVersion),
            Key.uuid: .string(id.rawValue),
            Key.origin: .string(origin.rawValue),
            Key.version: version.plist,
            Key.isDeletion: .bool(isDeletion),
            Key.recordedAt: .date(recordedAt),
        ]
        // A whole NoteArchive rather than a bare note, so a record and an
        // exported archive decode through exactly the same code.
        entry[Key.note] = note.map { NoteArchive(notes: [$0]).plist }
        return .dictionary(entry)
    }

    public init(plist: PlistValue) throws {
        guard let entry = plist.dictionaryValue else {
            throw RecordError.malformed("record is not a dictionary")
        }
        guard let formatVersion = entry[Key.formatVersion]?.intValue else {
            throw RecordError.malformed("missing \(Key.formatVersion)")
        }
        guard formatVersion <= Self.currentFormatVersion else {
            throw RecordError.unsupportedFormatVersion(
                found: formatVersion,
                supported: Self.currentFormatVersion
            )
        }
        guard let raw = entry[Key.uuid]?.stringValue, let id = StickyID(rawValue: raw) else {
            throw RecordError.malformed("missing or unusable \(Key.uuid)")
        }
        guard let origin = entry[Key.origin]?.stringValue else {
            throw RecordError.malformed("missing \(Key.origin)")
        }
        guard let versionPlist = entry[Key.version] else {
            throw RecordError.malformed("missing \(Key.version)")
        }

        let isDeletion = entry[Key.isDeletion]?.boolValue ?? false
        let note: StickyNote? =
            if let notePlist = entry[Key.note] {
                try NoteArchive(plist: notePlist).notes.first
            } else {
                nil
            }

        guard isDeletion == (note == nil) else {
            throw RecordError.malformed(
                "record for \(id) is \(isDeletion ? "a deletion with content" : "not a deletion but has no content")"
            )
        }

        self.init(
            id: id,
            origin: DeviceID(rawValue: origin),
            version: try VersionVector(plist: versionPlist),
            isDeletion: isDeletion,
            note: note,
            recordedAt: entry[Key.recordedAt].flatMap { if case .date(let d) = $0 { d } else { nil } }
                ?? Date(timeIntervalSince1970: 0)
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
            throw RecordError.malformed(error.localizedDescription)
        }
        try self.init(plist: try PlistValue(propertyList: object))
    }
}

extension VersionVector {
    public var plist: PlistValue {
        .dictionary(
            Dictionary(uniqueKeysWithValues: counters.map { ($0.key.rawValue, PlistValue.integer($0.value)) })
        )
    }

    public init(plist: PlistValue) throws {
        guard let entry = plist.dictionaryValue else {
            throw SyncRecord.RecordError.malformed("version vector is not a dictionary")
        }
        var counters: [DeviceID: Int] = [:]
        for (device, value) in entry {
            guard let seq = value.intValue else {
                throw SyncRecord.RecordError.malformed("version vector entry \(device) is not an integer")
            }
            counters[DeviceID(rawValue: device)] = seq
        }
        self.init(counters: counters)
    }
}
