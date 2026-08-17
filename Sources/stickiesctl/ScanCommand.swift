import ArgumentParser
import Foundation
import StickiesFormat
import StickiesStore
import SyncEngine

struct ScanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Compare the container against the replica and record what changed.",
        discussion: """
            The first scan on a Mac records every note as an addition. After \
            that, only differences are reported, and each is recorded as it is \
            reported — running scan twice does not report the same change twice.
            """
    )

    @OptionGroup var container: ContainerOptions

    func run() throws {
        let replica = try container.openReplica()
        let (changes, snapshot) = try container.reconcile(replica)

        print(Self.render(changes, deviceName: replica.deviceName))

        for line in snapshot.problemLines {
            printError(line)
        }
        if snapshot.hasUnreadableData {
            throw ExitCode.failure
        }
    }

    static func render(_ changes: [NoteChange], deviceName: String) -> String {
        guard !changes.isEmpty else { return "No changes." }
        return (changes.map { "  \($0.glyph) \($0)" }
            + ["", "\(changes.count) change(s) recorded against \(deviceName)."])
            .joined(separator: "\n")
    }
}
