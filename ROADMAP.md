# StickiesSync — Roadmap

Milestone 0 shipped as v0.1.0 on 2026-08-17. Nothing synchronizes yet. A
milestone is done when its capability works end to end, its tests pass, the six
project documents match the code, and the user has reviewed it. Milestones 6 and
7 are marked optional: v1 is complete without them (see the non-goals in
[SPEC.md](SPEC.md)).

## v1 Milestones

| M | Status | Deliverable |
|---|--------|-------------|
| 0 | ✅ done | **Scaffolding** — SwiftPM workspace, `make check`, project docs, and `stickiesctl doctor` reporting container location, readability, note count, state-file shape, and Stickies run state |
| 1 | ⬜ planned | **Read-only fidelity** — `StickiesFormat` parses `<UUID>.rtfd` and `.SavedStickiesState` into a `StickyNote`; `stickiesctl list` and `export`; golden-file tests; every open format question in [ARCHITECTURE.md](ARCHITECTURE.md) answered |
| 2 | ⬜ planned | **Safe apply** — quit/write/relaunch coordinator with frontmost and ownership guards, container backup and rollback, `stickiesctl import`, bit-faithful export→wipe→import round trip |
| 3 | ⬜ planned | **Change detection** — SQLite replica, FSEvents watcher, per-note content hashing, version vectors, tombstones, version history; `stickiesctl watch` streaming note-level changes on one Mac |
| 4 | ⬜ planned | **Two Macs sync** — `FolderTransport` over a write-disjoint shared directory, manifest exchange, apply loop, last-writer-wins with conflict copies, `launchd` agent. First daily-usable release |
| 5 | ⬜ planned | **End-to-end encryption** — device keypairs, pairing, a shared vault key, sealed records over the existing transport |
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
