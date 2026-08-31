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
[SPEC.md](SPEC.md)). Neither is what should happen next — the section below the
table is.

## v1 Milestones

| M | Status | Deliverable |
|---|--------|-------------|
| 0 | ✅ done | **Scaffolding** — SwiftPM workspace, `make check`, project docs, and `stickiesctl doctor` reporting container location, readability, note count, state-file shape, and Stickies run state |
| 1 | ✅ done | **Read-only fidelity** — `StickiesFormat` parses `<UUID>.rtfd` and `.SavedStickiesState` into a `StickyNote`; `stickiesctl list` and `export`; golden-file tests; every open format question in [ARCHITECTURE.md](ARCHITECTURE.md) answered |
| 2 | ✅ done | **Safe apply** — quit/write/relaunch coordinator with frontmost and ownership guards, container backup and rollback, `stickiesctl import`, bit-faithful export→wipe→import round trip |
| 3 | ✅ done | **Change detection** — SQLite replica, FSEvents watcher, per-note content hashing, version vectors, tombstones, version history; `stickiesctl watch` streaming note-level changes on one Mac |
| 4 | ✅ done | **Two Macs sync** — `FolderTransport` over a write-disjoint shared directory, manifest exchange, apply loop, last-writer-wins with conflict copies, `launchd` agent. First daily-usable release |
| 5 | ✅ done | **End-to-end encryption** — a shared vault key, sealed records and manifests over a transport reduced to opaque bytes, device keypairs and code-verified pairing, `vault` and `pair` commands |
| 6 | ⬜ optional | **Menu bar app** — sync status, pause/resume, conflict resolution UI, history browser with restore |
| 7 | ⬜ optional | **More transports** — Bonjour + TLS LAN peer-to-peer, and an object-store backend for off-LAN use |

## Next — before either optional milestone

None of these is a feature. Each is either a way the system can lose a note or a
way it can fail without saying so, and every one of them is cheaper than a menu
bar. They are listed here rather than among the known limitations in
[ARCHITECTURE.md](ARCHITECTURE.md) because a roadmap that lists only capabilities
implies the rest is finished.

- **Refuse to tombstone a container that read as empty.** `Replica.reconcile`
  already declines to tombstone a note that was on disk but unreadable; that
  guard exists because one transient `EINTR` tombstoned a live note and the other
  Mac deleted it. There is no equivalent guard for the container as a whole. A
  read that *succeeds* and returns nothing reconciles as "every note was
  deleted", which is published, and every peer obeys.
  [ARCHITECTURE.md](ARCHITECTURE.md) already names the precondition — a macOS
  that gates app containers and returns an empty listing instead of a denial —
  but frames the consequence as doctor reporting wrongly, when the larger
  consequence is a sync pass. The container access that lapsed mid-session on the
  laptop, still unexplained, is the reason not to file this as hypothetical. The
  guard is blunt and cheap: if the last scan saw notes and this one sees none,
  stop the pass and say so. Principle 6 — degrade to inaction — in the one place
  the code does not currently apply it.

- **Tell an evicted iCloud file from a missing one.** The highest-likelihood
  failure on this list, because Optimize Mac Storage is on by default. An evicted
  *record* is a note that never arrives; an evicted *manifest* is a Mac that stops
  appearing as a peer with nothing anywhere saying it ever existed. The remedy
  today is a manual "Keep Downloaded" in Finder, on every Mac, forever — a
  permanent obligation on the user standing in for a fix
  [ARCHITECTURE.md](ARCHITECTURE.md) already spells out: check
  `URLUbiquitousItemDownloadingStatusKey`, call
  `FileManager.startDownloadingUbiquitousItem(at:)`, and report "downloading"
  rather than "absent". That is a distinction the transport cannot currently
  draw, and drawing it is most of the work.

- **Lock the container between processes.** A hand-run `stickiesctl` and the
  installed agent can both be inside `ApplyCoordinator` at once, each having quit
  Stickies, each writing. The frontmost check and the ownership guard are both
  within a single process, so neither sees the other. It is avoided today by
  remembering to stop the agent first, which is a procedure, not a guard. A
  lockfile under Application Support is small, and this is the same class of
  hazard as the one above: low likelihood, and the loss is a note.

- **Say that syncing is working, not merely that nothing failed.**
  [ARCHITECTURE.md](ARCHITECTURE.md) makes the point twice, in two different
  entries: silence in the log is not proof of syncing, only absence of errors.
  `vault status` answers "can I read my peers"; nothing answers "am I still
  running, and is what I last published current". A doctor check — this Mac's
  last successful pass was *n* minutes ago, no peer's manifest is older than *x*
  — turns that silence into an assertion, and is the natural place for both the
  eviction case above and a recurrence of the access lapse to become visible.

