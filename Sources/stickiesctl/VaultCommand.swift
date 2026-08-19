import ArgumentParser
import Foundation
import StickiesFormat
import StickiesStore
import StickiesSyncKit
import SyncEngine

struct VaultCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vault",
        abstract: "The key this Mac's notes are encrypted with.",
        discussion: """
            Every record and manifest in the sync folder is sealed with one key \
            shared by all of your Macs. Create it once with `vault init`, then \
            put it on the others with `pair`. Nothing syncs without it.

            The key lives in an owner-only file beside the replica. Anything \
            able to read that file can already read your notes in Stickies' own \
            container, which is not encrypted by anyone.
            """,
        subcommands: [Status.self, Initialize.self, Reset.self]
    )

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Report the vault, and whether the folder can actually be read."
        )

        @OptionGroup var container: ContainerOptions

        func run() throws {
            let store = container.vaultStore()
            let vault = try store.vault()

            print("vault:      \(vault?.keyID ?? "none — this Mac cannot sync yet")")
            print("key file:   \(container.vaultURL.path(percentEncoded: false)) \(Self.mode(of: container.vaultURL))")

            let replica = try container.openReplica()
            print("this Mac:   \(replica.deviceName) (\(replica.deviceID))")

            guard let vault else {
                print("")
                print("Run `stickiesctl vault init` on your first Mac, or")
                print("`stickiesctl pair request` on one that is joining.")
                return
            }

            guard let folder = try? container.configuredSyncFolder() else {
                print("folder:     not configured")
                return
            }
            print("folder:     \(folder.path(percentEncoded: false))")

            // The point of reporting this: a Mac holding the wrong key still
            // runs, still logs, and syncs nothing. Counting what opens is the
            // difference between "quiet" and "working".
            let channel = SealedChannel(
                transport: FolderTransport(root: folder, device: replica.deviceID),
                vault: vault,
                device: replica.deviceID
            )
            let reading = try channel.peerManifests()

            if reading.manifests.isEmpty && reading.unopened.isEmpty {
                print("peers:      none have published yet")
            }
            for manifest in reading.manifests {
                print("peer:       \(manifest.deviceName) — \(manifest.entries.count) record(s) readable")
            }
            for unopened in reading.unopened {
                printError("peer:       \(unopened.device) — CANNOT OPEN: \(unopened.reason)")
            }
            if !reading.unopened.isEmpty {
                printError(
                    "A peer that cannot be opened is either not paired with this vault yet, "
                        + "or is not one of your Macs. Nothing it publishes is applied."
                )
                throw ExitCode.failure
            }
        }

        private static func mode(of url: URL) -> String {
            guard let attributes = try? FileManager.default
                .attributesOfItem(atPath: url.path(percentEncoded: false)),
                let permissions = attributes[.posixPermissions] as? NSNumber
            else { return "(not written yet)" }
            return "(\(String(format: "%04o", permissions.intValue)))"
        }
    }

    struct Initialize: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "init",
            abstract: "Create this set of Macs' vault key. Run once, on one Mac."
        )

        @OptionGroup var container: ContainerOptions

        func run() throws {
            let store = container.vaultStore()
            if let existing = try store.vault() {
                throw ValidationError(
                    "this Mac already holds vault \(existing.keyID). "
                        + "Use `stickiesctl vault reset` to replace it, which every other Mac has to be paired to again."
                )
            }

            let vault = Vault.generate()
            try store.setVault(vault)

            print("Created vault \(vault.keyID).")
            print("Stored in \(container.vaultURL.path(percentEncoded: false)), readable only by you.")
            print("")
            print("On every other Mac, run `stickiesctl pair request` and follow what it prints.")
        }
    }

    struct Reset: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "reset",
            abstract: "Replace the vault key with a new one.",
            discussion: """
                For a key that was lost — if no Mac still holds it, the folder \
                cannot be read by anything and a new one is the only way \
                forward — or for rotating deliberately.

                Your notes are not at risk either way: Stickies is where they \
                live, and this only changes what the sync folder is sealed with. \
                Every other Mac stops being able to read this one until it is \
                paired again.
                """
        )

        @OptionGroup var container: ContainerOptions

        @Flag(name: .long, help: "Required, because every other Mac must be paired again afterwards.")
        var force = false

        func run() throws {
            let store = container.vaultStore()
            let existing = try store.vault()

            guard force else {
                throw ValidationError(
                    """
                    this replaces vault \(existing?.keyID ?? "none") with a new one.

                    Every other Mac keeps publishing under the old key and this one will \
                    refuse all of it until each is paired again. Pass --force to go ahead.
                    """
                )
            }

            let vault = Vault.generate()
            try store.setVault(vault)

            print("Vault is now \(vault.keyID)\(existing.map { ", was \($0.keyID)" } ?? "").")
            // The next publish reseals every record under the new key, and the
            // old files are pruned by the same pass: each record's name is
            // derived from the key, so none of the old names is expected any more.
            print("The next sync republishes everything under it and clears out the old records.")
            print("Pair your other Macs again: `stickiesctl pair request` on each.")
        }
    }
}
