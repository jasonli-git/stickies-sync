import CryptoKit
import Foundation
import StickiesFormat

/// What should happen to one note, given what this Mac holds and what a peer
/// advertises.
public struct Resolution: Hashable, Sendable {
    /// The record whose content should end up at the original identifier.
    /// `nil` means this Mac's content stays as it is.
    public var adopt: SyncRecord?
    /// The vector the note ends up carrying. On a concurrent resolution this is
    /// the merge of both sides, which is what stops the peers from rediscovering
    /// the same conflict on every pass.
    public var version: VersionVector
    /// A second note to create, holding the content that lost the identifier.
    public var conflictCopy: SyncRecord?

    public init(adopt: SyncRecord?, version: VersionVector, conflictCopy: SyncRecord? = nil) {
        self.adopt = adopt
        self.version = version
        self.conflictCopy = conflictCopy
    }
}

/// The heart of the milestone, and the part that has to be right.
///
/// Two Macs never talk to each other: each sees the same pair of records and
/// decides alone. Every choice here is therefore a pure function of the two
/// records — no clocks read at decision time, no random identifiers, no
/// dependence on which Mac is asking. A single non-deterministic choice and the
/// two Macs disagree permanently, each creating conflict copies of the other's
/// conflict copies.
public enum MergeDecision {
    /// `nil` when there is nothing to do.
    public static func resolve(local: SyncRecord?, remote: SyncRecord) -> Resolution? {
        guard let local else {
            // Never seen this note. Adopt it exactly as the peer has it.
            return Resolution(adopt: remote, version: remote.version)
        }

        switch local.version.ordering(against: remote.version) {
        case .equal, .descendant:
            return nil
        case .ancestor:
            return Resolution(adopt: remote, version: remote.version)
        case .concurrent:
            return resolveConcurrent(local: local, remote: remote)
        }
    }

    private static func resolveConcurrent(local: SyncRecord, remote: SyncRecord) -> Resolution {
        let merged = local.version.merged(with: remote.version)

        // Deletion against an edit: the edit wins, always. SPEC.md's first
        // principle is that a note is never lost, and a tombstone has nothing to
        // preserve — so this is not a conflict worth showing anyone, and no copy
        // is made. The cost is that deleting a note on one Mac while editing it
        // on another resurrects it; that is the intended direction to fail in.
        switch (local.isDeletion, remote.isDeletion) {
        case (true, true):
            return Resolution(adopt: nil, version: merged)
        case (false, true):
            return Resolution(adopt: nil, version: merged)
        case (true, false):
            return Resolution(adopt: remote, version: merged)
        case (false, false):
            break
        }

        // Both sides have content. One keeps the identifier; the other becomes a
        // new note. Which is which must not depend on who is asking.
        let remoteWins = isLater(remote, than: local)
        let loser = remoteWins ? local : remote

        return Resolution(
            adopt: remoteWins ? remote : nil,
            version: merged,
            conflictCopy: conflictCopy(of: loser, from: local.id)
        )
    }

    /// Last writer wins, with the origin device as the tiebreak.
    ///
    /// The timestamp is the "last writer" part, and it is the one place a clock
    /// influences anything — deliberately, because a conflict is a tie and
    /// something has to break it. Nothing is lost when it breaks the wrong way:
    /// the other version becomes a conflict copy. The device identifier is what
    /// makes the answer identical on both Macs when the timestamps match.
    private static func isLater(_ candidate: SyncRecord, than other: SyncRecord) -> Bool {
        if candidate.recordedAt != other.recordedAt {
            return candidate.recordedAt > other.recordedAt
        }
        return candidate.origin > other.origin
    }

    /// The losing content, under an identifier both Macs derive identically.
    ///
    /// It keeps the loser's own vector rather than getting a fresh one. If each
    /// Mac stamped the copy with its own new version, the two copies would be
    /// concurrent and would immediately conflict with each other — a conflict
    /// copy of a conflict copy, forever.
    public static func conflictCopy(of loser: SyncRecord, from original: StickyID) -> SyncRecord {
        SyncRecord(
            id: conflictCopyID(of: loser, from: original),
            origin: loser.origin,
            version: loser.version,
            isDeletion: false,
            note: loser.note.map { note in
                var copy = note
                copy.id = conflictCopyID(of: loser, from: original)
                copy.windowState = markAsConflictCopy(note.windowState, id: copy.id)
                return copy
            },
            recordedAt: loser.recordedAt
        )
    }

    /// A UUID derived from the original identifier and the losing version, so
    /// both Macs name the copy the same thing without coordinating.
    public static func conflictCopyID(of loser: SyncRecord, from original: StickyID) -> StickyID {
        let seed = "conflict:\(original.rawValue):\(loser.origin.rawValue):\(canonical(loser.version))"
        let digest = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))

        // Stamped as a version-4 UUID so it is indistinguishable from a real one
        // to Stickies, which only ever treats these as opaque names.
        var bytes = digest
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return StickyID(uuid: uuid)
    }

    private static func canonical(_ version: VersionVector) -> String {
        version.counters
            .sorted { $0.key < $1.key }
            .map { "\($0.key.rawValue)=\($0.value)" }
            .joined(separator: ",")
    }

    /// A conflict copy is marked by appearance, never by editing the note.
    ///
    /// SPEC.md requires the copy be *marked*, and the obvious way — prepending a
    /// "CONFLICT COPY" line to the text — was rejected: building that line means
    /// re-serializing rich text, which produces different bytes on different
    /// Macs, so the two copies would differ and immediately conflict with each
    /// other. A colour and an offset are exact numbers that both Macs write
    /// identically, and they are visible the moment the note appears.
    public static let conflictCopyColor = StickyColor(red: 1, green: 0.6, blue: 0.6)
    public static let conflictCopyOffset = CGSize(width: 24, height: -24)

    private static func markAsConflictCopy(
        _ state: StickyWindowState?,
        id: StickyID
    ) -> StickyWindowState? {
        guard var state else { return nil }
        state.id = id
        state.palette = StickyPalette(sticky: conflictCopyColor)
        state.frame = state.frame.offsetBy(
            dx: conflictCopyOffset.width,
            dy: conflictCopyOffset.height
        )
        // Z-order is Stickies' to assign and would only be a stale number here.
        state.zOrder = nil
        return state
    }
}
