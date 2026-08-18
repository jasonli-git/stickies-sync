import Foundation
import StickiesFormat
import StickiesStore
import SyncEngine

/// What one sync pass did.
public struct SyncOutcome: Sendable {
    public var localChanges: [NoteChange] = []
    public var adopted: [StickyID] = []
    public var removed: [StickyID] = []
    public var conflicts: [ConflictReport] = []
    public var peerNames: [String] = []
    public var publishedRecords = 0
    public var warnings: [String] = []
    public var wasDryRun = false

    public var didAnything: Bool {
        !localChanges.isEmpty || !adopted.isEmpty || !removed.isEmpty || !conflicts.isEmpty
    }
}

public struct ConflictReport: Hashable, Sendable {
    public let id: StickyID
    public let copyID: StickyID
    /// True when the peer's version kept the original note and this Mac's
    /// version became the copy.
    public let remoteKeptOriginal: Bool
}

/// One pass of: look at this Mac, look at the peers, decide, write, publish.
///
/// The composition root. `StickiesStore` supplies the container and the safe
/// write path, `SyncEngine` supplies the replica and the merge rules, and
/// neither knows the other exists — this type is the only place they meet.
///
/// The pass is deliberately ordered so that every remote change becomes one
/// batch handed to `ApplyCoordinator`. Ten notes arriving from another Mac cause
/// one quit-and-relaunch of Stickies, which is the coalescing SPEC.md promises.
public struct SyncService {
    private let home: URL
    private let replica: Replica
    private let transport: any SyncTransport
    private let reader: StickiesReader
    private let coordinator: ApplyCoordinator
    private let now: () -> Date

    public init(
        home: URL,
        replica: Replica,
        transport: any SyncTransport,
        reader: StickiesReader,
        coordinator: ApplyCoordinator,
        now: @escaping () -> Date = Date.init
    ) {
        self.home = home
        self.replica = replica
        self.transport = transport
        self.reader = reader
        self.coordinator = coordinator
        self.now = now
    }

    public static func forHome(
        _ home: URL,
        syncFolder: URL,
        replica: Replica,
        processControl: (any StickiesProcessControlling)? = nil
    ) -> SyncService {
        SyncService(
            home: home,
            replica: replica,
            transport: FolderTransport(root: syncFolder, device: replica.deviceID),
            reader: StickiesReader.forHome(home),
            coordinator: processControl.map {
                ApplyCoordinator.forHome(home, processControl: $0)
            } ?? ApplyCoordinator.forHome(home)
        )
    }

    @discardableResult
    public func syncOnce(dryRun: Bool = false) throws -> SyncOutcome {
        var outcome = SyncOutcome(wasDryRun: dryRun)

        // 1. Record what this Mac has done since the last pass, so what gets
        //    published and compared is current.
        let snapshot = try reader.read()
        outcome.warnings += snapshot.problemWarnings
        outcome.localChanges = dryRun ? [] : try replica.reconcile(with: snapshot.notes)

        // 2. Decide, against every peer.
        let plan = try makePlan(&outcome, placedBy: snapshot)

        // 3. Write everything in one batch, then tell the replica what landed.
        if !dryRun {
            try apply(plan, into: &outcome)
            try publish(&outcome)
        } else {
            outcome.adopted = plan.notes.map(\.id)
            outcome.removed = plan.removals
        }

        return outcome
    }

    // MARK: - Deciding

    private struct Plan {
        var notes: [StickyNote] = []
        var removals: [StickyID] = []
        /// What to tell the replica once the container has actually taken it.
        var integrations: [(id: StickyID, note: StickyNote?, isDeleted: Bool, version: VersionVector, origin: DeviceID)] = []
    }

    private func makePlan(_ outcome: inout SyncOutcome, placedBy snapshot: StickiesSnapshot) throws -> Plan {
        // Where each note currently sits on *this* Mac. Taken from the container
        // rather than the replica: a note that has only been moved leaves no
        // retained version, by design, so the replica's copy of its geometry is
        // deliberately stale.
        let placement = Dictionary(
            uniqueKeysWithValues: snapshot.notes.map { ($0.id, $0.windowState) }
        )
        var plan = Plan()
        var localRecords = Dictionary(
            uniqueKeysWithValues: try replica.localRecords().map { ($0.id, $0) }
        )

        for manifest in try transport.peerManifests(excluding: replica.deviceID) {
            outcome.peerNames.append(manifest.deviceName)

            for entry in manifest.entries {
                let local = localRecords[entry.id]

                // The manifest carries the vector, so a note we are level with
                // or ahead of never costs a record read at all.
                if let local, local.version.ordering(against: entry.version) != .ancestor,
                   local.version.ordering(against: entry.version) != .concurrent
                {
                    continue
                }

                guard let remote = try transport.record(entry.id, from: manifest.device) else {
                    // Advertised but not landed yet — normal while the folder is
                    // still copying. The next pass will find it.
                    outcome.warnings.append(
                        "\(manifest.deviceName) lists \(entry.id) but its record has not arrived yet"
                    )
                    continue
                }
                guard let resolution = MergeDecision.resolve(local: local, remote: remote) else {
                    continue
                }

                apply(
                    resolution.keepingPlacement(placement[entry.id], of: entry.id),
                    for: entry.id,
                    local: local,
                    into: &plan,
                    &outcome,
                    &localRecords
                )
            }
        }
        return plan
    }

