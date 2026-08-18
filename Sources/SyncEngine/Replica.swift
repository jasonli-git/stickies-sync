import Foundation
import StickiesFormat

/// One difference between what the container holds and what the replica
/// believed.
public struct NoteChange: Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        case added
        case edited
        case deleted
        /// A note that had been tombstoned is on disk again.
        case reappeared
    }

    public let id: StickyID
    public let kind: Kind
    public let contentChanged: Bool
    public let windowStateChanged: Bool
    public let version: VersionVector

    /// The note moved or changed colour but its text did not change.
    ///
    /// Worth distinguishing because Stickies repositions windows and renumbers
    /// z-order on its own, so this kind of change can arise with no user action
    /// at all. A transport may reasonably treat it as lower priority than an
    /// edit; nothing here decides that.
    public var isWindowStateOnly: Bool {
        kind == .edited && !contentChanged && windowStateChanged
    }

    public var description: String {
        let detail =
            switch (kind, contentChanged, windowStateChanged) {
            case (.edited, true, true): "edited: text and window"
            case (.edited, true, false): "edited: text"
            case (.edited, false, true): "edited: window only"
            default: kind.rawValue
            }
        return "\(id) \(detail)"
    }
}

/// What the replica believes about one note.
public struct KnownNote: Hashable, Sendable {
    public let id: StickyID
    public let digest: NoteDigest
    public let isDeleted: Bool
    public let updatedAt: Date
    public let version: VersionVector
    /// The Mac whose change produced this state. Not necessarily this Mac: a
    /// note adopted from a peer keeps that peer's identity, which is what stops
    /// a relayed note from being re-attributed on every hop.
    public let origin: DeviceID
}

/// One retained version of a note.
public struct RetainedVersion: Hashable, Sendable {
    public let id: StickyID
    public let deviceID: DeviceID
    public let seq: Int
    public let isDeletion: Bool
    public let recordedAt: Date
    /// The note as it was. `nil` for a deletion, whose content lives in the
    /// version recorded before it.
    public let note: StickyNote?
}

/// The local record of every note this Mac knows about: what it currently is,
/// how it came to be that way, and what it used to be.
///
/// Knows nothing about Macs, containers, or networks — it is handed
/// `[StickyNote]` and hands back what changed. That boundary is what lets
/// Milestone 4 drive it from a transport without the engine learning what a
/// transport is.
public final class Replica {
    /// Versions retained per note before the oldest are dropped. Twenty covers
    /// "I broke this note yesterday" without the database growing without bound.
    public static let defaultVersionRetention = 20

    public let deviceID: DeviceID
    public let deviceName: String

    private let database: Database
    private let versionRetention: Int
    private let now: () -> Date
    private let formatter: ISO8601DateFormatter

    public init(
        database: Database,
        deviceName: String = ProcessInfo.processInfo.hostName,
        versionRetention: Int = defaultVersionRetention,
        now: @escaping () -> Date = Date.init
    ) throws {
        self.database = database
        self.versionRetention = versionRetention
        self.now = now
        self.formatter = Self.makeFormatter()

        try Schema.migrate(database)

        // The device row is written once and never rewritten: every version
        // vector already in the history refers to it.
        if let existing = try database.query("SELECT device_id, name FROM device WHERE singleton = 0").first,
           let id = existing.text("device_id")
        {
            self.deviceID = DeviceID(rawValue: id)
            self.deviceName = existing.text("name") ?? deviceName
        } else {
            let generated = DeviceID.generate()
            try database.run(
                "INSERT INTO device (singleton, device_id, name) VALUES (0, ?, ?)",
                [.text(generated.rawValue), .text(deviceName)]
            )
            self.deviceID = generated
            self.deviceName = deviceName
        }

        // Rows that predate the origin column carry its empty default. They can
        // only have originated here — the column arrived with syncing — but the
        // backfill has to happen after the device row exists, so the migration
        // itself cannot do it. Leaving them empty publishes records with no
        // origin, and the receiving Mac then files every version of that note
        // under sequence zero, each overwriting the last.
        try database.run(
            "UPDATE notes SET origin_device = ? WHERE origin_device = ''",
            [.text(deviceID.rawValue)]
        )
    }

    public static func open(
        at url: URL,
        deviceName: String = ProcessInfo.processInfo.hostName,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) throws -> Replica {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try Replica(
            database: try Database(path: url.path(percentEncoded: false)),
            deviceName: deviceName,
            now: now
        )
    }

