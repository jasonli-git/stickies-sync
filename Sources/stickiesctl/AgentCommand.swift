import ArgumentParser
import Foundation
import StickiesFormat
import StickiesStore
import StickiesSyncKit

struct AgentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Install or remove the background sync agent.",
        subcommands: [Install.self, Uninstall.self, Status.self]
    )

    static let label = "com.stickiessync.agent"

    static func plistURL(home: URL) -> URL {
        home.appending(path: "Library/LaunchAgents/\(label).plist", directoryHint: .notDirectory)
    }

    static func logURL(home: URL) -> URL {
        home.appending(path: "Library/Logs/StickiesSync.log", directoryHint: .notDirectory)
    }

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Install a launchd agent that runs `stickiesctl sync --watch` at login.",
            discussion: """
                Writes ~/Library/LaunchAgents/com.stickiessync.agent.plist and \
                loads it. The sync folder must already be configured — run \
                `stickiesctl sync --folder <path>` first. Output goes to \
                ~/Library/Logs/StickiesSync.log.
                """
        )

        @OptionGroup var container: ContainerOptions

        @Option(
            name: .long,
            help: ArgumentHelp("stickiesctl to run. Defaults to this one.", valueName: "path")
        )
        var executable: String?

        func run() throws {
            guard let syncFolder = SyncConfiguration.load(home: container.home).syncFolder else {
                throw ValidationError(
                    "no sync folder configured — run `stickiesctl sync --folder <path>` first"
                )
            }

            // Checked before anything persistent is written. An agent that cannot
            // read the container still starts, still logs, and syncs nothing —
            // failing once here, in front of whoever typed the command, beats
            // failing every thirty seconds where nobody is looking.
            try container.requireReadableContainer("install the agent")
            // The same argument, for the same reason: an agent with no vault
            // refuses every pass (#57).
            let vault = try container.requireVault()

            let binary = try resolveExecutable()
            let plistURL = AgentCommand.plistURL(home: container.home)
            let logURL = AgentCommand.logURL(home: container.home)

            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let plist: [String: Any] = [
                "Label": AgentCommand.label,
                "ProgramArguments": [binary.path(percentEncoded: false), "sync", "--watch"],
                "RunAtLoad": true,
                // The sync loop is meant to be always-on; if it dies, bring it
                // back. Throttled so a crash loop cannot spin.
                "KeepAlive": true,
                "ThrottleInterval": 30,
                "StandardOutPath": logURL.path(percentEncoded: false),
                "StandardErrorPath": logURL.path(percentEncoded: false),
            ]
            try PropertyListSerialization
                .data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: plistURL, options: .atomic)

            // Replacing an already-loaded agent needs the old one gone first;
            // bootout on a service that is not loaded is a normal failure.
            _ = try? AgentCommand.launchctl(["bootout", "gui/\(getuid())/\(AgentCommand.label)"])
            let output = try AgentCommand.launchctl([
                "bootstrap", "gui/\(getuid())", plistURL.path(percentEncoded: false),
            ])

            print("Installed \(plistURL.path(percentEncoded: false))")
            print("Syncing through \(syncFolder.path(percentEncoded: false)), sealed with vault \(vault.keyID)")
            print("Logging to \(logURL.path(percentEncoded: false))")
            if !output.isEmpty { printError(output) }

            printError(
                "note: the agent runs as a launchd job, which inherits no grant from a terminal. "
                    + "If its log shows permission errors after a reboot, add "
                    + "\(binary.path(percentEncoded: false)) to Full Disk Access."
            )

            if binary.path(percentEncoded: false).contains("/.build/") {
                printError(
                    "warning: the agent points at a build directory (\(binary.path(percentEncoded: false))). "
                        + "Run `make release` and reinstall with "
                        + "--executable .build/release/stickiesctl, or the agent breaks on `make clean`."
                )
            }
        }

        /// `CommandLine.arguments[0]` is whatever the shell used, which may be
        /// relative or a symlink; launchd needs a real absolute path.
        private func resolveExecutable() throws -> URL {
            if let executable {
                return URL(filePath: executable, directoryHint: .notDirectory)
                    .absoluteURL.standardizedFileURL
            }
            return URL(filePath: CommandLine.arguments[0], directoryHint: .notDirectory)
                .absoluteURL.resolvingSymlinksInPath()
        }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "uninstall",
            abstract: "Stop the agent and remove its launchd job."
        )

        @OptionGroup var container: ContainerOptions

        func run() throws {
            let plistURL = AgentCommand.plistURL(home: container.home)
            _ = try? AgentCommand.launchctl(["bootout", "gui/\(getuid())/\(AgentCommand.label)"])

            if FileManager.default.fileExists(atPath: plistURL.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: plistURL)
                print("Removed \(plistURL.path(percentEncoded: false))")
            } else {
                print("No agent was installed.")
            }
            // Notes, the replica, and the sync folder are all left alone: this
            // stops the automation, it does not undo the syncing.
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Report whether the agent is installed and running."
        )

        @OptionGroup var container: ContainerOptions

        func run() throws {
            let plistURL = AgentCommand.plistURL(home: container.home)
            let installed = FileManager.default.fileExists(atPath: plistURL.path(percentEncoded: false))
            print("launchd job:  \(installed ? plistURL.path(percentEncoded: false) : "not installed")")

            let listing = (try? AgentCommand.launchctl(["print", "gui/\(getuid())/\(AgentCommand.label)"])) ?? ""
            let running = listing.contains("state = running")
            print("running:      \(running ? "yes" : "no")")

            let configuration = SyncConfiguration.load(home: container.home)
            print("sync folder:  \(configuration.syncFolder?.path(percentEncoded: false) ?? "not configured")")
            print("log:          \(AgentCommand.logURL(home: container.home).path(percentEncoded: false))")
        }
    }

    static func launchctl(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl", directoryHint: .notDirectory)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            struct LaunchctlError: Error, CustomStringConvertible {
                let description: String
            }
            throw LaunchctlError(
                description: "launchctl \(arguments.joined(separator: " ")) failed: \(output)"
            )
        }
        return output
    }
}
