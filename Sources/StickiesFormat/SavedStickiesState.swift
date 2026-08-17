import Foundation

/// The `.SavedStickiesState` document: an ordered array of per-note window
/// state, keyed inside each entry by `UUID`.
///
/// Entries this version cannot parse are kept verbatim rather than dropped. One
/// malformed or future-format entry therefore costs the sync of that one note,
/// not the whole file, and writing the file back cannot damage the notes we did
/// not understand. Order is preserved because it is the file's own order and
/// nothing is gained by disturbing it.
public struct SavedStickiesState: Hashable, Sendable {
    public enum Entry: Hashable, Sendable {
        case note(StickyWindowState)
        case unreadable(value: PlistValue, reason: String)
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public init(notes: [StickyWindowState]) {
        self.entries = notes.map(Entry.note)
    }

    public var notes: [StickyWindowState] {
        entries.compactMap { if case .note(let state) = $0 { state } else { nil } }
    }

    /// The reasons individual entries could not be read, for reporting. Empty
    /// on a container this version fully understands.
    public var unreadableReasons: [String] {
        entries.compactMap { if case .unreadable(_, let reason) = $0 { reason } else { nil } }
    }

    public subscript(id: StickyID) -> StickyWindowState? {
        notes.first { $0.id == id }
    }
}

extension SavedStickiesState {
    public enum DecodingFailure: Error, Equatable, CustomStringConvertible {
        case notAPropertyList(String)
        case rootIsNotAnArray(String)

        public var description: String {
            switch self {
            case .notAPropertyList(let message): "\(message)"
            case .rootIsNotAnArray(let type): "state file root is \(type), expected an array"
            }
        }
    }

    public init(data: Data) throws {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw DecodingFailure.notAPropertyList(error.localizedDescription)
        }

        guard let root = try? PlistValue(propertyList: object), let array = root.arrayValue else {
            throw DecodingFailure.rootIsNotAnArray(String(describing: type(of: object)))
        }

        self.entries = array.map { value in
            do {
                return .note(try StickyWindowState(plist: value))
            } catch {
                return .unreadable(value: value, reason: String(describing: error))
            }
        }
    }

    /// Serialized as XML, which is the format Stickies itself writes; a binary
    /// plist would be valid but would make the file undiffable for anyone
    /// looking at it by hand.
    public func serialized() throws -> Data {
        let array = PlistValue.array(
            entries.map { entry in
                switch entry {
                case .note(let state): state.plist
                case .unreadable(let value, _): value
                }
            }
        )
        return try PropertyListSerialization.data(
            fromPropertyList: array.propertyList,
            format: .xml,
            options: 0
        )
    }
}
