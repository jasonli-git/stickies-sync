import CryptoKit
import Foundation
import StickiesFormat
import Testing

@testable import SyncEngine

@Suite("Vault sealing")
struct VaultTests {
    private let macA = DeviceID(rawValue: "AAAAAAAA-0000-0000-0000-000000000001")
    private let macB = DeviceID(rawValue: "BBBBBBBB-0000-0000-0000-000000000002")
    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private func record(
        _ raw: String = "17",
        text: String = "Milk",
        origin: DeviceID? = nil
    ) throws -> SyncRecord {
        SyncRecord(
            id: try stickyID(raw),
            origin: origin ?? macA,
            version: VersionVector(counters: [macA: 1]),
            isDeletion: false,
            note: try note(raw, text: text),
            recordedAt: epoch
        )
    }

    // MARK: - Round trips

    @Test("A sealed record comes back exactly as it went in")
    func sealedRecordRoundTrips() throws {
        let vault = Vault.generate()
        let original = try record(text: "Buy milk and eggs")

        let sealed = try vault.seal(record: original, publishedBy: macA)
        let opened = try vault.open(record: sealed, publishedBy: macA, named: vault.name(of: original.id))

        #expect(opened == original)
    }

    @Test("A sealed manifest comes back exactly as it went in")
    func sealedManifestRoundTrips() throws {
        let vault = Vault.generate()
        let original = DeviceManifest(
            device: macA,
            deviceName: "mac-a",
            entries: [
                .init(id: try stickyID("17"), version: VersionVector(counters: [macA: 2]), isDeletion: false)
            ]
        )

        let sealed = try vault.seal(manifest: original, publishedBy: macA)

        #expect(try vault.open(manifest: sealed, publishedBy: macA) == original)
    }

    @Test("None of the note survives into the sealed payload")
    func sealingHidesTheNote() throws {
        let vault = Vault.generate()
        let id = "A0000000-0000-0000-0000-000000000001"
        let sealed = try vault.seal(record: try record(id, text: "Dentist at four"), publishedBy: macA)

        // Against the ciphertext itself, not the file around it. Searching the
        // file would prove nothing: the payload rides in a `<data>` element, so
        // even a completely unsealed record would be base64 by the time it got
        // there and no plaintext needle would match.
        let payload = try #require(Self.payload(of: sealed))
        #expect(!payload.contains(Data("Dentist".utf8)))
        #expect(!payload.contains(Data(id.utf8)))
        #expect(!payload.contains(Data("rtf1".utf8)))
        #expect(!payload.contains(Data("FormatVersion".utf8)))

        // And the identifier is not in the file either, where it would be a
        // plain string rather than base64.
        #expect(!sealed.contains(Data(id.utf8)))
    }

    /// The sealed blob out of the envelope around it.
    static func payload(of file: Data) -> Data? {
        guard let object = try? PropertyListSerialization.propertyList(from: file, format: nil),
              let plist = try? PlistValue(propertyList: object),
              case .data(let payload)? = plist.dictionaryValue?["Sealed"]
        else { return nil }
        return payload
    }

    // MARK: - Determinism

