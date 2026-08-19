import CryptoKit
import Foundation
import StickiesFormat
import Testing

@testable import SyncEngine

@Suite("Vault storage")
struct VaultStoreTests {
    /// A store in a directory that is removed afterwards.
    private func withStore(_ body: (FileVaultStore, URL) throws -> Void) throws {
        let root = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "StickiesSyncVault-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appending(path: "vault.plist", directoryHint: .notDirectory)
        try body(FileVaultStore(url: url), url)
    }

    @Test("A Mac with no vault says so rather than inventing one")
    func absentVaultIsNil() throws {
        try withStore { store, _ in
            let vault = try store.vault()
            #expect(vault?.keyID == nil)
        }
    }

    @Test("A stored vault comes back as the same key")
    func vaultSurvivesAReopen() throws {
        try withStore { store, url in
            let vault = Vault.generate()
            try store.setVault(vault)

            #expect(try store.vault()?.keyID == vault.keyID)
            // A second store over the same file stands in for the next run of
            // the agent.
            #expect(try FileVaultStore(url: url).vault()?.keyID == vault.keyID)
        }
    }

    @Test("The vault file is readable only by its owner")
    func vaultFileIsOwnerOnly() throws {
        try withStore { store, url in
            try store.setVault(Vault.generate())

            let attributes = try FileManager.default
                .attributesOfItem(atPath: url.path(percentEncoded: false))
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber)

            #expect(permissions.intValue == 0o600)
        }
    }

    @Test("The identity key is created once and then stays put")
    func identityIsStable() throws {
        try withStore { store, url in
            let first = try store.identityKey()
            let again = try store.identityKey()

            // A pairing request already published names the old public key, so
            // regenerating this would silently invalidate it.
            #expect(first.publicKey.rawRepresentation == again.publicKey.rawRepresentation)
            #expect(
                try FileVaultStore(url: url).identityKey().publicKey.rawRepresentation
                    == first.publicKey.rawRepresentation
            )
        }
    }

    @Test("An identity created before a vault survives the vault arriving")
    func identitySurvivesPairing() throws {
        try withStore { store, _ in
            // The order pairing actually uses: identity first, on a Mac with no
            // vault, then the vault once the grant is accepted.
            let identity = try store.identityKey()
            try store.setVault(Vault.generate())

            #expect(
                try store.identityKey().publicKey.rawRepresentation
                    == identity.publicKey.rawRepresentation
            )
        }
    }

    @Test("A vault file that is not a property list is refused, not overwritten")
    func malformedFileIsRefused() throws {
        try withStore { store, url in
            try Data("not a property list".utf8).write(to: url)

            // Silently replacing it would throw away a key that might only need
            // its permissions fixed — and the notes it can still decrypt.
            #expect(throws: FileVaultStore.StoreError.self) { _ = try store.vault() }
        }
    }

    @Test("A vault file from a newer StickiesSync is refused")
    func newerFileIsRefused() throws {
        try withStore { store, url in
            try PropertyListSerialization
                .data(
                    fromPropertyList: PlistValue.dictionary(["FormatVersion": .integer(99)]).propertyList,
                    format: .xml,
                    options: 0
                )
                .write(to: url)

            #expect(throws: FileVaultStore.StoreError.self) { _ = try store.vault() }
        }
    }
}