    private func apply(
        _ resolution: Resolution,
        for id: StickyID,
        local: SyncRecord?,
        into plan: inout Plan,
        _ outcome: inout SyncOutcome,
        _ localRecords: inout [StickyID: SyncRecord]
    ) {
        let adopted = resolution.adopt

        if let adopted, adopted.isDeletion {
            plan.removals.append(id)
        } else if let note = adopted?.note {
            plan.notes.append(note)
        }

        plan.integrations.append(
            (
                id: id,
                note: adopted?.note,
                isDeleted: adopted?.isDeletion ?? (local?.isDeletion ?? false),
                version: resolution.version,
                origin: adopted?.origin ?? local?.origin ?? replica.deviceID
            )
        )

        // Keep the working copy current so a second peer advertising the same
        // note compares against what this pass has already decided, not against
        // what was on disk when the pass began.
        localRecords[id] = SyncRecord(
            id: id,
            origin: adopted?.origin ?? local?.origin ?? replica.deviceID,
            version: resolution.version,
            isDeletion: adopted?.isDeletion ?? (local?.isDeletion ?? false),
            note: adopted?.note ?? local?.note,
            recordedAt: adopted?.recordedAt ?? local?.recordedAt ?? now()
        )

        if let copy = resolution.conflictCopy, let note = copy.note {
            plan.notes.append(note)
            plan.integrations.append(
                (id: copy.id, note: note, isDeleted: false, version: copy.version, origin: copy.origin)
            )
            localRecords[copy.id] = copy
            outcome.conflicts.append(
                ConflictReport(id: id, copyID: copy.id, remoteKeptOriginal: adopted != nil)
            )
        }
    }

    // MARK: - Writing

    private func apply(_ plan: Plan, into outcome: inout SyncOutcome) throws {
        guard !plan.notes.isEmpty || !plan.removals.isEmpty else { return }

        let applied: ApplyOutcome
        do {
            applied = try coordinator.apply(
                ApplyRequest(notes: plan.notes, removing: plan.removals)
            )
        } catch let refusal as ApplyRefusal {
            // Refusing is a normal outcome — the user is typing in Stickies, or
            // a note here cannot be read. Local state is still published below,
            // and the next pass will try again.
            outcome.warnings.append("nothing applied: \(refusal)")
            return
        }

        outcome.adopted = applied.written
        outcome.removed = applied.removed
        outcome.warnings += applied.warnings

        // Only now that the container has taken them. Integrating first would
        // leave the replica claiming notes that a refused or failed apply never
        // wrote.
        for integration in plan.integrations {
            try replica.integrate(
                id: integration.id,
                note: integration.note,
                isDeleted: integration.isDeleted,
                version: integration.version,
                origin: integration.origin
            )
        }
    }

    private func publish(_ outcome: inout SyncOutcome) throws {
        let records = try replica.localRecords()
        try transport.publish(manifest: try replica.manifest(publishedAt: now()), records: records)
        outcome.publishedRecords = records.count
    }
}

extension Resolution {
    /// The peer's words and colour, at this Mac's placement.
    ///
    /// Adopting a peer's frame for a note already on screen here is what made
    /// opening Stickies on a laptop rearrange the desktop Mac's notes: the
    /// smaller display clamps out-of-bounds windows and writes the clamped
    /// frames back, and those then replicated. A note arriving for the *first*
    /// time has no local placement to keep, so it is seeded with the sender's.
    func keepingPlacement(_ local: StickyWindowState??, of id: StickyID) -> Resolution {
        guard let local = local.flatMap({ $0 }), var record = adopt, var note = record.note else {
            return self
        }
        note.windowState = note.windowState?.keepingGeometry(of: local)
        record.note = note

        var kept = self
        kept.adopt = record
        return kept
    }
}

extension StickiesSnapshot {
    /// The reader's findings as warnings, for a sync pass that must keep going
    /// regardless.
    var problemWarnings: [String] {
        unreadableNotes.map { "cannot read note \($0.id): \($0.reason) — it will not be synced" }
            + unreadableStateEntries.map { "cannot read a window-state entry: \($0)" }
    }
}
