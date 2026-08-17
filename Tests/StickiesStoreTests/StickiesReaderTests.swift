import CoreGraphics
import Foundation
import StickiesFormat
import Testing

@testable import StickiesStore

@Suite("StickiesReader")
struct StickiesReaderTests {
    @Test("Reads notes with their content and their window state joined by identifier")
    func readsNotesAndState() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addNote("A0000000-0000-0000-0000-000000000000")
            try home.addNote("B0000000-0000-0000-0000-000000000000", attachments: ["photo.png": Data([1, 2])])
            try home.writeSavedState(notes: [
                try makeWindowState("A0000000-0000-0000-0000-000000000000", zOrder: 1),
                try makeWindowState(
                    "B0000000-0000-0000-0000-000000000000",
                    frame: CGRect(x: 400, y: 700, width: 360, height: 240),
                    isFloating: true,
                    zOrder: 2
                ),
            ])

            let snapshot = try home.reader().read()

            #expect(snapshot.isFullyUnderstood)
            #expect(snapshot.notes.count == 2)

            let first = try #require(snapshot.notes.first)
            #expect(first.id.rawValue == "A0000000-0000-0000-0000-000000000000")
            #expect(first.package.richText == sampleRichText)
            #expect(first.windowState?.zOrder == 1)

            let second = snapshot.notes[1]
            #expect(second.package.attachmentNames == ["photo.png"])
            #expect(second.windowState?.frame == CGRect(x: 400, y: 700, width: 360, height: 240))
            #expect(second.windowState?.isFloating == true)
        }
    }

    @Test("An empty container reads as empty, not as an error")
    func readsAnEmptyContainer() throws {
        try SyntheticHome.run { home in
            try home.createContainer()

            let snapshot = try home.reader().read()

            #expect(snapshot.notes.isEmpty)
            #expect(snapshot.isFullyUnderstood)
        }
    }

    @Test("A container with notes but no state file still yields the notes")
    func readsNotesWithoutAStateFile() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addNote("17")

            let snapshot = try home.reader().read()

            // Stickies writes the state file only once it has something to say,
            // so its absence is not a fault.
            #expect(snapshot.notes.count == 1)
            #expect(snapshot.notes.first?.windowState == nil)
            #expect(snapshot.notesWithoutState.count == 1)
        }
    }

    @Test("Window state for a note that is not on disk is reported, not dropped")
    func reportsStateWithoutAPackage() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addNote("17")
            try home.writeSavedState(notes: [
                try makeWindowState("17"),
                try makeWindowState("18"),
            ])

            let snapshot = try home.reader().read()

            #expect(snapshot.notes.map(\.id.rawValue) == ["17"])
            #expect(snapshot.stateWithoutPackage.map(\.id.rawValue) == ["18"])
        }
    }

    @Test("A package with no rich text is reported and the other notes still read")
    func reportsAnUnreadablePackage() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addNote("17")
            try home.addEmptyPackage("18")

            let snapshot = try home.reader().read()

            #expect(snapshot.notes.map(\.id.rawValue) == ["17"])
            #expect(snapshot.unreadableNotes.map(\.id.rawValue) == ["18"])
            #expect(snapshot.hasUnreadableData)
            #expect(snapshot.isFullyUnderstood == false)
        }
    }

    @Test("A nested directory inside a package is refused rather than half-read")
    func refusesNestedPackageContents() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addNote("17")
            try home.addNestedDirectory(named: "Attachments", insideNote: "17")

            let snapshot = try home.reader().read()

            #expect(snapshot.notes.isEmpty)
            #expect(snapshot.unreadableNotes.count == 1)
            #expect(snapshot.unreadableNotes.first?.reason.contains("nested") == true)
        }
    }

    @Test("Finder metadata inside a package is not replicated")
    func skipsFinderMetadata() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addNote("17", attachments: [".DS_Store": Data([0, 1, 2])])

            let snapshot = try home.reader().read()

            // .DS_Store is machine-local by definition and never part of the
            // document, so carrying it to another Mac would be noise.
            #expect(snapshot.notes.first?.package.attachmentNames.isEmpty == true)
            #expect(snapshot.isFullyUnderstood)
        }
    }

    @Test("A state entry the format layer cannot parse is reported per entry")
    func reportsUnreadableStateEntries() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addNote("17")
            try home.writeSavedState(propertyList: [["UUID": "17"]] as [Any])

            let snapshot = try home.reader().read()

            #expect(snapshot.notes.count == 1)
            #expect(snapshot.notes.first?.windowState == nil)
            #expect(snapshot.unreadableStateEntries.count == 1)
        }
    }

    @Test("Directory entries that are not notes are carried into the snapshot")
    func reportsUnrecognizedEntries() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addNote("17")
            try home.addDirectoryEntry(named: "Backups")

            let snapshot = try home.reader().read()

            #expect(snapshot.unrecognizedEntries == ["Backups"])
            #expect(snapshot.isFullyUnderstood == false)
        }
    }

    @Test("A missing container throws, because the caller cannot work around it")
    func throwsOnAMissingContainer() throws {
        try SyntheticHome.run { home in
            #expect(throws: (any Error).self) {
                try home.reader().read()
            }
        }
    }

    @Test("A whole container round-trips through an archive without changing")
    func roundTripsThroughAnArchive() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addNote("17", attachments: ["photo.png": Data([0x89, 0x50])])
            try home.addNote("18")
            try home.writeSavedState(notes: [
                try makeWindowState("17", isFloating: true, zOrder: 1),
                try makeWindowState("18", zOrder: 2),
            ])

            let snapshot = try home.reader().read()
            let restored = try NoteArchive(data: try NoteArchive(notes: snapshot.notes).serialized())

            // The property Milestone 2's import depends on: what came off disk
            // and what comes back out of an archive are the same notes.
            #expect(restored.notes == snapshot.notes)
        }
    }
}
