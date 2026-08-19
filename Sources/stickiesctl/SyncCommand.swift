import ArgumentParser
import Foundation
import StickiesFormat
import StickiesStore
import StickiesSyncKit
import SyncEngine

struct SyncCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Exchange notes with the other Macs using the shared folder.",
        discussion: """
            Set the folder once with --folder and it is remembered. Point every \
            Mac at the same folder — an iCloud Drive or Syncthing directory, or \
            a mounted share — and each writes only its own subtree of it, so the \
            service moving the files never has to resolve anything.

            One pass by default. --watch keeps running, syncing when notes change \
            here, when the folder changes, and on a timer as a backstop.
            """
    )

    @OptionGroup var container: ContainerOptions

    @Option(
        name: .long,
        help: ArgumentHelp("Shared folder to sync through. Remembered for next time.", valueName: "path")
    )
    var folder: String?

    @Flag(name: .long, help: "Keep running and sync as things change.")
    var watch = false

    @Flag(name: .long, help: "Report what would happen without changing anything.")
    var dryRun = false

    @Option(name: .long, help: ArgumentHelp("Seconds between backstop passes when watching.", valueName: "seconds"))
    var interval: Double = 30

    func run() throws {
        let syncFolder = try resolveFolder()
        let replica = try container.openReplica()
        let service = SyncService.forHome(container.home, syncFolder: syncFolder, replica: replica)

        guard watch else {
            let outcome = try service.syncOnce(dryRun: dryRun)
            print(Self.render(outcome, replica: replica))
            return
        }

        // Same reasoning as `watch`: a redirected log must show each pass as it
        // happens, and the agent's log is redirected by definition.
        setvbuf(stdout, nil, _IOLBF, 0)

        print("Syncing \(ContainerLocator.stickiesDirectory(homeDirectory: container.home).root.path(percentEncoded: false))")
        print("through \(syncFolder.path(percentEncoded: false))")
        print("as \(replica.deviceName) (\(replica.deviceID)). Ctrl-C to stop.")

        // Stated in the banner because this is the first thing anyone reads in
        // the log after a reboot, and it is the question a launchd job cannot
        // answer in advance: did it inherit enough access to do anything?
        let report = ContainerProbe.forHome(container.home).run()
        let readable = report.access == ContainerReport.Access.readable
        print("container: \(readable ? "readable" : "NOT READABLE")")
        for failure in report.diagnostics() where failure.status == .failure {
            printError("\(failure.name): \(failure.detail)")
        }
        print("")

        let runner = SyncRunner(service: service, replica: replica)
        runner.run(label: "initial pass")

        // Three triggers into one serial queue: notes changing here, records
        // arriving in the folder, and a timer in case the folder's own syncing
        // lands files without FSEvents noticing.
        let containerWatcher = ContainerWatcher.forHome(container.home)
        try containerWatcher.start { runner.run(label: nil) }
        defer { containerWatcher.stop() }

        let folderWatcher = ContainerWatcher(directory: syncFolder, coalescingWindow: 1)
        try folderWatcher.start { runner.run(label: nil) }
        defer { folderWatcher.stop() }

        let timer = DispatchSource.makeTimerSource(queue: runner.queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { runner.run(label: nil) }
        timer.resume()
        defer { timer.cancel() }

        RunLoop.main.run()
    }

    private func resolveFolder() throws -> URL {
        var configuration = SyncConfiguration.load(home: container.home)

        if let folder {
            let url = URL(filePath: folder, directoryHint: .isDirectory)
                .absoluteURL.standardizedFileURL
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            configuration.syncFolder = url
            try configuration.save(home: container.home)
        }

        guard let syncFolder = configuration.syncFolder else {
            throw ValidationError(
                "no sync folder configured — run `stickiesctl sync --folder <path>` once to set one"
            )
        }
        guard FileManager.default.fileExists(atPath: syncFolder.path(percentEncoded: false)) else {
            throw ValidationError(
                "the configured sync folder \(syncFolder.path(percentEncoded: false)) does not exist"
            )
        }
        return syncFolder
    }

    static func render(_ outcome: SyncOutcome, replica: Replica) -> String {
        var lines: [String] = []

        if outcome.wasDryRun {
            lines.append("Dry run: nothing was changed.")
        }
        for change in outcome.localChanges {
            lines.append("  \(change.glyph) \(change) (here)")
        }
        for id in outcome.adopted {
            lines.append("  < \(id) taken from a peer")
        }
        for id in outcome.removed {
            lines.append("  - \(id) deleted by a peer")
        }
        for conflict in outcome.conflicts {
            lines.append(
                "  ! \(conflict.id) was edited in two places — "
                    + "\(conflict.remoteKeptOriginal ? "the other Mac's" : "this Mac's") version kept the note, "
                    + "the other is now \(conflict.copyID)"
            )
        }

        if lines.isEmpty || (outcome.wasDryRun && lines.count == 1) {
            lines.append("Up to date.")
        }

        let peers = outcome.peerNames.isEmpty
            ? "no other Macs have published yet"
            : "peers: \(outcome.peerNames.joined(separator: ", "))"
        lines.append("")
        lines.append("\(outcome.publishedRecords) record(s) published as \(replica.deviceName); \(peers).")

        return lines.joined(separator: "\n")
    }
}

/// Serializes every trigger onto one queue, so two overlapping passes can never
/// both decide to write to Stickies.
private final class SyncRunner: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.stickiessync.sync")

    private let service: SyncService
    private let replica: Replica

    init(service: SyncService, replica: Replica) {
        self.service = service
        self.replica = replica
    }

    func run(label: String?) {
        queue.async { [self] in
            do {
                let outcome = try service.syncOnce()
                guard outcome.didAnything || label != nil else { return }

                if let label { print("[\(label)]") }
                print(SyncCommand.render(outcome, replica: replica))
                for warning in outcome.warnings {
                    printError(warning)
                }
            } catch {
                // A folder that has gone away — an unmounted share, iCloud
                // evicting a directory — must not end a long-running sync.
                printError("sync pass failed, still running: \(error)")
            }
        }
    }
}
