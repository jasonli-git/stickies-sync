import Foundation

/// A portable, versioned container for whole notes — the format `stickiesctl
/// export` writes and, from Milestone 2, `import` reads.
///
/// It is a property list rather than JSON because a note's window state already
/// *is* a property-list dictionary, including keys this version does not
/// understand. Serializing it as JSON would mean inventing a mapping for plist
/// types and hoping the mapping is lossless; keeping it as a plist makes
/// fidelity structural instead of conventional, and package bytes ride along in
/// `<data>` elements without base64 hand-rolling.
///
/// `formatVersion` exists so a Mac running a newer StickiesSync can refuse an
/// archive it would misread, rather than silently importing half of it.
public struct NoteArchive: Hashable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var notes: [StickyNote]

    public init(notes: [StickyNote], formatVersion: Int = currentFormatVersion) {
        self.formatVersion = formatVersion
        self.notes = notes
    }
}

extension NoteArchive {
    enum Key {
        static let formatVersion = "FormatVersion"
        static let notes = "Notes"
        static let uuid = "UUID"
        static let windowState = "WindowState"
        static let files = "Files"
    }

    public enum ArchiveError: Error, Equatable, CustomStringConvertible {
        case notAPropertyList(String)
        case malformed(String)
        case unsupportedFormatVersion(found: Int, supported: Int)

        public var description: String {
            switch self {
            case .notAPropertyList(let message):
                message
            case .malformed(let detail):
                "archive is malformed: \(detail)"
            case .unsupportedFormatVersion(let found, let supported):
                "archive format version \(found) is newer than the supported version \(supported)"
            }
        }
    }

    public var plist: PlistValue {
        .dictionary([
            Key.formatVersion: .integer(formatVersion),
            Key.notes: .array(
                notes.map { note in
                    var entry: [String: PlistValue] = [
                        Key.uuid: .string(note.id.rawValue),
                        Key.files: .dictionary(note.package.files.mapValues(PlistValue.data)),
                    ]
                    entry[Key.windowState] = note.windowState?.plist
                    return .dictionary(entry)
                }
            ),
        ])
    }

    public init(plist: PlistValue) throws {
        guard let root = plist.dictionaryValue else {
            throw ArchiveError.malformed("root is not a dictionary")
        }
        guard let version = root[Key.formatVersion]?.intValue else {
            throw ArchiveError.malformed("missing \(Key.formatVersion)")
        }
        guard version <= Self.currentFormatVersion else {
            throw ArchiveError.unsupportedFormatVersion(
                found: version,
                supported: Self.currentFormatVersion
            )
        }
        guard let entries = root[Key.notes]?.arrayValue else {
            throw ArchiveError.malformed("missing \(Key.notes)")
        }

        self.formatVersion = version
        self.notes = try entries.map(Self.note(from:))
    }

    private static func note(from value: PlistValue) throws -> StickyNote {
        guard let entry = value.dictionaryValue else {
            throw ArchiveError.malformed("note entry is not a dictionary")
        }
        guard let rawIdentifier = entry[Key.uuid]?.stringValue,
              let id = StickyID(rawValue: rawIdentifier)
        else {
            throw ArchiveError.malformed("note entry has a missing or unusable \(Key.uuid)")
        }
        guard let files = entry[Key.files]?.dictionaryValue else {
            throw ArchiveError.malformed("note \(id) has no \(Key.files)")
        }

        var bytes: [String: Data] = [:]
        for (name, value) in files {
            guard case .data(let data) = value else {
                throw ArchiveError.malformed("note \(id) file \(name) is not data")
            }
            bytes[name] = data
        }

        do {
            return StickyNote(
                id: id,
                package: try NotePackage(files: bytes),
                windowState: try entry[Key.windowState].map(StickyWindowState.init(plist:))
            )
        } catch let error as NotePackage.ValidationError {
            throw ArchiveError.malformed("note \(id): \(error)")
        } catch let error as StickyWindowState.ParseError {
            throw ArchiveError.malformed("note \(id): \(error)")
        }
    }

    public func serialized() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist.propertyList, format: .xml, options: 0)
    }

    public init(data: Data) throws {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw ArchiveError.notAPropertyList(error.localizedDescription)
        }
        try self.init(plist: try PlistValue(propertyList: object))
    }
}
