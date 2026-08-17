import Foundation
import Testing

@testable import StickiesFormat

@Suite("StickiesDirectory")
struct StickiesDirectoryTests {
    private let directory = StickiesDirectory(root: URL(filePath: "/tmp/Stickies", directoryHint: .isDirectory))

    @Test("Derives the state file and note package paths from the root")
    func derivesPaths() throws {
        let id = try #require(StickyID(rawValue: "17"))
        #expect(directory.savedStateURL.path(percentEncoded: false) == "/tmp/Stickies/.SavedStickiesState")
        // An RTFD package is a directory, and the URL says so — hence the
        // trailing slash. Path components still read normally through it.
        #expect(directory.packageURL(for: id).path(percentEncoded: false) == "/tmp/Stickies/17.rtfd/")
        #expect(directory.packageURL(for: id).lastPathComponent == "17.rtfd")
    }

    @Test("Splits a listing into notes, the state file, and entries it cannot classify")
    func classifiesEntries() throws {
        let contents = directory.classify(entryNames: [
            "B0000000-0000-0000-0000-000000000000.rtfd",
            ".SavedStickiesState",
            "A0000000-0000-0000-0000-000000000000.rtfd",
            ".DS_Store",
            "Backups",
        ])

        #expect(contents.notes.map(\.rawValue) == [
            "A0000000-0000-0000-0000-000000000000",
            "B0000000-0000-0000-0000-000000000000",
        ])
        #expect(contents.hasSavedState)
        #expect(contents.unrecognized == [".DS_Store", "Backups"])
    }

    @Test("An empty listing is classified as an empty container, not a broken one")
    func classifiesEmptyListing() {
        let contents = directory.classify(entryNames: [String]())
        #expect(contents == StickiesDirectory.Contents(notes: [], hasSavedState: false, unrecognized: []))
    }
}