    // MARK: - Reconciliation

    /// Compares the container's notes against what the replica believed, records
    /// every difference, and returns them.
    ///
    /// Recording and reporting are one operation on purpose. A caller that could
    /// ask "what changed?" without committing the answer would eventually ask
    /// twice and act twice, and the whole point of the replica is that a change
    /// is observed exactly once.
    @discardableResult
    public func reconcile(with notes: [StickyNote]) throws -> [NoteChange] {
        try database.transaction {
            let timestamp = now()
            var known = try knownNotesByID()
            var changes: [NoteChange] = []

            for note in notes.sorted(by: { $0.id < $1.id }) {
                let digest = NoteDigest(note)
                let existing = known.removeValue(forKey: note.id)

                let kind: NoteChange.Kind
                let contentChanged: Bool
                let windowStateChanged: Bool

                if let existing {
                    contentChanged = existing.digest.content != digest.content
                    windowStateChanged = existing.digest.state != digest.state
                    if existing.isDeleted {
                        kind = .reappeared
                    } else if !contentChanged && !windowStateChanged {
                        continue
                    } else {
                        kind = .edited
                    }
                } else {
                    kind = .added
                    contentChanged = true
                    windowStateChanged = note.windowState != nil
                }

                try upsertNote(note.id, digest: digest, isDeleted: false, origin: deviceID, at: timestamp)
                let version = try bumpVersion(of: note.id, from: existing?.version)
                try recordVersion(note.id, seq: version[deviceID], note: note, isDeletion: false, at: timestamp)

                changes.append(
                    NoteChange(
                        id: note.id,
                        kind: kind,
                        contentChanged: contentChanged,
                        windowStateChanged: windowStateChanged,
                        version: version
                    )
                )
            }

            // Whatever is left in `known` was not on disk. A note already
            // tombstoned stays tombstoned rather than being reported again.
            for (id, existing) in known.sorted(by: { $0.key < $1.key }) where !existing.isDeleted {
                try upsertNote(id, digest: existing.digest, isDeleted: true, origin: deviceID, at: timestamp)
                let version = try bumpVersion(of: id, from: existing.version)
                try recordVersion(id, seq: version[deviceID], note: nil, isDeletion: true, at: timestamp)

                changes.append(
                    NoteChange(
                        id: id,
                        kind: .deleted,
                        contentChanged: false,
                        windowStateChanged: false,
                        version: version
                    )
                )
            }

            for change in changes {
                try pruneVersions(of: change.id)
            }
            return changes
        }
    }

    // MARK: - Integrating a peer's version

    /// Records a version that came from somewhere else, under *its* identity.
    ///
    /// This is the method Milestone 3 was missing, and the reason two Macs can
    /// converge at all. `reconcile` bumps this Mac's counter because everything
    /// it sees originated here; integration must do the opposite and take the
    /// vector wholesale. Bumping the local counter here would restamp every
    /// arriving note as a local edit, so each Mac would keep telling the other
    /// about changes the other had just made, and the two would never settle.
    ///
    /// `note` is `nil` to leave this Mac's content alone and only advance the
    /// vector — what a concurrent resolution needs when the local content won.
    public func integrate(
        id: StickyID,
        note: StickyNote?,
        isDeleted: Bool,
        version: VersionVector,
        origin: DeviceID,
        recordedAt: Date? = nil
    ) throws {
        try database.transaction {
            let timestamp = recordedAt ?? now()
            let existing = try knownNote(id)

            let digest: NoteDigest =
                if let note {
                    NoteDigest(note)
                } else if let existing {
                    existing.digest
                } else {
                    // Nothing to describe: a deletion for a note this Mac has
                    // never held. Recorded so the tombstone still propagates.
                    NoteDigest(content: "", state: "")
                }

            try upsertNote(id, digest: digest, isDeleted: isDeleted, origin: origin, at: timestamp)
            try replaceVersionVector(of: id, with: version)

            // Only when there is something to retain. A resolution that keeps
            // this Mac's content and merely advances the vector has no new
            // version to record — and writing one would be actively destructive,
            // because the history row it would land on is keyed by
            // (note, device, seq) and already holds that content. Recording an
            // empty version there erases it, and the Mac then publishes whatever
            // older version is left, quietly overwriting the peer's correct copy
            // with stale text.
            if note != nil || isDeleted {
                try recordVersion(
                    id,
                    device: origin,
                    seq: version[origin],
                    note: note,
                    isDeletion: isDeleted,
                    at: timestamp
                )
                try pruneVersions(of: id)
            }
        }
    }

