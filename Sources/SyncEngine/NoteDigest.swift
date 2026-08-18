import CryptoKit
import Foundation
import StickiesFormat

/// Three digests for a note, because its three parts travel differently.
///
/// - `content` and `appearance` describe the note, and belong on every Mac.
/// - `geometry` describes where a window sits, which is a property of the
///   display it was placed on. It is deliberately excluded from everything that
///   drives syncing.
///
/// The three-way split replaced a two-way one after two real Macs were put in
/// play. Opening Stickies on a 1512-wide laptop clamps notes placed on a
/// 2560-wide desktop and rewrites some of them to disk; with geometry folded
/// into one "state" digest those rewrites read as ordinary edits and replicated,
/// so every Mac's layout collapsed to the smallest screen in the set.
public struct NoteDigest: Hashable, Sendable {
    /// Over the package bytes: the note's text, formatting, and attachments.
    public let content: String
    /// Over colour, translucency, floating, and keys this version does not
    /// recognise.
    public let appearance: String
    /// Over frame, size, z-order and per-screen frames. Never published.
    public let geometry: String

    public init(content: String, appearance: String, geometry: String) {
        self.content = content
        self.appearance = appearance
        self.geometry = geometry
    }

    public init(_ note: StickyNote) {
        self.content = Self.digest(of: note.package)
        self.appearance = Self.digest(of: note.windowState?.appearancePlist, absent: "no-window-state")
        self.geometry = Self.digest(of: note.windowState?.geometryPlist, absent: "no-geometry")
    }

    /// True when the notes differ in a way worth telling another Mac about.
    public func differsInSyncedPartsFrom(_ other: NoteDigest) -> Bool {
        content != other.content || appearance != other.appearance
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
    private static func digest(of part: PlistValue?, absent: String) -> String {
        guard let part else { return hexadecimal(SHA256.hash(data: Data(absent.utf8))) }
        return hexadecimal(SHA256.hash(data: part.canonicalBytes))
    }

    private static func hexadecimal(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
