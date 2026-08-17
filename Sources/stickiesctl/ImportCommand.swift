import ArgumentParser
import Foundation
import StickiesFormat
import StickiesStore

struct ImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Write the notes in an archive into this Mac's Stickies container.",
        discussion: """
            Stickies overwrites its files from memory while running, so an \
            import quits it, writes, and relaunches it — but never while it is \
            frontmost, since that means you are typing in it. The container is \
            copied to a backup first and restored if the write fails.

            By default the notes in the archive are added or overwritten and \
            everything else is left alone. --replace additionally deletes notes \
            the archive does not contain.
            """
    )

    @OptionGroup var container: ContainerOptions

    @Argument(help: ArgumentHelp("Archive written by `stickiesctl export`.", valueName: "archive"))
    var archivePath: String

    @Flag(name: .long, help: "Delete notes that the archive does not contain.")
    var replace = false

    @Flag(name: .long, help: "Report what would change without touching anything.")
    var dryRun = false

    func run() throws {
        let archive = try NoteArchive(
            data: try Data(contentsOf: URL(filePath: archivePath, directoryHint: .notDirectory))
        )
        let request = ApplyRequest(
            notes: archive.notes,
            removing: replace ? try identifiersToRemove(keeping: archive.notes.map(\.id)) : []
        )

        guard !request.isEmpty else {
            print("Nothing to do: the archive is empty and no notes need removing.")
            return
        }

        let outcome = try ApplyCoordinator.forHome(container.home).apply(request, dryRun: dryRun)
        print(Self.summary(of: outcome))

        for warning in outcome.warnings {
            printError(warning)
        }
    }

    /// `--replace` deletes only notes this tool can see. An entry it does not
    /// recognise is not a note it is entitled to delete.
    private func identifiersToRemove(keeping kept: [StickyID]) throws -> [StickyID] {
        let keptSet = Set(kept)
        return try StickiesReader.forHome(container.home).read()
            .notes
            .map(\.id)
            .filter { !keptSet.contains($0) }
    }

    private static func summary(of outcome: ApplyOutcome) -> String {
        var lines: [String] = []
        let verb = outcome.wasDryRun ? "Would write" : "Wrote"
        lines.append("\(verb) \(outcome.written.count) note(s); "
            + "\(outcome.wasDryRun ? "would remove" : "removed") \(outcome.removed.count).")

        if outcome.wasDryRun {
            lines.append("Dry run: nothing was changed.")
        } else {
            if let backupName = outcome.backupName {
                lines.append("Backed up the container as \(backupName).")
            }
            if outcome.didQuitStickies {
                lines.append(
                    outcome.didRelaunchStickies
                        ? "Quit Stickies and relaunched it."
                        : "Quit Stickies; it did not come back — see the warnings."
                )
            } else {
                lines.append("Stickies was not running, so it was left closed.")
            }
        }
        return lines.joined(separator: "\n")
    }
}
