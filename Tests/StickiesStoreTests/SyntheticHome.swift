import Foundation
import StickiesFormat

@testable import StickiesStore

struct FixtureError: Error, CustomStringConvertible {
    let description: String
}

/// Rich text as Stickies writes it, used wherever a test needs a note with real
/// content rather than a placeholder.
let sampleRichText = Data(#"""
{\rtf1\ansi\ansicpg1252\cocoartf2870
{\fonttbl\f0\fswiss\fcharset0 Helvetica;}
{\colortbl;\red255\green255\blue255;}
\pard\tx560\pardeftab560\partightenfactor0
\f0\fs28 \cf0 Shopping list\
Milk and eggs.}
"""#.utf8)

/// A throwaway home directory laid out like a real Mac's.
///
/// The probe and the reader work against a real filesystem rather than an
/// abstraction over one, so tests give them a real filesystem — just not the
/// user's. Every path comes from `ContainerLocator`, so a change to the
/// container layout is exercised here rather than duplicated in the tests.
struct SyntheticHome {
    let root: URL
    private let fileManager = FileManager.default

    /// Creates a home, runs the body, and removes the home afterwards.
    static func run(_ body: (SyntheticHome) throws -> Void) throws {
        let root = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "StickiesSyncTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(SyntheticHome(root: root))
    }

    var stickiesDirectory: StickiesDirectory {
        ContainerLocator.stickiesDirectory(homeDirectory: root)
    }

    func createContainer() throws {
        try fileManager.createDirectory(at: stickiesDirectory.root, withIntermediateDirectories: true)
    }

    /// A note package with rich text and any attachments, as Stickies writes
    /// them: a flat directory holding `TXT.rtf` plus attachment files.
    @discardableResult
    func addNote(
        _ rawIdentifier: String,
        richText: Data = sampleRichText,
        attachments: [String: Data] = [:]
    ) throws -> StickyID {
        let id = try identifier(rawIdentifier)
        let packageURL = stickiesDirectory.packageURL(for: id)
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try richText.write(to: file(NotePackage.richTextEntryName, in: packageURL))
        for (name, contents) in attachments {
            try contents.write(to: file(name, in: packageURL))
        }
        return id
    }

    /// A package directory with nothing in it — what a reader must reject, since
    /// a note with no rich text is not a note.
    func addEmptyPackage(_ rawIdentifier: String) throws {
        try fileManager.createDirectory(
            at: stickiesDirectory.packageURL(for: try identifier(rawIdentifier)),
            withIntermediateDirectories: true
        )
    }

    /// A subdirectory inside a package, which the flat RTFD layout does not
    /// allow.
    func addNestedDirectory(named name: String, insideNote rawIdentifier: String) throws {
        try fileManager.createDirectory(
            at: stickiesDirectory.packageURL(for: try identifier(rawIdentifier))
                .appending(path: name, directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
    }

    func addDirectoryEntry(named name: String) throws {
        try fileManager.createDirectory(
            at: stickiesDirectory.root.appending(path: name, directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
    }

    func writeSavedState(entryCount: Int) throws {
        try writeSavedState(propertyList: Array(repeating: [String: Any](), count: entryCount))
    }

    func writeSavedState(notes: [StickyWindowState]) throws {
        try writeSavedState(propertyList: SavedStickiesState(notes: notes).plistArrayForTesting)
    }

    func writeSavedState(propertyList: Any) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)
        try data.write(to: stickiesDirectory.savedStateURL)
    }

    func writeRawSavedState(_ bytes: Data) throws {
        try bytes.write(to: stickiesDirectory.savedStateURL)
    }

    func createLegacyDatabase() throws {
        let url = ContainerLocator.legacyDatabaseURL(homeDirectory: root)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    func probe(runState: StickiesRunState = .notRunning) -> ContainerProbe {
        ContainerProbe.forHome(root, observeRunState: { runState })
    }

    func reader() -> StickiesReader {
        StickiesReader.forHome(root)
    }

    private func identifier(_ rawIdentifier: String) throws -> StickyID {
        guard let id = StickyID(rawValue: rawIdentifier) else {
            throw FixtureError(description: "\(rawIdentifier) is not a usable sticky identifier")
        }
        return id
    }

    private func file(_ name: String, in packageURL: URL) -> URL {
        packageURL.appending(path: name, directoryHint: .notDirectory)
    }
}

extension SavedStickiesState {
    /// The plist form as an `Any`, for handing to `PropertyListSerialization` in
    /// fixtures.
    var plistArrayForTesting: Any {
        PlistValue.array(notes.map(\.plist)).propertyList
    }
}

/// Window state with the three required keys and whatever else a test needs.
func makeWindowState(
    _ rawIdentifier: String,
    frame: CGRect = CGRect(x: 10, y: 20, width: 300, height: 200),
    color: StickyColor = StickyColor(red: 1, green: 0.96, blue: 0.61),
    isFloating: Bool? = nil,
    zOrder: Int? = nil
) throws -> StickyWindowState {
    guard let id = StickyID(rawValue: rawIdentifier) else {
        throw FixtureError(description: "\(rawIdentifier) is not a usable sticky identifier")
    }
    return StickyWindowState(
        id: id,
        frame: frame,
        palette: StickyPalette(sticky: color),
        isFloating: isFloating,
        zOrder: zOrder
    )
}
