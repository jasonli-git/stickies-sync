import ArgumentParser
import Foundation
import StickiesFormat
import StickiesStore
import SyncEngine

struct RestoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Put a retained version of a note back into Stickies.",
        discussion: """
            Restores the newest version that has content, which for a deleted \
            note is whatever it held before it went. Pass --version to choose an \
            earlier one; `stickiesctl history <sticky-id>` lists them.

            The restore goes through the same apply path as import, so it quits \
            Stickies, backs the container up, writes, and relaunches.
            """
    )

    @OptionGroup var container: ContainerOptions

    @Argument(help: ArgumentHelp("The note to restore.", valueName: "sticky-id"))
    var stickyIdentifier: String

    @Option(name: .long, help: ArgumentHelp("Restore this sequence number instead of the newest.", valueName: "seq"))
    var version: Int?

    @Flag(name: .long, help: "Report what would be restored without touching anything.")
    var dryRun = false

    func run() throws {
        guard let id = StickyID(rawValue: stickyIdentifier) else {
            throw ValidationError("\(stickyIdentifier) is not a usable sticky identifier")
        }

        let replica = try container.openReplica()
        let candidate = try Self.version(version, of: id, in: replica)

        guard let note = candidate.note else {
            throw ValidationError(
                "version \(candidate.seq) of \(id) is a deletion and has no content to restore"
            )
        }

        let outcome = try ApplyCoordinator.forHome(container.home)
            .apply(ApplyRequest(notes: [note]), dryRun: dryRun)

        let recorded = Self.timestamp.string(from: candidate.recordedAt)
        print(
            dryRun
                ? "Would restore \(id) to version \(candidate.seq), recorded \(recorded)."
                : "Restored \(id) to version \(candidate.seq), recorded \(recorded)."
        )
        if let backupName = outcome.backupName {
            print("Backed up the container as \(backupName).")
        }
        for warning in outcome.warnings {
            printError(warning)
        }

        // The container now differs from what the replica believes, and leaving
        // that gap would make the next scan report the restore as a fresh edit
        // by this Mac. Recording it here keeps the replica honest.
        if !dryRun {
            _ = try container.reconcile(replica)
        }
    }

    private static func version(
        _ seq: Int?,
        of id: StickyID,
        in replica: Replica
    ) throws -> RetainedVersion {
        let versions = try replica.versions(of: id)
        guard !versions.isEmpty else {
            throw ValidationError("the replica has no retained versions of \(id)")
        }

        guard let seq else {
            guard let newest = try replica.newestRecoverableVersion(of: id) else {
                throw ValidationError("every retained version of \(id) is a deletion")
            }
            return newest
        }
        guard let chosen = versions.first(where: { $0.seq == seq }) else {
            throw ValidationError(
                "\(id) has no version \(seq); available: "
                    + versions.map { String($0.seq) }.joined(separator: ", ")
            )
        }
        return chosen
    }

    private static let timestamp = HistoryCommand.timestamp
}
