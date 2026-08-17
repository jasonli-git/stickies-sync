import Foundation
import StickiesFormat

/// Notes to install and notes to delete.
public struct ApplyRequest: Hashable, Sendable {
    public var notes: [StickyNote]
    public var removing: [StickyID]

    public init(notes: [StickyNote] = [], removing: [StickyID] = []) {
        self.notes = notes
        self.removing = removing
    }

    public var isEmpty: Bool {
        notes.isEmpty && removing.isEmpty
    }
}

/// What an apply did, including the parts a caller has to be told about rather
/// than infer: whether Stickies was interrupted, and whether it came back.
public struct ApplyOutcome: Hashable, Sendable {
    public var written: [StickyID] = []
    public var removed: [StickyID] = []
    public var backupName: String?
    public var didQuitStickies = false
    public var didRelaunchStickies = false
    public var warnings: [String] = []
    public var wasDryRun = false
}

public enum ApplyRefusal: Error, Equatable, CustomStringConvertible {
    /// The user is typing in Stickies. Nothing was done.
    case stickiesIsFrontmost
    /// The request would write over or delete a note whose existing package
    /// could not be read — content we would destroy without ever having seen it.
    /// Nothing was written; Stickies is as it was.
    case wouldTouchUnreadableNotes([String])
    case stickiesWouldNotQuit(timeout: TimeInterval)
    /// The write failed and the container was put back from its backup.
    case rolledBack(underlying: String, backupName: String)
    /// The write failed and so did the restore. The backup is still on disk and
    /// is named here, because at this point a person has to look.
    case rollbackFailed(underlying: String, rollbackError: String, backupName: String)

    public var description: String {
        switch self {
        case .stickiesIsFrontmost:
            "Stickies is frontmost — you are probably typing in it, so nothing was changed"
        case .wouldTouchUnreadableNotes(let reasons):
            "these notes cannot be read, so overwriting or deleting them would destroy "
                + "content never seen; nothing was written:\n  " + reasons.joined(separator: "\n  ")
        case .stickiesWouldNotQuit(let timeout):
            "Stickies did not quit within \(timeout)s — it may have an unsaved note or a sheet open"
        case .rolledBack(let underlying, let backupName):
            "the write failed (\(underlying)); the container was restored from backup \(backupName)"
        case .rollbackFailed(let underlying, let rollbackError, let backupName):
            "the write failed (\(underlying)) AND the restore failed (\(rollbackError)). "
                + "The container may be inconsistent. The backup is intact at \(backupName)"
        }
    }
}

/// Puts notes into the Stickies container safely.
///
/// The order of operations is the whole design, and it is not the obvious one.
/// Stickies autosaves as it quits, so the container is only current *after* it
/// has gone — which means reading and backing up have to happen after the quit,
/// not before. Only the frontmost check runs first, because it is the one
/// refusal worth making without disturbing anything.
///
/// ```
/// frontmost?  -> refuse, nothing touched
/// quit Stickies (it flushes its notes on the way out)
/// read + validate  -> refuse: relaunch first, leave the Mac as we found it
/// back up the container
/// write            -> on failure: restore, relaunch, report the rollback
/// relaunch, but only if we were the one who quit it
/// ```
public struct ApplyCoordinator {
    public static let defaultQuitTimeout: TimeInterval = 10
    public static let defaultBackupRetention = 10

    private let directory: StickiesDirectory
    private let reader: StickiesReader
    private let writer: ContainerWriter
    private let backups: ContainerBackupStore
    private let processControl: any StickiesProcessControlling
    private let quitTimeout: TimeInterval
    private let backupRetention: Int

    public init(
        directory: StickiesDirectory,
        reader: StickiesReader,
        writer: ContainerWriter,
        backups: ContainerBackupStore,
        processControl: any StickiesProcessControlling,
        quitTimeout: TimeInterval = defaultQuitTimeout,
        backupRetention: Int = defaultBackupRetention
    ) {
        self.directory = directory
        self.reader = reader
        self.writer = writer
        self.backups = backups
        self.processControl = processControl
        self.quitTimeout = quitTimeout
        self.backupRetention = backupRetention
    }

    public static func forHome(
        _ homeDirectory: URL = ContainerLocator.currentHomeDirectory,
        processControl: any StickiesProcessControlling = StickiesProcessControl(),
        fileManager: FileManager = .default
    ) -> ApplyCoordinator {
        ApplyCoordinator(
            directory: ContainerLocator.stickiesDirectory(homeDirectory: homeDirectory),
            reader: StickiesReader.forHome(homeDirectory, fileManager: fileManager),
            writer: ContainerWriter.forHome(homeDirectory, fileManager: fileManager),
            backups: ContainerBackupStore.forHome(homeDirectory, fileManager: fileManager),
            processControl: processControl
        )
    }

