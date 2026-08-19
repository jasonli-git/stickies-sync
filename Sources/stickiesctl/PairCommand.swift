import ArgumentParser
import Foundation
import StickiesFormat
import StickiesStore
import StickiesSyncKit
import SyncEngine

struct PairCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pair",
        abstract: "Give another Mac the vault key.",
        discussion: """
            Three steps, and you have to be at both Macs.

              1. On the new Mac:      stickiesctl pair request
              2. On a Mac that syncs: stickiesctl pair approve <mac> --code <code>
              3. On the new Mac:      stickiesctl pair complete

            The code shown in step 1 is what makes this safe. Anything that can \
            write to the sync folder can publish a request of its own and be \
            handed the vault, so step 2 refuses unless the code you type matches \
            the request it found. Read it off the other Mac's screen — do not \
            take it from the folder.
            """,
        subcommands: [Request.self, List.self, Approve.self, Complete.self]
    )

    /// The three subcommands that touch the folder all need the same three
    /// things, and assembling them in one place keeps the refusals identical.
    fileprivate struct Session {
        let replica: Replica
        let transport: FolderTransport
        let store: FileVaultStore

        init(_ container: ContainerOptions) throws {
            self.replica = try container.openReplica()
            self.transport = FolderTransport(
                root: try container.configuredSyncFolder(),
                device: replica.deviceID
            )
            self.store = container.vaultStore()
        }
    }

    struct Request: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "request",
            abstract: "Ask to join, from a Mac that has no vault yet."
        )

        @OptionGroup var container: ContainerOptions

        func run() throws {
            let session = try Session(container)

            if let existing = try session.store.vault() {
                throw ValidationError(
                    "this Mac already holds vault \(existing.keyID) — there is nothing to request. "
                        + "To join a different set of Macs, run `stickiesctl vault reset --force` first."
                )
            }

            let identity = try session.store.identityKey()
            let request = PairingRequest(
                device: session.replica.deviceID,
                deviceName: session.replica.deviceName,
                publicKey: identity.publicKey.rawRepresentation,
                requestedAt: Date()
            )
            try session.transport.publish(request: request)

            print("Asked to join, as \(request.deviceName).")
            print("")
            print("  Code:  \(request.code)")
            print("")
            print("On a Mac that is already syncing, run:")
            print("  stickiesctl pair approve \(request.deviceName) --code \(request.code)")
            print("")
            print("Then come back here and run `stickiesctl pair complete`.")
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "Show the Macs waiting to be let in."
        )

        @OptionGroup var container: ContainerOptions

        func run() throws {
            let session = try Session(container)
            let pending = try session.transport.pendingRequests()
                .filter { $0.device != session.replica.deviceID }

            guard !pending.isEmpty else {
                print("No Mac is waiting to be let in.")
                return
            }

            print(
                Table.render(
                    header: ["MAC", "CODE", "DEVICE", "ASKED"],
                    rows: pending.map {
                        [$0.deviceName, $0.code, $0.device.rawValue, Self.stamp($0.requestedAt)]
                    }
                )
            )
            printError(
                "\nCheck a code against the one shown on that Mac's own screen before approving it."
            )
        }

        private static func stamp(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return formatter.string(from: date)
        }
    }

    struct Approve: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "approve",
            abstract: "Grant the vault key to a Mac that asked for it."
        )

        @OptionGroup var container: ContainerOptions

        @Argument(help: ArgumentHelp("The Mac's name, or its device identifier.", valueName: "mac"))
        var mac: String

        @Option(
            name: .long,
            help: ArgumentHelp("The code shown on that Mac's screen.", valueName: "code")
        )
        var code: String

        func run() throws {
            let session = try Session(container)
            guard let vault = try session.store.vault() else {
                throw ValidationError(
                    "this Mac has no vault to grant. Run this on a Mac that is already syncing."
                )
            }

            let pending = try session.transport.pendingRequests()
                .filter { $0.device != session.replica.deviceID }
            let matches = pending.filter {
                $0.deviceName == mac
                    || $0.device.rawValue == mac
                    || $0.device.rawValue.lowercased().hasPrefix(mac.lowercased())
            }

            guard let request = matches.first else {
                throw ValidationError(
                    "no Mac called \(mac) has asked to join. "
                        + (pending.isEmpty
                            ? "Nothing is waiting; run `stickiesctl pair request` on the other Mac first."
                            : "Waiting: \(pending.map(\.deviceName).joined(separator: ", ")).")
                )
            }
            guard matches.count == 1 else {
                throw ValidationError(
                    "\(mac) matches \(matches.count) requests — name one by its device identifier: "
                        + matches.map(\.device.rawValue).joined(separator: ", ")
                )
            }

            // The whole security of pairing. Everything else here is arithmetic
            // an attacker can also do; this is the one step that requires having
            // been at the other Mac.
            guard Pairing.codesMatch(request.code, code) else {
                throw ValidationError(
                    String(describing: Pairing.PairingError.codeMismatch(shown: request.code, typed: code))
                )
            }

            let grant = try Pairing.grant(
                vault,
                to: request,
                from: session.replica.deviceID,
                named: session.replica.deviceName,
                using: try session.store.identityKey()
            )
            try session.transport.publish(grant: grant, answering: request.device)

            print("Code matches. Vault \(vault.keyID) granted to \(request.deviceName).")
            print("Run `stickiesctl pair complete` on that Mac.")
        }
    }

    struct Complete: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "complete",
            abstract: "Pick up the granted key, on the Mac that asked."
        )

        @OptionGroup var container: ContainerOptions

        func run() throws {
            let session = try Session(container)

            guard let grant = try session.transport.grants(for: session.replica.deviceID).first else {
                throw ValidationError(
                    "no grant has arrived yet. Approve this Mac on one that is already syncing, "
                        + "and give the folder a moment to copy it here."
                )
            }

            let vault = try Pairing.accept(
                grant,
                as: session.replica.deviceID,
                using: try session.store.identityKey()
            )
            try session.store.setVault(vault)
            // Its own directory, and it has served its purpose: the grant is a
            // wrapped key only this Mac can open, so leaving it is untidy rather
            // than unsafe.
            try session.transport.forgetPairing(of: session.replica.deviceID)

            print("Paired with \(grant.deviceName). This Mac now holds vault \(vault.keyID).")

            // Proving it opens something is worth more than reporting success:
            // a grant that was tampered with yields a key that unwraps to
            // nothing readable, and that has to be visible immediately rather
            // than as silence in a log.
            let channel = SealedChannel(
                transport: session.transport,
                vault: vault,
                device: session.replica.deviceID
            )
            let reading = try channel.peerManifests()
            for manifest in reading.manifests {
                print("Can read \(manifest.deviceName): \(manifest.entries.count) record(s).")
            }
            for unopened in reading.unopened {
                printError("Still cannot read what \(unopened.device) published: \(unopened.reason)")
            }
            if reading.manifests.isEmpty && !reading.unopened.isEmpty {
                printError(
                    "Nothing in the folder opens with this key. The grant may not have come from your Mac — "
                        + "check the code again, or run `stickiesctl vault reset --force` and start over."
                )
                throw ExitCode.failure
            }

            print("Run `stickiesctl sync` to start exchanging notes.")
        }
    }
}