    public func integrate(_ record: SyncRecord) throws {
        try integrate(
            id: record.id,
            note: record.note,
            isDeleted: record.isDeletion,
            version: record.version,
            origin: record.origin,
            recordedAt: record.recordedAt
        )
    }

    /// Everything this Mac knows, in publishable form.
    ///
    /// A note whose content is no longer retained is skipped rather than
    /// published as an empty one — publishing a note with no content would tell
    /// peers to overwrite theirs with nothing.
    public func localRecords() throws -> [SyncRecord] {
        try knownNotes().compactMap { known in
            let note = known.isDeleted ? nil : try newestRecoverableVersion(of: known.id)?.note
            guard known.isDeleted || note != nil else { return nil }
            return SyncRecord(
                id: known.id,
                origin: known.origin,
                version: known.version,
                isDeletion: known.isDeleted,
                note: note,
                recordedAt: known.updatedAt
            )
        }
    }

    public func localRecord(_ id: StickyID) throws -> SyncRecord? {
        try localRecords().first { $0.id == id }
    }

    public func manifest(publishedAt: Date? = nil) throws -> DeviceManifest {
        DeviceManifest(
            device: deviceID,
            deviceName: deviceName,
            publishedAt: publishedAt ?? now(),
            entries: try knownNotes().map {
                DeviceManifest.Entry(id: $0.id, version: $0.version, isDeletion: $0.isDeleted)
            }
        )
    }

    // MARK: - Reading

    public func knownNotes() throws -> [KnownNote] {
        try database.query(
            """
            SELECT sticky_id, content_hash, state_hash, is_deleted, updated_at, origin_device
            FROM notes ORDER BY sticky_id
            """
        )
        .compactMap { row in
            guard let raw = row.text("sticky_id"), let id = StickyID(rawValue: raw) else { return nil }
            return KnownNote(
                id: id,
                digest: NoteDigest(
                    content: row.text("content_hash") ?? "",
                    state: row.text("state_hash") ?? ""
                ),
                isDeleted: row.bool("is_deleted"),
                updatedAt: date(row.text("updated_at")),
                version: try versionVector(of: id),
                origin: DeviceID(rawValue: row.text("origin_device") ?? deviceID.rawValue)
            )
        }
    }

    public func knownNote(_ id: StickyID) throws -> KnownNote? {
        try knownNotes().first { $0.id == id }
    }

    /// Newest first.
    public func versions(of id: StickyID) throws -> [RetainedVersion] {
        try database.query(
            """
            SELECT sticky_id, device_id, seq, archive, is_deletion, recorded_at
            FROM note_versions WHERE sticky_id = ? ORDER BY recorded_at DESC, seq DESC
            """,
            [.text(id.rawValue)]
        )
        .compactMap { row in
            guard let raw = row.text("sticky_id"), let stickyID = StickyID(rawValue: raw),
                  let device = row.text("device_id"), let seq = row.integer("seq")
            else { return nil }

            let archive = row.blob("archive")
            return RetainedVersion(
                id: stickyID,
                deviceID: DeviceID(rawValue: device),
                seq: seq,
                isDeletion: row.bool("is_deletion"),
                recordedAt: date(row.text("recorded_at")),
                note: try archive.flatMap { try NoteArchive(data: $0).notes.first }
            )
        }
    }

    /// The newest retained version that has content — what "put this note back"
    /// means, including for a note that has been deleted.
    public func newestRecoverableVersion(of id: StickyID) throws -> RetainedVersion? {
        try versions(of: id).first { $0.note != nil }
    }

    /// Notes the replica has tombstoned and can still put back.
    public func recoverableDeletedNotes() throws -> [KnownNote] {
        try knownNotes().filter(\.isDeleted)
    }

    // MARK: - Writing helpers

    private func knownNotesByID() throws -> [StickyID: KnownNote] {
        Dictionary(uniqueKeysWithValues: try knownNotes().map { ($0.id, $0) })
    }

    private func versionVector(of id: StickyID) throws -> VersionVector {
        var counters: [DeviceID: Int] = [:]
        for row in try database.query(
            "SELECT device_id, seq FROM version_vectors WHERE sticky_id = ?",
            [.text(id.rawValue)]
        ) {
            guard let device = row.text("device_id"), let seq = row.integer("seq") else { continue }
            counters[DeviceID(rawValue: device)] = seq
        }
        return VersionVector(counters: counters)
    }

