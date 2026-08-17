import ArgumentParser
import Foundation
import StickiesFormat
import StickiesStore

struct ExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Write every note, verbatim, to a portable archive.",
        discussion: """
            The archive is an XML property list carrying each note's package \
            bytes and window state unchanged, and is what `import` will read \
            back in Milestone 2. Notes that could not be read are reported on \
            standard error and omitted; the command exits non-zero in that \
            case, because the archive is then incomplete.
            """
    )

    @OptionGroup var container: ContainerOptions

    @Option(
        name: [.customShort("o"), .customLong("output")],
        help: ArgumentHelp("Write to this file instead of standard output.", valueName: "path")
    )
    var outputPath: String?

    func run() throws {
        let snapshot = try StickiesReader.forHome(container.home).read()
        let archive = NoteArchive(notes: snapshot.notes)
        let data = try archive.serialized()

        if let outputPath {
            try data.write(to: URL(filePath: outputPath, directoryHint: .notDirectory))
            printError("Exported \(snapshot.notes.count) note(s) to \(outputPath).")
        } else {
            FileHandle.standardOutput.write(data)
        }

        for line in snapshot.problemLines {
            printError(line)
        }

        if snapshot.hasUnreadableData {
            throw ExitCode.failure
        }
    }
}
