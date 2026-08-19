import Foundation
import StickiesFormat

/// Notes in, blobs out. The only path from the sync logic to a transport.
///
/// Encryption is not a mode this can be run without: a channel cannot be built
/// without a `Vault`, and `SyncService` cannot reach a transport except through
/// a channel. SPEC.md F13 asks that a transport the user does not control never
/// sees plaintext, and the type system is a better place to keep that promise
/// than a flag someone forgets to set.
///
/// It is also where an unopenable peer stops. Sealed bytes that were not written
/// under this vault's key fail to open, so a `devices/` subtree published by
/// anything that lacks the key is reported and skipped rather than believed —
/// which is the second half of what this milestone is for. Such a peer cannot
/// even tell us its name: the name is inside the ciphertext.
public struct SealedChannel: Sendable {
    /// Why a peer's published bytes were not usable.
    public struct Unopened: Hashable, Sendable {
        public let device: DeviceID
        public let reason: String
    }

    public struct PeerReading: Sendable {
        public var manifests: [DeviceManifest] = []
        public var unopened: [Unopened] = []
    }

    /// What came back for one advertised record.
    public enum Fetched: Sendable {
        case arrived(SyncRecord)
        /// Advertised but not on disk yet — normal while the folder is copying.
        case notLandedYet
        case unreadable(String)
    }

    private let transport: any SyncTransport
    private let vault: Vault
    private let device: DeviceID

    public init(transport: any SyncTransport, vault: Vault, device: DeviceID) {
        self.transport = transport
        self.vault = vault
        self.device = device
    }

    public var vaultID: String { vault.keyID }

    public func publish(manifest: DeviceManifest, records: [SyncRecord]) throws {
        var sealed: [RecordName: Data] = [:]
        for record in records {
            sealed[vault.name(of: record.id)] = try vault.seal(record: record, publishedBy: device)
        }
        try transport.publish(
            manifest: try vault.seal(manifest: manifest, publishedBy: device),
            records: sealed
        )
    }

    /// Every peer's manifest that this vault can open, and every one it cannot.
    ///
    /// One peer failing never stops the others: a Mac that has not been paired
    /// yet, or one still publishing the plaintext records that predate
    /// encryption, must not take the rest of the folder down with it.
    public func peerManifests() throws -> PeerReading {
        var reading = PeerReading()
        for published in try transport.peerManifests(excluding: device) {
            do {
                reading.manifests.append(
                    try vault.open(manifest: published.bytes, publishedBy: published.device)
                )
            } catch {
                reading.unopened.append(
                    Unopened(device: published.device, reason: String(describing: error))
                )
            }
        }
        return reading
    }

    public func record(_ id: StickyID, from peer: DeviceID) throws -> Fetched {
        let name = vault.name(of: id)
        guard let data = try transport.record(name, from: peer) else { return .notLandedYet }
        do {
            return .arrived(try vault.open(record: data, publishedBy: peer, named: name))
        } catch {
            return .unreadable(String(describing: error))
        }
    }
}
