import CoreGraphics
import Foundation
import StickiesFormat
import Testing

@testable import SyncEngine

@Suite("Replica")
struct ReplicaTests {
    /// A clock the tests advance by hand, so retained versions get distinct,
    /// ordered timestamps without any sleeping.
    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_770_000_000)

        func now() -> Date { lock.withLock { current } }

        func advance(_ seconds: TimeInterval = 1) {
            lock.withLock { current = current.addingTimeInterval(seconds) }
        }
    }

    private func makeReplica(
        clock: TestClock = TestClock(),
        versionRetention: Int = Replica.defaultVersionRetention
    ) throws -> Replica {
        try Replica(
            database: try Database.inMemory(),
            deviceName: "test-mac",
            versionRetention: versionRetention,
            now: clock.now
        )
    }

    // MARK: - Identity and migration

    @Test("A replica keeps one device identity across reopens")
    func deviceIdentityIsStable() throws {
        let database = try Database.inMemory()
        let first = try Replica(database: database, deviceName: "test-mac")
        let second = try Replica(database: database, deviceName: "renamed")

        // Every version vector already written refers to it, so it must not be
        // regenerated.
        #expect(second.deviceID == first.deviceID)
        #expect(second.deviceName == "test-mac")
    }

    @Test("Migrating an already-migrated database is a no-op")
    func migrationIsIdempotent() throws {
        let database = try Database.inMemory()
        _ = try Replica(database: database)
        _ = try Replica(database: database)

        #expect(try database.query("PRAGMA user_version").first?.integer("user_version") == 1)
    }

    // MARK: - Classification

    @Test("A container seen for the first time reports every note as added")
    func firstScanReportsAdditions() throws {
        let replica = try makeReplica()

        let changes = try replica.reconcile(with: [try note("17"), try note("18")])

        #expect(changes.map(\.kind) == [.added, .added])
        #expect(changes.map(\.id.rawValue) == ["17", "18"])
        #expect(changes.allSatisfy { $0.version[replica.deviceID] == 1 })
    }

    @Test("Scanning an unchanged container reports nothing")
    func unchangedContainerReportsNothing() throws {
        let replica = try makeReplica()
        let notes = [try note("17"), try note("18")]
        _ = try replica.reconcile(with: notes)

        // The property the watcher depends on: FSEvents fires for reasons that
        // are not edits, and a scan must be free to run at any time.
        #expect(try replica.reconcile(with: notes).isEmpty)
        #expect(try replica.reconcile(with: notes).isEmpty)
    }

    @Test("Editing the text reports a content change and bumps the version")
    func detectsAContentEdit() throws {
        let clock = TestClock()
        let replica = try makeReplica(clock: clock)
        _ = try replica.reconcile(with: [try note("17", text: "Milk")])
        clock.advance()

        let changes = try replica.reconcile(with: [try note("17", text: "Milk and eggs")])

        let change = try #require(changes.first)
        #expect(change.kind == .edited)
        #expect(change.contentChanged)
        #expect(change.windowStateChanged == false)
        #expect(change.version[replica.deviceID] == 2)
    }

    @Test("Moving a window reports a window-only change")
    func detectsAWindowMove() throws {
        let clock = TestClock()
        let replica = try makeReplica(clock: clock)
        _ = try replica.reconcile(with: [try note("17")])
        clock.advance()

        let moved = try note("17", state: try windowState("17", frame: CGRect(x: 900, y: 40, width: 300, height: 200)))
        let change = try #require(try replica.reconcile(with: [moved]).first)

        // Stickies moves windows on its own, so a caller needs to be able to
        // tell this apart from an edit without diffing the note itself.
        #expect(change.kind == .edited)
        #expect(change.isWindowStateOnly)
        #expect(change.contentChanged == false)
    }

    @Test("A note that disappears is tombstoned, once")
    func detectsADeletion() throws {
        let clock = TestClock()
        let replica = try makeReplica(clock: clock)
        _ = try replica.reconcile(with: [try note("17"), try note("18")])
        clock.advance()

        let changes = try replica.reconcile(with: [try note("17")])

        #expect(changes.map(\.kind) == [.deleted])
        #expect(changes.first?.id.rawValue == "18")
        #expect(try replica.knownNote(try stickyID("18"))?.isDeleted == true)

        // Reported once: a tombstoned note stays tombstoned rather than being
        // rediscovered on every later scan.
        clock.advance()
        #expect(try replica.reconcile(with: [try note("17")]).isEmpty)
    }

    @Test("A deleted note that comes back is distinguished from a new one")
    func detectsAReappearance() throws {
        let clock = TestClock()
        let replica = try makeReplica(clock: clock)
        _ = try replica.reconcile(with: [try note("17")])
        clock.advance()
        _ = try replica.reconcile(with: [])
        clock.advance()

        let change = try #require(try replica.reconcile(with: [try note("17")]).first)

        #expect(change.kind == .reappeared)
        #expect(try replica.knownNote(try stickyID("17"))?.isDeleted == false)
    }

    @Test("A note both edited and moved reports both")
    func detectsBothAtOnce() throws {
        let clock = TestClock()
        let replica = try makeReplica(clock: clock)
        _ = try replica.reconcile(with: [try note("17", text: "Milk")])
        clock.advance()

        let changed = try note(
            "17",
            text: "Bread",
            state: try windowState("17", frame: CGRect(x: 500, y: 500, width: 300, height: 200))
        )
        let change = try #require(try replica.reconcile(with: [changed]).first)

        #expect(change.contentChanged)
        #expect(change.windowStateChanged)
        #expect(change.isWindowStateOnly == false)
    }

    // MARK: - History

    @Test("Every change retains a version, newest first")
    func retainsVersions() throws {
        let clock = TestClock()
        let replica = try makeReplica(clock: clock)
        _ = try replica.reconcile(with: [try note("17", text: "One")])
        clock.advance()
        _ = try replica.reconcile(with: [try note("17", text: "Two")])
        clock.advance()
        _ = try replica.reconcile(with: [try note("17", text: "Three")])

        let versions = try replica.versions(of: try stickyID("17"))

        #expect(versions.count == 3)
        #expect(versions.map(\.seq) == [3, 2, 1])
        #expect(versions.first?.note?.package.plainTextForTesting?.contains("Three") == true)
        #expect(versions.last?.note?.package.plainTextForTesting?.contains("One") == true)
    }

    @Test("A retained version reproduces the note's bytes exactly")
    func retainedVersionsAreFaithful() throws {
        let replica = try makeReplica()
        let original = try note("17", text: "Milk", attachments: ["photo.png": Data([0x89, 0x50])])
        _ = try replica.reconcile(with: [original])

        let restored = try #require(try replica.versions(of: try stickyID("17")).first?.note)

        #expect(restored == original)
        #expect(restored.package.files == original.package.files)
    }

    @Test("Only the newest versions are retained")
    func prunesOldVersions() throws {
        let clock = TestClock()
        let replica = try makeReplica(clock: clock, versionRetention: 3)

        for index in 1...6 {
            _ = try replica.reconcile(with: [try note("17", text: "Version \(index)")])
            clock.advance()
        }

        let versions = try replica.versions(of: try stickyID("17"))
        #expect(versions.count == 3)
        #expect(versions.map(\.seq) == [6, 5, 4])
    }

    // MARK: - Deletion and recovery

    @Test("A deletion is recorded as a tombstone with no content of its own")
    func deletionRecordsATombstone() throws {
        let clock = TestClock()
        let replica = try makeReplica(clock: clock)
        _ = try replica.reconcile(with: [try note("17", text: "Do not lose me")])
        clock.advance()
        _ = try replica.reconcile(with: [])

        let versions = try replica.versions(of: try stickyID("17"))

        #expect(versions.first?.isDeletion == true)
        #expect(versions.first?.note == nil)
        #expect(versions.count == 2)
    }

    @Test("A deleted note can still be recovered from the version before it")
    func recoversADeletedNote() throws {
        let clock = TestClock()
        let replica = try makeReplica(clock: clock)
        let original = try note("17", text: "Do not lose me")
        _ = try replica.reconcile(with: [original])
        clock.advance()
        _ = try replica.reconcile(with: [])

        // SPEC.md F8: a deletion is a tombstone with recoverable content, not an
        // erasure.
        let recoverable = try #require(try replica.newestRecoverableVersion(of: try stickyID("17")))
        #expect(recoverable.note == original)
        #expect(try replica.recoverableDeletedNotes().map(\.id.rawValue) == ["17"])
    }

    @Test("An empty container on the very first scan reports nothing")
    func emptyFirstScanIsQuiet() throws {
        #expect(try makeReplica().reconcile(with: []).isEmpty)
    }
}

extension NotePackage {
    /// The reader's `plainText` lives in StickiesStore, which SyncEngine
    /// deliberately does not depend on; these tests only need to see the text
    /// they wrote.
    var plainTextForTesting: String? {
        String(data: richText, encoding: .utf8)
    }
}
