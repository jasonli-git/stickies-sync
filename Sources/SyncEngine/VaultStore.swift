import CryptoKit
import Foundation
import StickiesFormat

/// Where a Mac keeps the two secrets it needs: the vault key it shares with its
/// peers, and the identity keypair that pairing uses to get that key onto a new
/// Mac.
///
/// A protocol because "where does the key live" is a decision worth being able
/// to revisit — the login Keychain is the obvious other answer (#54).
public protocol VaultStore: Sendable {
    /// `nil` when this Mac has not been given a vault yet.
    func vault() throws -> Vault?
    func setVault(_ vault: Vault) throws
    /// This Mac's pairing identity, created and persisted the first time it is
    /// asked for. Stable afterwards: a pending pairing request published under
    /// the old public key would stop matching.
    func identityKey() throws -> Curve25519.KeyAgreement.PrivateKey
}

/// Both secrets in one owner-only file.
///
/// Chosen over the Keychain deliberately (#54). Anything that can read this file
/// can already read the plaintext notes it protects — Stickies' own container is
/// two directories away and is not encrypted by anyone — so a file is not a
/// weaker position than the thing being protected. What it avoids is real: an
/// unsigned command-line tool's Keychain access is bound to the binary, so every
/// rebuild can raise an authorization prompt, including for the background agent
/// where there is nobody to answer it.
public struct FileVaultStore: VaultStore {
    public enum StoreError: Error, CustomStringConvertible {
        case cannotWrite(path: String, underlying: String)
        case malformed(path: String, detail: String)

        public var description: String {
            switch self {
            case .cannotWrite(let path, let underlying):
                "cannot write the vault file \(path): \(underlying)"
            case .malformed(let path, let detail):
                "the vault file \(path) is malformed: \(detail) — "
                    + "pair this Mac again, or run `stickiesctl vault reset`"
            }
        }
    }

    private static let currentFormatVersion = 1

    private enum Key {
        static let formatVersion = "FormatVersion"
        static let vaultKey = "VaultKey"
        static let identity = "Identity"
    }

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func vault() throws -> Vault? {
        guard let entry = try read() else { return nil }
        guard case .data(let raw)? = entry[Key.vaultKey] else { return nil }
        guard raw.count == 32 else {
            throw StoreError.malformed(path: path, detail: "the vault key is \(raw.count) bytes, not 32")
        }
        return Vault(key: SymmetricKey(data: raw))
    }

    public func setVault(_ vault: Vault) throws {
        var entry = try read() ?? [:]
        entry[Key.vaultKey] = .data(vault.rawKey.withUnsafeBytes { Data($0) })
        try write(entry)
    }

    public func identityKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        var entry = try read() ?? [:]

        if case .data(let raw)? = entry[Key.identity] {
            do {
                return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
            } catch {
                throw StoreError.malformed(path: path, detail: "the identity key is unusable")
            }
        }

        let generated = Curve25519.KeyAgreement.PrivateKey()
        entry[Key.identity] = .data(generated.rawRepresentation)
        try write(entry)
        return generated
    }

    // MARK: - The file

    private var path: String { url.path(percentEncoded: false) }

    private func read() throws -> [String: PlistValue]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let plist = try? PlistValue(propertyList: object),
              let entry = plist.dictionaryValue
        else {
            throw StoreError.malformed(path: path, detail: "it is not a property list")
        }
        guard let version = entry[Key.formatVersion]?.intValue, version <= Self.currentFormatVersion else {
            throw StoreError.malformed(
                path: path,
                detail: "it was written by a newer StickiesSync"
            )
        }
        return entry
    }

    /// Created owner-only *before* any secret goes into it, then moved into
    /// place. Writing first and fixing the mode afterwards would leave the key
    /// world-readable for as long as that takes.
    private func write(_ entry: [String: PlistValue]) throws {
        var entry = entry
        entry[Key.formatVersion] = .integer(Self.currentFormatVersion)

        let fileManager = FileManager.default
        let data = try PropertyListSerialization.data(
            fromPropertyList: PlistValue.dictionary(entry).propertyList,
            format: .xml,
            options: 0
        )

        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let temporary = url.appendingPathExtension("new")
            try? fileManager.removeItem(at: temporary)
            guard fileManager.createFile(
                atPath: temporary.path(percentEncoded: false),
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw StoreError.cannotWrite(path: path, underlying: "could not create a temporary file")
            }

            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            // replaceItemAt may carry the replaced file's metadata over, so the
            // mode is asserted again rather than assumed.
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.cannotWrite(path: path, underlying: error.localizedDescription)
        }
    }
}