- **Exercise what has never been exercised.** No code, and possibly the most
  valuable item here. [ARCHITECTURE.md](ARCHITECTURE.md) names four things still
  untested: clock skew changing the conflict tiebreak, iCloud Drive or Syncthing
  delaying or reordering arrivals, Syncthing as the transport at all, and a Mac
  whose Stickies is *running* during an apply. That last one is the central
  hazard of the whole design — it is what the "the write path is the whole
  problem" paragraph in [SPEC.md](SPEC.md) is about — and it is currently a line
  in a limitations list rather than a test.

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
- Count what a pass writes to the folder. Depends on nothing and is small: a
  pass already reports `publishedRecords`, and `FolderTransport` is the single
  place sealed bytes are written, so summing the bytes it actually writes gives
  bytes-per-pass exactly. Worth doing first and separately from the profiling
  below, for two reasons. It is the number that answers the question that would
  actually change the design — a pass serializes and re-seals *every* record it
  publishes rather than only what changed, so the cost is expected to track the
  number of notes rather than the number of edits (see the limitation in
  [ARCHITECTURE.md](ARCHITECTURE.md)). Running one pass against `--home`
  containers of ten, a hundred and a thousand notes and reading the slope settles
  that, with no profiler involved at all; if the slope is bad, the fix is
  incremental publish in `localRecords`, and the measurement is what schedules it.
  And it cannot be obtained from outside the process even in principle: nothing
  on macOS reports per-process network I/O without root, and the upload is not
  StickiesSync's anyway — `bird` moves those bytes later, on its own schedule.
  Being cheap enough to log on every pass, it is a standing instrument rather
  than a study that goes stale. Name it for what it is, though: bytes written to
  the folder are an exact measure of local write volume and only an upper bound
  on upload, since a file rewritten twice before iCloud gets to it is uploaded
  once. The slope is the part that answers the question, and the slope survives
  that caveat.
- Profile the agent with `mac-sitrep`, the separate project that is the source of
  every figure here that is not the one above. Its workload profiling and
  publishing milestones were both complete as of 2026-08-31, so this waits on
  nothing but wanting it. The two questions in the original version of this item
  need two different mechanisms, and conflating them is what made "sampling over
  a day" vague: *what does a pass cost* is `sitrep run` wrapping a one-shot
  `stickiesctl sync`, five runs to a median and range, against the same synthetic
  containers; *what does it cost at idle* is not a wrapped run at all, but
  `sitrepd`'s per-process history, which needs only that the agent be running.
  Two details decide whether the resulting profile is honest. Stickies.app has to
  be declared as an external service, because an apply quits and relaunches it and
  that cost lands wholly outside the wrapped process tree — the same shape of
  problem the declared-service delta was built for. And a wide range should be
  expected rather than treated as a bad measurement: the profiler subtracts its
  own overhead, and a mostly-idle agent is exactly where that overhead is a
  meaningful fraction of what is being measured. The payoff beyond knowing the
  number is `sitrep export --inject README.md` with its `--check` drift gate
  wired into `make check`, which keeps a published footprint from quietly rotting.
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
- Decide what happens when a Mac leaves. Today there is exactly one answer —
  `vault reset --force` and re-pair everything else — and it is a fallback rather
  than a choice anyone made. A paired Mac keeps the key and can read anything
  published afterwards; it also still holds, in Stickies, in the clear, every note
  it ever synced, so no amount of rotation retrieves what it already has. That
  argues the current answer is close to right and the work is mostly to say so
  deliberately. Two smaller pieces are separable from that decision: a
  `forget-device` command, because a departed peer's subtree and its counters
  otherwise stay in the folder and in every vector forever, and rotation being a
  named operation rather than a reset that happens to work.
- Discharge the uninstall promise. [SPEC.md](SPEC.md) principle 2 says plainly
  that if StickiesSync is uninstalled the user is left with a normal, working
  Stickies. `agent uninstall` removes the `launchd` job; nothing removes the
  replica, the container backups, the vault key, or this Mac's subtree in the
  shared folder. Small, and a principle stated that flatly is worth a command
  that keeps it.
- Character-level merge of rich text, replacing conflict copies where the change
  is unambiguous
- Syncing Stickies application preferences (default colour, translucency)
- Selective sync — excluding individual notes or a colour from replication
- Compaction policy for version history beyond a fixed retention count
- Verified support for macOS versions other than those tested
- Signed and notarized distribution, if the project ever stops being personal
