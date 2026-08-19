# StickiesSync — Roadmap

Milestone 5 shipped as v0.6.0 on 2026-08-19: notes sync between Macs over a
shared folder that holds nothing readable, with conflicts resolved into visible
copies and a `launchd` agent to run it. Convergence is verified between two
simulated Macs and between two real ones; the encryption is verified through the
real CLI on one machine, and across two real Macs is outstanding. A milestone is
done when its capability works end to end, its tests pass, the six project
documents match the code, and the user has reviewed it. Milestones 6 and 7 are
marked optional: v1 is complete without them (see the non-goals in
[SPEC.md](SPEC.md)).

## v1 Milestones

| M | Status | Deliverable |
|---|--------|-------------|
| 0 | ✅ done | **Scaffolding** — SwiftPM workspace, `make check`, project docs, and `stickiesctl doctor` reporting container location, readability, note count, state-file shape, and Stickies run state |
| 1 | ✅ done | **Read-only fidelity** — `StickiesFormat` parses `<UUID>.rtfd` and `.SavedStickiesState` into a `StickyNote`; `stickiesctl list` and `export`; golden-file tests; every open format question in [ARCHITECTURE.md](ARCHITECTURE.md) answered |
| 2 | ✅ done | **Safe apply** — quit/write/relaunch coordinator with frontmost and ownership guards, container backup and rollback, `stickiesctl import`, bit-faithful export→wipe→import round trip |
| 3 | ✅ done | **Change detection** — SQLite replica, FSEvents watcher, per-note content hashing, version vectors, tombstones, version history; `stickiesctl watch` streaming note-level changes on one Mac |
| 4 | ✅ done | **Two Macs sync** — `FolderTransport` over a write-disjoint shared directory, manifest exchange, apply loop, last-writer-wins with conflict copies, `launchd` agent. First daily-usable release |
| 5 | ✅ done | **End-to-end encryption** — a shared vault key, sealed records and manifests over a transport reduced to opaque bytes, device keypairs and code-verified pairing, `vault` and `pair` commands |
| 6 | ⬜ planned | **Menu bar app** *(optional)* — sync status, pause/resume, conflict resolution UI, history browser with restore |
| 7 | ⬜ planned | **More transports** *(optional)* — Bonjour + TLS LAN peer-to-peer, and an object-store backend for off-LAN use |

## Post-v1 (not scheduled)

- Character-level merge of rich text, replacing conflict copies where the change
  is unambiguous
- Syncing Stickies application preferences (default colour, translucency)
- Selective sync — excluding individual notes or a colour from replication
- Compaction policy for version history beyond a fixed retention count
- Verified support for macOS versions other than those tested
- Signed and notarized distribution, if the project ever stops being personal
