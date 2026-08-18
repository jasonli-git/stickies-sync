import Foundation

/// The replica's schema, applied as a numbered list of migrations.
///
/// Migrations rather than a single `CREATE` script because the replica is a
/// cache the user will carry across versions of this tool, and rebuilding it
/// from scratch would throw away the version history it exists to hold.
enum Schema {
    /// Append-only. Each entry is applied once, in order, and `user_version`
    /// records how far a database has got.
    static let migrations: [String] = [
        """
        -- This Mac's identity in every version vector. One row, ever.
        CREATE TABLE device (
            singleton  INTEGER PRIMARY KEY CHECK (singleton = 0),
            device_id  TEXT NOT NULL,
            name       TEXT NOT NULL
        );

        -- What the replica believes each note currently is. Content and window
        -- state are hashed separately so a note that only moved can be told
        -- apart from one that was edited: Stickies repositions windows on its
        -- own, and that must not read as a content change.
        CREATE TABLE notes (
            sticky_id     TEXT PRIMARY KEY,
            content_hash  TEXT NOT NULL,
            state_hash    TEXT NOT NULL,
            is_deleted    INTEGER NOT NULL DEFAULT 0,
            updated_at    TEXT NOT NULL
        );

        -- Ordering between Macs, one counter per note per device. Never
        -- timestamps: two Macs' clocks always disagree, and comparing them
        -- silently destroys the loser's work.
        CREATE TABLE version_vectors (
            sticky_id  TEXT NOT NULL REFERENCES notes(sticky_id) ON DELETE CASCADE,
            device_id  TEXT NOT NULL,
            seq        INTEGER NOT NULL,
            PRIMARY KEY (sticky_id, device_id)
        );

        -- Retained versions, and the tombstones that make a deleted note
        -- recoverable. `archive` is a single-note NoteArchive, reusing the
        -- format layer's codec rather than inventing a second one; it is NULL
        -- for a deletion, whose content lives in the version before it.
        CREATE TABLE note_versions (
            sticky_id    TEXT NOT NULL REFERENCES notes(sticky_id) ON DELETE CASCADE,
            device_id    TEXT NOT NULL,
            seq          INTEGER NOT NULL,
            archive      BLOB,
            is_deletion  INTEGER NOT NULL DEFAULT 0,
            recorded_at  TEXT NOT NULL,
            PRIMARY KEY (sticky_id, device_id, seq)
        );

        CREATE INDEX note_versions_by_note ON note_versions (sticky_id, recorded_at DESC);
        """,

        """
        -- Which Mac's change produced the note's current state. Needed to
        -- publish a record: a note relayed through this Mac must keep the
        -- originating device, not be re-attributed to whoever passed it on.
        -- Existing rows predate any syncing, so they originated here, and the
        -- empty default is rewritten to this device on the next reconcile.
        ALTER TABLE notes ADD COLUMN origin_device TEXT NOT NULL DEFAULT '';
        """,
    ]

    /// Applies whatever has not been applied yet. Safe to call on every open.
    static func migrate(_ database: Database) throws {
        let current = try database.query("PRAGMA user_version").first?.integer("user_version") ?? 0
        guard current < migrations.count else { return }

        for (index, migration) in migrations.enumerated().dropFirst(current) {
            try database.transaction {
                try database.execute(migration)
                // PRAGMA does not accept a bound parameter, and the value is an
                // array index rather than anything user-supplied.
                try database.execute("PRAGMA user_version = \(index + 1)")
            }
        }
    }
}
