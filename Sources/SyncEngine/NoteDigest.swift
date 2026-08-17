import CryptoKit
import Foundation
import StickiesFormat

/// Content and appearance digests for a note.
///
/// Two digests rather than one, because the two travel differently. Stickies
/// repositions windows on its own and renumbers z-order as they are raised, so a
/// single digest would report a note as edited every time its window moved — and
/// a sync driven by that would ship a note's whole content because the user
/// dragged it. Separating them lets a caller treat a move as the smaller event
/// it is.
public struct NoteDigest: Hashable, Sendable {
    /// Over the package bytes: the note's text, formatting, and attachments.
    public let content: String
    /// Over the window state: geometry, colours, flags, and any key this version
    /// does not understand.
    public let state: String

    public init(content: String, state: String) {
        self.content = content
        self.state = state
    }

    public init(_ note: StickyNote) {
        self.content = Self.digest(of: note.package)
        self.state = Self.digest(of: note.windowState)
    }

    /// Files are folded in sorted-name order, each length-prefixed, so a
    /// dictionary's arbitrary iteration order cannot change the result and no
    /// two different packages can hash alike by their bytes running together.
    private static func digest(of package: NotePackage) -> String {
        var hasher = SHA256()
        for name in package.files.keys.sorted() {
            let contents = package.files[name] ?? Data()
            hasher.update(data: Data("\(name)\u{0}\(contents.count):".utf8))
            hasher.update(data: contents)
        }
        return hexadecimal(hasher.finalize())
    }

    /// A note with no window state digests distinctly from one whose state is
    /// empty, so acquiring a position registers as a change.
    private static func digest(of state: StickyWindowState?) -> String {
        guard let state else { return hexadecimal(SHA256.hash(data: Data("no-window-state".utf8))) }
        return hexadecimal(SHA256.hash(data: state.plist.canonicalBytes))
    }

    private static func hexadecimal(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
