import CoreGraphics
import Foundation
import Testing

@testable import StickiesFormat

@Suite("NotePackage and NoteArchive")
struct NoteArchiveTests {
    private func package(
        rtf: Data = handwrittenRichText,
        attachments: [String: Data] = [:]
    ) throws -> NotePackage {
        var files = attachments
        files[NotePackage.richTextEntryName] = rtf
        return try NotePackage(files: files)
    }

    private func note(id rawIdentifier: String = "17") throws -> StickyNote {
        StickyNote(
            id: try #require(StickyID(rawValue: rawIdentifier)),
            package: try package(attachments: ["image.png": Data([0x89, 0x50, 0x4E, 0x47])]),
            windowState: try StickyWindowState(
                plist: .dictionary([
                    "UUID": .string(rawIdentifier),
                    "Frame": .string("{{400, 700}, {360, 240}}"),
                    "StickyColor": StickyColor(red: 0.6784, green: 0.8471, blue: 1).plist,
                    "Floating": .bool(true),
                    "ZOrder": .integer(2),
                ])
            )
        )
    }

    @Test("A package without rich text is not a package")
    func requiresRichText() {
        #expect(throws: NotePackage.ValidationError.missingRichText) {
            try NotePackage(files: ["image.png": Data()])
        }
    }

    @Test("A nested package entry is refused rather than half-replicated")
    func refusesNestedEntries() throws {
        #expect(throws: NotePackage.ValidationError.entryNameNotFlat("subdir/")) {
            try NotePackage(files: [NotePackage.richTextEntryName: handwrittenRichText, "subdir/": Data()])
        }
    }

    @Test("Attachments are listed separately from the rich text")
    func separatesAttachments() throws {
        let package = try package(attachments: ["b.png": Data([1]), "a.tiff": Data([2, 3])])

        #expect(package.attachmentNames == ["a.tiff", "b.png"])
        #expect(package.byteCount == handwrittenRichText.count + 3)
    }

    @Test("An archive reproduces every package byte exactly")
    func roundTripsPackageBytes() throws {
        let original = try note()

        let archive = try NoteArchive(data: try NoteArchive(notes: [original]).serialized())
        let restored = try #require(archive.notes.first)

        #expect(restored.package.files == original.package.files)
        #expect(restored.package.richText == handwrittenRichText)
        #expect(restored == original)
    }

    @Test("An archive round-trips window state, including unrecognised keys")
    func roundTripsWindowState() throws {
        var original = try note()
        original.windowState?.unrecognized["MultiScreenFrame"] = .string("{{0, 0}, {1, 1}}")

        let archive = try NoteArchive(data: try NoteArchive(notes: [original]).serialized())

        #expect(archive.notes.first?.windowState == original.windowState)
    }

    @Test("A note with no window state archives and restores as such")
    func roundTripsANoteWithoutState() throws {
        let original = StickyNote(
            id: try #require(StickyID(rawValue: "17")),
            package: try package()
        )

        let archive = try NoteArchive(data: try NoteArchive(notes: [original]).serialized())

        #expect(archive.notes == [original])
        #expect(archive.notes.first?.windowState == nil)
    }

    @Test("An archive records the format version it was written with")
    func recordsFormatVersion() throws {
        let archive = try NoteArchive(data: try NoteArchive(notes: []).serialized())
        #expect(archive.formatVersion == NoteArchive.currentFormatVersion)
    }

    @Test("An archive from a newer StickiesSync is refused, not partially read")
    func refusesNewerArchives() throws {
        let future = NoteArchive.currentFormatVersion + 1
        let data = try NoteArchive(notes: [], formatVersion: future).serialized()

        #expect(throws: NoteArchive.ArchiveError.unsupportedFormatVersion(
            found: future,
            supported: NoteArchive.currentFormatVersion
        )) {
            try NoteArchive(data: data)
        }
    }

    @Test("A malformed archive is refused with a reason")
    func refusesMalformedArchives() throws {
        let missingVersion = try PropertyListSerialization.data(
            fromPropertyList: ["Notes": []], format: .xml, options: 0
        )
        #expect(throws: NoteArchive.ArchiveError.malformed("missing FormatVersion")) {
            try NoteArchive(data: missingVersion)
        }

        let badNote = try PropertyListSerialization.data(
            fromPropertyList: ["FormatVersion": 1, "Notes": [["UUID": "17"]]],
            format: .xml,
            options: 0
        )
        #expect(throws: NoteArchive.ArchiveError.malformed("note 17 has no Files")) {
            try NoteArchive(data: badNote)
        }
    }
}
