import CoreGraphics
import Foundation
import StickiesFormat
import Testing

@testable import SyncEngine

@Suite("Canonical encoding and digests")
struct DigestTests {
    @Test("Dictionary key order does not change the encoding")
    func canonicalBytesAreOrderIndependent() {
        // Swift dictionaries iterate in an order that varies per process, so an
        // encoding that just walked them would hash the same state two ways.
        let one = PlistValue.dictionary(["a": .integer(1), "b": .integer(2), "c": .integer(3)])
        let other = PlistValue.dictionary(["c": .integer(3), "b": .integer(2), "a": .integer(1)])

        #expect(one.canonicalBytes == other.canonicalBytes)
    }

    @Test("Array order does change the encoding")
    func canonicalBytesRespectArrayOrder() {
        #expect(
            PlistValue.array([.integer(1), .integer(2)]).canonicalBytes
                != PlistValue.array([.integer(2), .integer(1)]).canonicalBytes
        )
    }

    @Test("Values that would run together are kept distinct by length prefixes")
    func canonicalBytesAreUnambiguous() {
        // Without length prefixes both of these would encode as "ab" followed by
        // "c" in some order and collide.
        #expect(
            PlistValue.array([.string("ab"), .string("c")]).canonicalBytes
                != PlistValue.array([.string("a"), .string("bc")]).canonicalBytes
        )
    }

    @Test("Types are distinguished even when they print the same")
    func canonicalBytesDistinguishTypes() {
        #expect(PlistValue.integer(1).canonicalBytes != PlistValue.string("1").canonicalBytes)
        #expect(PlistValue.bool(true).canonicalBytes != PlistValue.integer(1).canonicalBytes)
        #expect(PlistValue.double(1).canonicalBytes != PlistValue.integer(1).canonicalBytes)
    }

    @Test("The same note always digests the same way")
    func digestIsStable() throws {
        let first = try note("17")
        let second = try note("17")

        #expect(NoteDigest(first) == NoteDigest(second))
    }

    @Test("Editing the text changes the content digest and nothing else")
    func contentAndStateDigestsAreIndependent() throws {
        let original = try note("17", text: "Milk")
        var edited = original
        edited.package = try NotePackage(files: [NotePackage.richTextEntryName: richText("Milk and eggs")])

        let before = NoteDigest(original)
        let after = NoteDigest(edited)

        #expect(before.content != after.content)
        #expect(before.appearance == after.appearance)
        #expect(before.geometry == after.geometry)
    }

    @Test("Moving the window changes only the geometry digest")
    func movingChangesOnlyTheGeometryDigest() throws {
        let original = try note("17")
        var moved = original
        moved.windowState = try windowState("17", frame: CGRect(x: 900, y: 40, width: 300, height: 200))

        let before = NoteDigest(original)
        let after = NoteDigest(moved)

        // The whole reason geometry is hashed separately: Stickies moves windows
        // on its own whenever a note does not fit the screen, and that must not
        // read as anything worth telling another Mac about.
        #expect(before.content == after.content)
        #expect(before.appearance == after.appearance)
        #expect(before.geometry != after.geometry)
        #expect(before.differsInSyncedPartsFrom(after) == false)
    }

    @Test("Recolouring changes the appearance digest, and does count as a change to share")
    func recolouringChangesAppearance() throws {
        let original = try note("17")
        var recoloured = original
        recoloured.windowState = try windowState(
            "17",
            color: StickyColor(red: 0.68, green: 0.85, blue: 1)
        )

        let before = NoteDigest(original)
        let after = NoteDigest(recoloured)

        // Colour is a property of the note, not of the screen it sits on.
        #expect(before.appearance != after.appearance)
        #expect(before.geometry == after.geometry)
        #expect(before.differsInSyncedPartsFrom(after))
    }

    @Test("An attachment counts as content")
    func attachmentsAreContent() throws {
        let plain = try note("17")
        let withPhoto = try note("17", attachments: ["photo.png": Data([1, 2, 3])])

        #expect(NoteDigest(plain).content != NoteDigest(withPhoto).content)
    }

    @Test("Having no window state digests differently from having one")
    func absentStateHasItsOwnDigest() throws {
        var stateless = try note("17")
        stateless.windowState = nil

        #expect(NoteDigest(stateless).appearance != NoteDigest(try note("17")).appearance)
    }
}
