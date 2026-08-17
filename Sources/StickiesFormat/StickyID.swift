import Foundation

/// Identifies a single sticky note.
///
/// A note's identity on disk is the base name of its `.rtfd` package. Stickies
/// generates UUID names for new notes, but the legacy-database importer emits
/// decimal names (the `%lu.rtfd` format string in the app binary), and
/// `.SavedStickiesState` keys off whichever string the package happens to use.
/// The identifier is therefore a *string that is usually a UUID*, not a `UUID`
/// — modelling it as the latter would drop notes carried over from a
/// pre-sandbox Mac.
public struct StickyID: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: String

    /// Fails for names that could escape the container directory or shadow the
    /// dot-prefixed state file.
    public init?(rawValue: String) {
        guard Self.isAcceptable(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(uuid: UUID) {
        self.rawValue = uuid.uuidString
    }

    public static func generate() -> StickyID {
        StickyID(uuid: UUID())
    }

    /// The `UUID` form when the note uses modern naming; `nil` for a note
    /// carried over from the pre-sandbox `~/Library/StickiesDatabase`.
    public var uuid: UUID? {
        UUID(uuidString: rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: StickyID, rhs: StickyID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    private static func isAcceptable(_ raw: String) -> Bool {
        guard !raw.isEmpty, !raw.hasPrefix(".") else { return false }
        return !raw.contains(where: { $0 == "/" || $0 == ":" || $0.isNewline })
    }

    // Encoded as a bare string rather than a wrapper object, so identifiers
    // read the same in JSON as they do on disk.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = StickyID(rawValue: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Not a usable sticky identifier: \(raw)")
            )
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension StickyID {
    /// Name of the note's package on disk, e.g. `283D5D66-….rtfd`.
    public var packageFileName: String {
        "\(rawValue).\(StickiesFileNames.packageExtension)"
    }

    /// Recovers an identifier from a directory entry name, or `nil` if the
    /// entry is not a note package.
    public init?(packageFileName: String) {
        let url = URL(fileURLWithPath: packageFileName)
        guard url.pathExtension == StickiesFileNames.packageExtension else { return nil }
        self.init(rawValue: url.deletingPathExtension().lastPathComponent)
    }
}
