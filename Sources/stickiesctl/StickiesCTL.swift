import ArgumentParser

@main
struct StickiesCTL: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stickiesctl",
        abstract: "Inspect and synchronize Apple Stickies notes.",
        version: "0.6.1",
        subcommands: [
            DoctorCommand.self, ListCommand.self, ExportCommand.self, ImportCommand.self,
            ScanCommand.self, WatchCommand.self, HistoryCommand.self, RestoreCommand.self,
            SyncCommand.self, VaultCommand.self, PairCommand.self, AgentCommand.self,
        ]
    )
}
