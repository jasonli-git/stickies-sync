import ArgumentParser

@main
struct StickiesCTL: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stickiesctl",
        abstract: "Inspect and synchronize Apple Stickies notes.",
        version: "0.3.0",
        subcommands: [
            DoctorCommand.self, ListCommand.self, ExportCommand.self, ImportCommand.self,
        ]
    )
}
