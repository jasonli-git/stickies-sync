import ArgumentParser
import Foundation
import StickiesFormat
import StickiesStore
import SyncEngine

struct HistoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Show the versions the replica has retained.",
        discussion: """
            With no identifier, lists every note the replica knows about, \
            including ones that have been deleted and can still be recovered. \
            With one, lists that note's retained versions, newest first.
            """
    )

    @OptionGroup var container: ContainerOptions

    @Argument(help: ArgumentHelp("Show one note's versions.", valueName: "sticky-id"))
    var stickyIdentifier: String?

    func run() throws {
        let replica = try container.openReplica()

        guard let stickyIdentifier else {
            print(try Self.renderNotes(replica))
            return
        }
        guard let id = StickyID(rawValue: stickyIdentifier) else {
            throw ValidationError("\(stickyIdentifier) is not a usable sticky identifier")
        }
        print(try Self.renderVersions(of: id, in: replica))
    }

    private static func renderNotes(_ replica: Replica) throws -> String {
        let notes = try replica.knownNotes()
        guard !notes.isEmpty else { return "The replica is empty. Run `stickiesctl scan` first." }

        let rows = try notes.map { note in
            [
                note.id.rawValue,
                note.isDeleted ? "deleted" : "present",
                String(try replica.versions(of: note.id).count),
                Self.timestamp.string(from: note.updatedAt),
                note.version.counters
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key.rawValue.prefix(8))=\($0.value)" }
                    .joined(separator: " "),
            ]
        }
        return Table.render(header: ["IDENTIFIER", "STATE", "VERSIONS", "UPDATED", "VERSION VECTOR"], rows: rows)
    }

    private static func renderVersions(of id: StickyID, in replica: Replica) throws -> String {
        let versions = try replica.versions(of: id)
        guard !versions.isEmpty else { return "No retained versions for \(id)." }

        let rows = versions.map { version in
            [
                String(version.seq),
                String(version.deviceID.rawValue.prefix(8)) + "…",
                Self.timestamp.string(from: version.recordedAt),
                version.isDeletion ? "deletion" : "\(version.note?.package.byteCount ?? 0) bytes",
                version.isDeletion ? "—" : (version.note?.package.titleLine ?? "(no text)"),
            ]
        }
        return Table.render(header: ["SEQ", "DEVICE", "RECORDED", "SIZE", "TITLE"], rows: rows)
    }

    static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
