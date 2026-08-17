import ArgumentParser
import Foundation
import StickiesFormat
import StickiesStore

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the notes in this Mac's Stickies container.",
        discussion: """
            Anything the container held that could not be read is reported on \
            standard error. Exits non-zero when a note or a state entry could \
            not be read, since that is data a sync would silently drop.
            """
    )

    @OptionGroup var container: ContainerOptions

    func run() throws {
        let snapshot = try StickiesReader.forHome(container.home).read()

        if snapshot.notes.isEmpty {
            print("No notes.")
        } else {
            print(Table.render(header: Self.header, rows: snapshot.notes.map(Self.row(for:))))
        }

        for line in snapshot.problemLines {
            printError(line)
        }
        for state in snapshot.stateWithoutPackage {
            printError("window state for \(state.id) has no note package on disk")
        }

        if snapshot.hasUnreadableData {
            throw ExitCode.failure
        }
    }

    private static let header = ["IDENTIFIER", "SIZE", "POSITION", "COLOUR", "Z", "FLAGS", "TITLE"]

    private static func row(for note: StickyNote) -> [String] {
        let state = note.windowState
        return [
            note.id.rawValue,
            state.map { "\(integer($0.frame.width))x\(integer($0.frame.height))" } ?? "—",
            state.map { "\(integer($0.frame.minX)),\(integer($0.frame.minY))" } ?? "—",
            state?.palette.sticky.hexDescription ?? "—",
            state?.zOrder.map(String.init) ?? "—",
            flags(for: note),
            note.package.titleLine ?? "(no text)",
        ]
    }

    /// `F` floating above other windows, `T` translucent, `A` carrying
    /// attachments beyond the rich text.
    private static func flags(for note: StickyNote) -> String {
        var flags = ""
        if note.windowState?.isFloating == true { flags += "F" }
        if note.windowState?.isTranslucent == true { flags += "T" }
        if !note.package.attachmentNames.isEmpty { flags += "A" }
        return flags.isEmpty ? "—" : flags
    }

    private static func integer(_ value: CGFloat) -> String {
        String(Int(value.rounded()))
    }
}
