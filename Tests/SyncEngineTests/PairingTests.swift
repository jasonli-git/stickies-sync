import CryptoKit
import Foundation
import StickiesFormat
import Testing

@testable import SyncEngine

@Suite("Pairing")
struct PairingTests {
    private let macA = DeviceID(rawValue: "AAAAAAAA-0000-0000-0000-000000000001")
    private let macB = DeviceID(rawValue: "BBBBBBBB-0000-0000-0000-000000000002")
    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private func request(
        _ device: DeviceID,
        named name: String = "mac-b",
        key: Curve25519.KeyAgreement.PrivateKey
    ) -> PairingRequest {
        PairingRequest(
            device: device,
            deviceName: name,
            publicKey: key.publicKey.rawRepresentation,
            requestedAt: epoch
        )
    }

    // MARK: - The code

    @Test("A code is twelve characters in three groups, and stable")
    func codeIsStable() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let request = request(macB, key: key)

        #expect(request.code.count == 14)
        #expect(request.code.split(separator: "-").count == 3)
        #expect(request.code == Pairing.code(for: macB, publicKey: key.publicKey.rawRepresentation))
        // No characters people confuse when copying between two screens.
        #expect(!request.code.contains(where: { "01IO".contains($0) }))
    }

    @Test("A substituted public key changes the code")
    func codeCoversThePublicKey() throws {
        let mine = request(macB, key: Curve25519.KeyAgreement.PrivateKey())
        let substituted = request(macB, key: Curve25519.KeyAgreement.PrivateKey())

        // The attack: rewrite someone's request with your own key and be handed
        // the vault. The code is what the person compares, so it has to move.
        #expect(mine.code != substituted.code)
    }

    @Test("A request claiming a different device changes the code")
    func codeCoversTheDevice() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()

        #expect(request(macA, key: key).code != request(macB, key: key).code)
    }

    @Test("Dashes, case and stray spaces do not stop a code matching")
    func codesMatchLoosely() throws {
        #expect(Pairing.codesMatch("K7Q2-9F1M-3XZW", "k7q29f1m3xzw"))
        #expect(Pairing.codesMatch("K7Q2-9F1M-3XZW", "  K7Q2 9F1M 3XZW "))
        #expect(!Pairing.codesMatch("K7Q2-9F1M-3XZW", "K7Q2-9F1M-3XZX"))
        // An empty typed code is not a match for anything.
        #expect(!Pairing.codesMatch("K7Q2-9F1M-3XZW", ""))
        #expect(!Pairing.codesMatch("", ""))
    }

    // MARK: - Granting

    @Test("A granted vault arrives as the same vault")
    func grantCarriesTheVault() throws {
        let vault = Vault.generate()
        let granter = Curve25519.KeyAgreement.PrivateKey()
        let joiner = Curve25519.KeyAgreement.PrivateKey()

        let grant = try Pairing.grant(
            vault,
            to: request(macB, key: joiner),
            from: macA,
            named: "mac-a",
            using: granter
        )
        let received = try Pairing.accept(grant, as: macB, using: joiner)

        #expect(received.keyID == vault.keyID)
        // Same key, so the same sealed bytes open on the other side.
        let record = SyncRecord(
            id: try stickyID("17"),
            origin: macA,
            version: VersionVector(counters: [macA: 1]),
            isDeletion: false,
            note: try note("17", text: "Shared"),
            recordedAt: epoch
        )
        let sealed = try vault.seal(record: record, publishedBy: macA)
        #expect(try received.open(record: sealed, publishedBy: macA, named: received.name(of: record.id)) == record)
    }

    @Test("The vault key is not in the grant in the clear")
    func grantHidesTheKey() throws {
        let vault = Vault.generate()
        let grant = try Pairing.grant(
            vault,
            to: request(macB, key: Curve25519.KeyAgreement.PrivateKey()),
            from: macA,
            named: "mac-a",
            using: Curve25519.KeyAgreement.PrivateKey()
        )

        let raw = vault.rawKey.withUnsafeBytes { Data($0) }
        #expect(!grant.sealed.contains(raw))
        #expect(!(try grant.serialized()).contains(raw))
    }

    @Test("A grant written for one Mac cannot be opened by another")
    func grantIsBoundToTheJoiner() throws {
        let joiner = Curve25519.KeyAgreement.PrivateKey()
        let grant = try Pairing.grant(
            Vault.generate(),
            to: request(macB, key: joiner),
            from: macA,
            named: "mac-a",
            using: Curve25519.KeyAgreement.PrivateKey()
        )

        #expect(throws: Pairing.PairingError.cannotUnwrap) {
            try Pairing.accept(grant, as: macB, using: Curve25519.KeyAgreement.PrivateKey())
        }
    }

    @Test("A grant claimed by a different Mac's identifier does not open")
    func grantIsBoundToTheDevice() throws {
        let joiner = Curve25519.KeyAgreement.PrivateKey()
        let grant = try Pairing.grant(
            Vault.generate(),
            to: request(macB, key: joiner),
            from: macA,
            named: "mac-a",
            using: Curve25519.KeyAgreement.PrivateKey()
        )

        #expect(throws: Pairing.PairingError.cannotUnwrap) {
            try Pairing.accept(grant, as: macA, using: joiner)
        }
    }

    @Test("An altered grant does not open")
    func alteredGrantDoesNotOpen() throws {
        let joiner = Curve25519.KeyAgreement.PrivateKey()
        let grant = try Pairing.grant(
            Vault.generate(),
            to: request(macB, key: joiner),
            from: macA,
            named: "mac-a",
            using: Curve25519.KeyAgreement.PrivateKey()
        )

        var sealed = grant.sealed
        sealed[sealed.count / 2] ^= 0x01
        let tampered = PairingGrant(
            device: grant.device,
            deviceName: grant.deviceName,
            publicKey: grant.publicKey,
            keyID: grant.keyID,
            sealed: sealed
        )

        #expect(throws: Pairing.PairingError.cannotUnwrap) {
            try Pairing.accept(tampered, as: macB, using: joiner)
        }
    }

    // MARK: - Serialization

    @Test("A request and a grant round-trip through the folder's format")
    func pairingFilesRoundTrip() throws {
        let joiner = Curve25519.KeyAgreement.PrivateKey()
        let original = request(macB, key: joiner)
        let restored = try PairingRequest(data: try original.serialized())

        #expect(restored == original)
        #expect(restored.code == original.code)

        let grant = try Pairing.grant(
            Vault.generate(),
            to: original,
            from: macA,
            named: "mac-a",
            using: Curve25519.KeyAgreement.PrivateKey()
        )
        #expect(try PairingGrant(data: try grant.serialized()) == grant)
    }

    @Test("A pairing file from a newer StickiesSync is refused")
    func newerPairingFilesAreRefused() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: PlistValue.dictionary([
                "FormatVersion": .integer(Pairing.currentFormatVersion + 1),
                "Device": .string(macB.rawValue),
                "PublicKey": .data(Data(repeating: 0, count: 32)),
            ]).propertyList,
            format: .xml,
            options: 0
        )

        #expect(throws: Pairing.PairingError.self) { try PairingRequest(data: data) }
    }

    // MARK: - Over a folder

    @Test("A request and its grant travel through the folder and are cleaned up")
    func pairingOverAFolder() throws {
        let root = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "StickiesSyncPairing-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let joining = FolderTransport(root: root, device: macB)
        let granting = FolderTransport(root: root, device: macA)
        let joiner = Curve25519.KeyAgreement.PrivateKey()

        try joining.publish(request: request(macB, key: joiner))
        let pending = try granting.pendingRequests()
        #expect(pending.map(\.device) == [macB])

        let vault = Vault.generate()
        let grant = try Pairing.grant(
            vault,
            to: try #require(pending.first),
            from: macA,
            named: "mac-a",
            using: Curve25519.KeyAgreement.PrivateKey()
        )
        try granting.publish(grant: grant, answering: macB)

        let received = try #require(try joining.grants(for: macB).first)
        #expect(try Pairing.accept(received, as: macB, using: joiner).keyID == vault.keyID)

        try joining.forgetPairing(of: macB)
        #expect(try granting.pendingRequests().isEmpty)
        #expect(try joining.grants(for: macB).isEmpty)
    }
}
