import Foundation
import Testing

@testable import StickiesFormat

@Suite("StickyID")
struct StickyIDTests {
    @Test("A generated identifier round-trips through its UUID form")
    func generatedIdentifierIsAUUID() throws {
        let id = StickyID.generate()
        let uuid = try #require(id.uuid)
        #expect(StickyID(uuid: uuid) == id)
    }

    @Test("Legacy decimal package names are accepted and report no UUID")
    func legacyNamesAreAccepted() throws {
        // Stickies' legacy-database importer names packages with `%lu.rtfd`,
        // so an identifier that insisted on being a UUID would drop these.
        let id = try #require(StickyID(rawValue: "17"))
        #expect(id.rawValue == "17")
        #expect(id.uuid == nil)
    }

    @Test("Names that could escape the container or shadow the state file are rejected", arguments: [
        "",
        ".",
        ".SavedStickiesState",
        "../escape",
        "sub/dir",
        "has:colon",
        "two\nlines",
    ])
    func unsafeNamesAreRejected(name: String) {
        #expect(StickyID(rawValue: name) == nil)
    }

    @Test("An identifier round-trips through its package file name")
    func packageFileNameRoundTrip() throws {
        let id = StickyID.generate()
        #expect(id.packageFileName == "\(id.rawValue).rtfd")
        #expect(StickyID(packageFileName: id.packageFileName) == id)
    }

    @Test("Entries that are not note packages yield no identifier", arguments: [
        "notes.txt",
        "Stickies",
        ".SavedStickiesState",
        ".rtfd",
    ])
    func nonPackageNamesYieldNoIdentifier(name: String) {
        #expect(StickyID(packageFileName: name) == nil)
    }

    @Test("Identifiers encode as bare JSON strings")
    func codableIsABareString() throws {
        let id = try #require(StickyID(rawValue: "283D5D66-E204-497A-A0DB-3B5D7963085A"))

        let encoded = try JSONEncoder().encode(id)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"283D5D66-E204-497A-A0DB-3B5D7963085A\"")
        #expect(try JSONDecoder().decode(StickyID.self, from: encoded) == id)
    }

    @Test("Decoding rejects an identifier the initializer would refuse")
    func codableRejectsUnsafeNames() {
        let encoded = Data(#""../escape""#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(StickyID.self, from: encoded)
        }
    }
}