    /// Milestone 3 only ever increments this Mac's counter: every change it sees
    /// originated here. Merging a peer's vector is Milestone 4.
    private func bumpVersion(of id: StickyID, from existing: VersionVector?) throws -> VersionVector {
        var version = existing ?? VersionVector()
        version.increment(deviceID)
        try database.run(
            """
            INSERT INTO version_vectors (sticky_id, device_id, seq) VALUES (?, ?, ?)
            ON CONFLICT (sticky_id, device_id) DO UPDATE SET seq = excluded.seq
            """,
            [.text(id.rawValue), .text(deviceID.rawValue), .integer(version[deviceID])]
        )
        return version
    }

    /// Always called before `bumpVersion` and `recordVersion`: both reference
    /// this row, and the schema's foreign keys are checked per statement rather
    /// than deferred to the end of the transaction.
    /// Replaces every counter, which is what integrating a peer's version means:
    /// the peer's vector already includes whatever it knew of ours.
    private func replaceVersionVector(of id: StickyID, with version: VersionVector) throws {
        try database.run("DELETE FROM version_vectors WHERE sticky_id = ?", [.text(id.rawValue)])
        for (device, seq) in version.counters.sorted(by: { $0.key < $1.key }) {
            try database.run(
                "INSERT INTO version_vectors (sticky_id, device_id, seq) VALUES (?, ?, ?)",
                [.text(id.rawValue), .text(device.rawValue), .integer(seq)]
            )
        }
    }

    private func upsertNote(
        _ id: StickyID,
        digest: NoteDigest,
        isDeleted: Bool,
        origin: DeviceID,
        at timestamp: Date
    ) throws {
        try database.run(
            """
            INSERT INTO notes (sticky_id, content_hash, state_hash, is_deleted, updated_at, origin_device)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (sticky_id) DO UPDATE SET
                content_hash = excluded.content_hash,
                state_hash = excluded.state_hash,
                is_deleted = excluded.is_deleted,
                updated_at = excluded.updated_at,
                origin_device = excluded.origin_device
            """,
            [
                .text(id.rawValue), .text(digest.content), .text(digest.state),
                .integer(isDeleted ? 1 : 0), .text(string(timestamp)), .text(origin.rawValue),
            ]
        )
    }

    private func recordVersion(
        _ id: StickyID,
        device: DeviceID? = nil,
        seq: Int,
        note: StickyNote?,
        isDeletion: Bool,
        at timestamp: Date
    ) throws {
        let device = device ?? deviceID
        let archive = try note.map { try NoteArchive(notes: [$0]).serialized() }
        try database.run(
            """
            INSERT INTO note_versions (sticky_id, device_id, seq, archive, is_deletion, recorded_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (sticky_id, device_id, seq) DO UPDATE SET
                archive = excluded.archive,
                is_deletion = excluded.is_deletion,
                recorded_at = excluded.recorded_at
            """,
            [
                .text(id.rawValue), .text(device.rawValue), .integer(seq),
                archive.map { Database.Value.blob($0) } ?? .null,
                .integer(isDeletion ? 1 : 0), .text(string(timestamp)),
            ]
        )
    }

    private func pruneVersions(of id: StickyID) throws {
        try database.run(
            """
            DELETE FROM note_versions
            WHERE sticky_id = ? AND rowid NOT IN (
                SELECT rowid FROM note_versions WHERE sticky_id = ?
                ORDER BY recorded_at DESC, seq DESC LIMIT ?
            )
            """,
            [.text(id.rawValue), .text(id.rawValue), .integer(versionRetention)]
        )
    }

    // MARK: - Timestamps

    /// ISO 8601 with fractional seconds, so the string sorts chronologically —
    /// which is what the history queries order by. The timestamps are
    /// informational; ordering between Macs comes from version vectors.
    ///
    /// An instance property rather than a static one: `ISO8601DateFormatter` is
    /// not `Sendable`, and a replica is single-threaded by construction, so
    /// owning one is honest where a shared global would not be.
    private static func makeFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private func string(_ date: Date) -> String {
        formatter.string(from: date)
    }

    private func date(_ string: String?) -> Date {
        string.flatMap { formatter.date(from: $0) } ?? Date(timeIntervalSince1970: 0)
    }
}
