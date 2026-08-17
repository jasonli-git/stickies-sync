import AppKit
import StickiesFormat

/// Reading a note's text for display.
///
/// These live here rather than in `StickiesFormat` because RTF parsing is an
/// AppKit facility, and `StickiesFormat` deliberately holds package contents as
/// bytes and imports nothing but Foundation. Nothing produced here is ever
/// written back: an `NSAttributedString` round trip does not reproduce the
/// original bytes, which SPEC.md F4 and F5 require.
extension NotePackage {
    /// The note's text with formatting stripped. `nil` when the rich text does
    /// not parse — reported as such rather than shown as an empty note.
    public var plainText: String? {
        guard let attributed = try? NSAttributedString(
            data: richText,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) else { return nil }
        return attributed.string
    }

    /// First non-empty line of the note's text, trimmed — what Stickies itself
    /// shows in a note's window.
    public var titleLine: String? {
        plainText?
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}
