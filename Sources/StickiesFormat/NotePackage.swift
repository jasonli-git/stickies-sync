import Foundation

/// The contents of one `<identifier>.rtfd` package, held as bytes.
///
/// Deliberately *not* an `NSAttributedString`. Reading RTFD into an attributed
/// string and writing it back produces different bytes for the same document —
/// fonts get resolved, attribute runs get coalesced, the colour table gets
/// rebuilt — and SPEC.md F4 and F5 require that a note survive a round trip
/// unchanged. Keeping the files verbatim also means an attachment format this
/// tool has never heard of replicates correctly, and gives Milestone 3 a stable
/// thing to hash.
public struct NotePackage: Hashable, Sendable {
    /// Rich text entry name inside an RTFD package, as written by
    /// `NSAttributedString`'s RTFD support and by Stickies.
    public static let richTextEntryName = "TXT.rtf"

    /// Every file in the package, keyed by its name within the package.
    /// Attachments sit alongside `TXT.rtf` under their own filenames.
    public private(set) var files: [String: Data]

    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case missingRichText
        case entryNameNotFlat(String)

        public var description: String {
            switch self {
            case .missingRichText:
                "package has no \(NotePackage.richTextEntryName)"
            case .entryNameNotFlat(let name):
                "package entry \(name) is nested; only flat RTFD packages are understood"
            }
        }
    }

    /// An RTFD package is flat: `TXT.rtf` plus attachment files. A nested entry
    /// means the format is not what this tool believes it to be, and SPEC.md F14
    /// requires saying so rather than replicating half of it.
    public init(files: [String: Data]) throws {
        guard files[Self.richTextEntryName] != nil else { throw ValidationError.missingRichText }
        if let nested = files.keys.first(where: { $0.contains("/") }) {
            throw ValidationError.entryNameNotFlat(nested)
        }
        self.files = files
    }

    public var richText: Data {
        // Guaranteed by init; a package cannot exist without it.
        files[Self.richTextEntryName]!
    }

    /// Names of everything in the package other than the rich text, sorted.
    public var attachmentNames: [String] {
        files.keys.filter { $0 != Self.richTextEntryName }.sorted()
    }

    /// Total bytes across the package, for display and for change reporting.
    public var byteCount: Int {
        files.values.reduce(0) { $0 + $1.count }
    }
}

// Reading the rich text as text needs AppKit, so those conveniences live in
// StickiesStore rather than here — see NoteText.swift. This module stays
// byte-only on purpose.