    /// A dry run reads and validates but neither quits Stickies nor writes. It
    /// therefore reports against the container as it stands right now, which is
    /// not quite what a real apply will see if Stickies is running — the outcome
    /// says so in a warning rather than leaving the caller to work it out.
    public func apply(_ request: ApplyRequest, dryRun: Bool = false) throws -> ApplyOutcome {
        var outcome = ApplyOutcome(wasDryRun: dryRun)
        guard !request.isEmpty else { return outcome }

        if dryRun {
            let snapshot = try reader.read()
            try validate(snapshot, against: request)
            outcome.warnings += warnings(for: snapshot, request: request)
            if processControl.runState().isRunning {
                outcome.warnings.append(
                    "Stickies is running: a real apply would quit it first and re-read the container"
                )
            }
            outcome.written = request.notes.map(\.id)
            outcome.removed = request.removing
            return outcome
        }

        if case .running(frontmost: true) = processControl.runState() {
            throw ApplyRefusal.stickiesIsFrontmost
        }

        // Ownership: only relaunch what we quit, so an app the user closed
        // deliberately stays closed.
        let wasRunning = processControl.runState().isRunning
        if wasRunning {
            guard processControl.quit(within: quitTimeout) else {
                throw ApplyRefusal.stickiesWouldNotQuit(timeout: quitTimeout)
            }
            outcome.didQuitStickies = true
        }

        let snapshot: StickiesSnapshot
        do {
            snapshot = try reader.read()
            try validate(snapshot, against: request)
        } catch {
            // We interrupted the user for nothing; put Stickies back before
            // surfacing why.
            relaunchIfNeeded(wasRunning, into: &outcome)
            throw error
        }
        outcome.warnings += warnings(for: snapshot, request: request)

        let backup = try backups.makeBackup(of: directory.root)
        outcome.backupName = backup.name

        do {
            try writer.apply(
                notes: request.notes,
                removing: request.removing,
                mergingInto: snapshot.savedState
            )
        } catch {
            let refusal: ApplyRefusal
            do {
                try backups.restore(backup, to: directory.root)
                refusal = .rolledBack(
                    underlying: String(describing: error),
                    backupName: backup.name
                )
            } catch let rollbackError {
                refusal = .rollbackFailed(
                    underlying: String(describing: error),
                    rollbackError: String(describing: rollbackError),
                    backupName: backup.name
                )
            }
            relaunchIfNeeded(wasRunning, into: &outcome)
            throw refusal
        }

        outcome.written = request.notes.map(\.id)
        outcome.removed = request.removing
        relaunchIfNeeded(wasRunning, into: &outcome)

        // Pruning is housekeeping: failing it must not fail an apply that
        // already succeeded.
        do {
            try backups.prune(keeping: backupRetention)
        } catch {
            outcome.warnings.append("could not prune old backups: \(error)")
        }

        return outcome
    }

    /// Refuses precisely where a write could destroy something: a note whose
    /// existing package could not be read and which this request would overwrite
    /// or delete.
    ///
    /// The broader "refuse if anything in the container is unreadable" rule was
    /// tried first and is wrong. An unparseable *state entry* is written back
    /// verbatim (ARCHITECTURE #16), so writing cannot damage it, and refusing
    /// over one would disable sync entirely for a single odd entry — the failure
    /// mode #16 exists to avoid. An unreadable package the request does not touch
    /// is likewise left exactly as it is.
    private func validate(_ snapshot: StickiesSnapshot, against request: ApplyRequest) throws {
        let touched = Set(request.notes.map(\.id)).union(request.removing)
        let blocking = snapshot.unreadableNotes.filter { touched.contains($0.id) }
        guard blocking.isEmpty else {
            throw ApplyRefusal.wouldTouchUnreadableNotes(
                blocking.map { "note \($0.id): \($0.reason)" }
            )
        }
    }

    /// Everything tolerated rather than refused. Each of these is a place the
    /// write deliberately leaves the container alone, and saying so is what
    /// keeps that from looking like an oversight.
    private func warnings(for snapshot: StickiesSnapshot, request: ApplyRequest) -> [String] {
        let touched = Set(request.notes.map(\.id)).union(request.removing)
        return snapshot.unreadableNotes
            .filter { !touched.contains($0.id) }
            .map { "leaving unreadable note \($0.id) alone: \($0.reason)" }
            + snapshot.unreadableStateEntries.map {
                "keeping a window-state entry this version cannot parse, verbatim: \($0)"
            }
            + snapshot.unrecognizedEntries.map {
                "leaving unrecognised container entry alone: \($0)"
            }
    }

    /// A failed relaunch is a warning, not a failure: the notes are already
    /// written, and reporting the apply as failed would invite a retry that
    /// changes nothing.
    private func relaunchIfNeeded(_ wasRunning: Bool, into outcome: inout ApplyOutcome) {
        guard wasRunning else { return }
        do {
            try processControl.launch()
            outcome.didRelaunchStickies = true
        } catch {
            outcome.warnings.append("could not relaunch Stickies: \(error)")
        }
    }
}