    @Test("Sealing the same record twice produces the same bytes")
    func sealingIsDeterministic() throws {
        let vault = Vault.generate()
        let record = try record()

        // Decisions #48 and #49 depend on this: an unchanged record must
        // re-publish to identical bytes, or every pass re-uploads the folder.
        #expect(
            try vault.seal(record: record, publishedBy: macA)
                == vault.seal(record: record, publishedBy: macA)
        )
    }

    @Test("Two vaults built from the same key seal identically")
    func sealingIsStableAcrossInstances() throws {
        let key = SymmetricKey(size: .bits256)
        let manifest = DeviceManifest(
            device: macA,
            deviceName: "mac-a",
            entries: [
                .init(id: try stickyID("18"), version: VersionVector(counters: [macB: 3]), isDeletion: true),
                .init(id: try stickyID("17"), version: VersionVector(counters: [macA: 1]), isDeletion: false),
            ]
        )

        // Two instances stand in for two runs of the agent: the sealed bytes are
        // a function of the key and the content, never of the process.
        #expect(
            try Vault(key: key).seal(manifest: manifest, publishedBy: macA)
                == Vault(key: key).seal(manifest: manifest, publishedBy: macA)
        )
        #expect(Vault(key: key).keyID == Vault(key: key).keyID)
    }

    @Test("A different record seals to different bytes")
    func differentRecordsSealDifferently() throws {
        let vault = Vault.generate()

        #expect(
            try vault.seal(record: try record(text: "One"), publishedBy: macA)
                != vault.seal(record: try record(text: "Two"), publishedBy: macA)
        )
    }

    // MARK: - What the sealing is bound to

    @Test("A record moved into another Mac's subtree will not open")
    func sealingIsBoundToThePublisher() throws {
        let vault = Vault.generate()
        let record = try record()
        let sealed = try vault.seal(record: record, publishedBy: macA)

        // Copying a record from one device's area into another's is a write
        // anything with folder access can perform. It must not be believed.
        #expect(throws: Vault.VaultError.cannotOpen) {
            try vault.open(record: sealed, publishedBy: macB, named: vault.name(of: record.id))
        }
    }

    @Test("A record renamed onto another note will not open")
    func sealingIsBoundToTheName() throws {
        let vault = Vault.generate()
        let sealed = try vault.seal(record: try record("17"), publishedBy: macA)

        #expect(throws: Vault.VaultError.cannotOpen) {
            try vault.open(record: sealed, publishedBy: macA, named: vault.name(of: try stickyID("18")))
        }
    }

    @Test("Altered ciphertext does not open")
    func alteredBytesDoNotOpen() throws {
        let vault = Vault.generate()
        let record = try record()
        var sealed = try vault.seal(record: record, publishedBy: macA)

        // Flip a bit somewhere in the middle, where the payload is.
        sealed[sealed.count / 2] ^= 0x01

        #expect(throws: (any Error).self) {
            try vault.open(record: sealed, publishedBy: macA, named: vault.name(of: record.id))
        }
    }

    // MARK: - The wrong key, and no key at all

    @Test("Another vault's key is refused by name, not reported as corruption")
    func aDifferentVaultIsNamed() throws {
        let mine = Vault.generate()
        let theirs = Vault.generate()
        let record = try record()
        let sealed = try theirs.seal(record: record, publishedBy: macA)

        // "Sealed under a different vault" and "this file is damaged" call for
        // completely different responses from whoever reads the message.
        #expect(throws: Vault.VaultError.sealedUnderADifferentKey(found: theirs.keyID, held: mine.keyID)) {
            try mine.open(record: sealed, publishedBy: macA, named: mine.name(of: record.id))
        }
    }

    @Test("A plaintext record from before encryption is refused, not believed")
    func plaintextIsRefused() throws {
        let vault = Vault.generate()
        let plaintext = try record().serialized()

        // Accepting these would leave the injection hole this milestone closes
        // propped open by backward compatibility: anything that can write to the
        // folder can write a plaintext record.
        #expect(throws: Vault.VaultError.notSealed) {
            try vault.open(record: plaintext, publishedBy: macA, named: vault.name(of: try stickyID("17")))
        }
    }

    @Test("Sealed bytes from a newer StickiesSync are refused rather than guessed at")
    func newerFormatsAreRefused() throws {
        let vault = Vault.generate()
        let future = try PropertyListSerialization.data(
            fromPropertyList: PlistValue.dictionary([
                "FormatVersion": .integer(Vault.currentFormatVersion + 1),
                "KeyID": .string(vault.keyID),
                "Sealed": .data(Data([0x00, 0x01])),
            ]).propertyList,
            format: .xml,
            options: 0
        )

        #expect(
            throws: Vault.VaultError.unsupportedFormatVersion(
                found: Vault.currentFormatVersion + 1,
                supported: Vault.currentFormatVersion
            )
        ) {
            try vault.open(record: future, publishedBy: macA, named: vault.name(of: try stickyID("17")))
        }
    }

    // MARK: - Names

    @Test("Both Macs derive the same name for a record without exchanging it")
    func namesAreDerivedNotExchanged() throws {
        let key = SymmetricKey(size: .bits256)
        let id = try stickyID("17")

        #expect(Vault(key: key).name(of: id) == Vault(key: key).name(of: id))
        #expect(Vault(key: key).name(of: id) != Vault(key: key).name(of: try stickyID("18")))
    }

    @Test("A record's name reveals nothing about the note")
    func namesRevealNothing() throws {
        let id = try stickyID("A0000000-0000-0000-0000-000000000001")
        let name = Vault.generate().name(of: id)

        #expect(!name.rawValue.contains("A0000000"))
        #expect(Vault.generate().name(of: id) != Vault.generate().name(of: id))
        // It becomes a filename on every transport that stores files.
        #expect(!name.rawValue.contains("/"))
        #expect(RecordName(rawValue: "../escape") == nil)
        #expect(RecordName(rawValue: "") == nil)
    }

    @Test("A vault names itself without revealing itself")
    func keyIDIsAFingerprint() throws {
        let vault = Vault.generate()

        #expect(vault.keyID.count == 8)
        #expect(vault.keyID != Vault.generate().keyID)
    }
}
