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

    @Test("Editing the text changes the content digest but not the window digest")
    func contentAndStateDigestsAreIndependent() throws {
        let original = try note("17", text: "Milk")
        var edited = original
        edited.package = try NotePackage(files: [NotePackage.richTextEntryName: richText("Milk and eggs")])

        let before = NoteDigest(original)
        let after = NoteDigest(edited)

        #expect(before.content != after.content)
        #expect(before.state == after.state)
    }

    @Test("Moving the window changes the window digest but not the content digest")
    func movingChangesOnlyTheStateDigest() throws {
        let original = try note("17")
        var moved = original
        moved.windowState = try windowState("17", frame: CGRect(x: 900, y: 40, width: 300, height: 200))

        let before = NoteDigest(original)
        let after = NoteDigest(moved)

        // This separation is the whole reason for two digests: Stickies moves
        // windows on its own, and that must not read as an edit.
        #expect(before.content == after.content)
        #expect(before.state != after.state)
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

        #expect(NoteDigest(stateless).state != NoteDigest(try note("17")).state)
    }
}
