# StickiesSync — Roadmap

Milestone 5 shipped as v0.6.0 on 2026-08-19: notes sync between Macs over a
shared folder that holds nothing readable, with conflicts resolved into visible
copies and a `launchd` agent to run it. Convergence is verified between two
simulated Macs and between two real ones, and both real Macs were migrated,
paired, and observed exchanging notes sealed in both directions over iCloud Drive
on 2026-08-19. A milestone is
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

- Optional Markdown interoperability — `.md` import and export as a bridge to
  other tools, converted through `NSAttributedString`. The rich-text package
  stays canonical and Markdown never enters the sync path, so it costs ordinary
  syncing nothing. Four things worth knowing before starting:
  - The two directions are not the same size of job. Foundation parses Markdown
    into an `NSAttributedString` for free; it will not write one back out —
    `NSAttributedString.DocumentType` has `.rtf`, `.rtfd`, `.html` and `.plain`
    and no Markdown. Import is small. Export means walking attribute runs and
    emitting the markup, or going through the HTML that AppKit *will* write.
  - Attachments are most of the export design. An `.rtfd` package can hold
    images, and Markdown has to either link them as files written alongside,
    inline them as data URIs, or drop them and say so.
  - A Markdown library would be the second third-party dependency, against #10
    keeping it at one. Worth deciding deliberately rather than in passing.
  - **Do not extend this to editing a note as Markdown and saving it back.**
    Export loses what Markdown cannot express, which is fine when the result
    goes to the user; writing it back over a note's bytes is the lossy round
    trip [ARCHITECTURE.md](ARCHITECTURE.md) #13 exists to refuse, and every
    rewritten note would replicate as a genuine edit to every Mac.
- Measure what the agent actually costs — resident memory, CPU per pass and at
  idle, disk written, and bytes pushed through iCloud over a day. None of it has
  ever been measured, which is a gap worth closing for something that runs
  unattended on every Mac the user owns. Three things make it more than curiosity:
  the FSEvents watcher and the SQLite replica are both held open for the agent's
  whole lifetime; a pass serializes and re-seals *every* record it publishes
  rather than only what changed, so the cost grows with the number of notes rather
  than the number of edits (see the limitation in
  [ARCHITECTURE.md](ARCHITECTURE.md)); and the thirty-second backstop sets a floor
  on how often that happens. `agent status` reporting the job's resident size and
  accumulated CPU from `launchctl` would be the cheap first version; a real answer
  needs sampling over a day against a container with a realistic number of notes
- A git repository as a transport — a `GitTransport` conforming to the same three
  methods `FolderTransport` does, pulling before a pass and committing and pushing
  its own subtree after. Distinct from the shared-directory transport, which
  already covers iCloud Drive, Syncthing, Dropbox and SMB with no code at all,
  because nothing keeps a repository in step on its own: the pull and the push
  are the transport's job. Points in its favour and against:
  - The write-disjoint layout (#6) suits it. Each Mac only ever touches paths
    under its own `devices/<id>/`, so two Macs pushing concurrently produce
    disjoint trees that merge without conflict; a fetch-rebase-push retry loop
    covers the race on the ref itself.
  - Encryption comes free (#55). The transport moves opaque bytes, so a repo
    holds ciphertext without a line of crypto in the transport.
  - Every version is kept forever, which is either the feature or the problem.
    It sits awkwardly beside the twenty-versions-per-note retention, and a
    deleted note's ciphertext stays in the history after the tombstone
    propagates.
  - Sealed records do not delta-compress; each edit stores a whole new blob.
    Irrelevant at the size Stickies notes are, worth knowing before pointing it
    at anything larger.
- Character-level merge of rich text, replacing conflict copies where the change
  is unambiguous
- Syncing Stickies application preferences (default colour, translucency)
- Selective sync — excluding individual notes or a colour from replication
- Compaction policy for version history beyond a fixed retention count
- Verified support for macOS versions other than those tested
- Signed and notarized distribution, if the project ever stops being personal
