# StickiesSync — Roadmap

Milestone 5 shipped as v0.6.0 on 2026-08-19: notes sync between Macs over a
shared folder that holds nothing readable, with conflicts resolved into visible
copies and a `launchd` agent to run it. Convergence is verified between two
simulated Macs and between two real ones, and both real Macs were migrated,
paired, and observed exchanging notes sealed in both directions over iCloud Drive
on 2026-08-19. A milestone is
done when its capability works end to end, its tests pass, the six project
documents match the code, and the user has reviewed it.

**The v1 scope has been complete since 2026-08-19 and 1.0.0 is not released** —
the project is still on 0.6.1. The gap is worth naming rather than closing
quietly, because something has to earn the number. Milestone 8 is the candidate:
the system can still tombstone an entire container on a read that returns
nothing, and a version that says "finished" does not belong on that. Throughout
this document "v1" names a scope and "1.0.0" names a release, and they are not
the same event.

## v1 Milestones

| M | Status | Deliverable |
|---|--------|-------------|
| 0 | ✅ done | **Scaffolding** — SwiftPM workspace, `make check`, project docs, and `stickiesctl doctor` reporting container location, readability, note count, state-file shape, and Stickies run state |
| 1 | ✅ done | **Read-only fidelity** — `StickiesFormat` parses `<UUID>.rtfd` and `.SavedStickiesState` into a `StickyNote`; `stickiesctl list` and `export`; golden-file tests; every open format question in [ARCHITECTURE.md](ARCHITECTURE.md) answered |
| 2 | ✅ done | **Safe apply** — quit/write/relaunch coordinator with frontmost and ownership guards, container backup and rollback, `stickiesctl import`, bit-faithful export→wipe→import round trip |
| 3 | ✅ done | **Change detection** — SQLite replica, FSEvents watcher, per-note content hashing, version vectors, tombstones, version history; `stickiesctl watch` streaming note-level changes on one Mac |
| 4 | ✅ done | **Two Macs sync** — `FolderTransport` over a write-disjoint shared directory, manifest exchange, apply loop, last-writer-wins with conflict copies, `launchd` agent. First daily-usable release |
| 5 | ✅ done | **End-to-end encryption** — a shared vault key, sealed records and manifests over a transport reduced to opaque bytes, device keypairs and code-verified pairing, `vault` and `pair` commands |

## Scheduled milestones

Milestone numbers continue rather than restarting, and an assigned number is
never reused or reordered: milestones name capability slices, and Milestones 6
and 7 are already cross-referenced by number from four decisions in
[ARCHITECTURE.md](ARCHITECTURE.md) (#6, #8, #41, #55), from
[CHANGELOG.md](CHANGELOG.md), and from two source comments
(`PassReporter.swift`, `Diagnostics.swift`). New work therefore appends from 8,
and **the M column is not the running order** — the Release column is.

Versions carry the ordering, on one rule: **v1.x for everything additive, 2.0.0
reserved for the first network listener.** Milestone 7's LAN transport is that
listener, and it is a genuine posture change in a utility that has so far only
read and written files. It also moves the threat model from "anything that can
write to the folder" to "anything that can reach this Mac on the LAN", which is
a change [SPEC.md](SPEC.md) has to absorb rather than inherit. The object-store
half of the original Milestone 7 does none of that — it is an outbound client to
a service the user configures — so it is ordinary additive work and is split out
as Milestone 11. Bundling the two under one milestone hid the fact that they sit
on opposite sides of the only version boundary that matters here.

Ordering as planned on 2026-09-09. Milestone 8 comes first and gates 1.0.0.
Milestone 9's byte accounting is what decides whether incremental publish in
`localRecords` is worth building, so it stays ahead of anything that would
depend on that answer. Milestone 6 floats — it is a second interface onto
capabilities that already exist and nothing depends on it, though it is also the
milestone that finally requires Xcode, which retires the `make test` workaround
in #11. Milestones 11 through 14 can be reordered freely; they are listed by
rough usefulness, not by dependency.

| M | Release | Status | Deliverable |
|---|---------|--------|-------------|
| 8 | v1.0.0 | ⬜ next | **Trustworthy unattended** — refuse to tombstone a container that read as empty, tell an evicted iCloud file from a missing one, lock the container between processes, assert that syncing is current rather than merely quiet, and exercise the four scenarios that never have been |
| 9 | v1.1.0 | ⬜ planned | **Footprint** — bytes written per pass, counted where they are written; the agent profiled with `mac-sitrep` and the result published under a drift gate |
| 10 | v1.2.0 | ⬜ planned | **Leaving cleanly** — `forget-device`, a named answer for a Mac that leaves, and an uninstall that discharges [SPEC.md](SPEC.md) principle 2 |
| 6 | v1.3.0 | ⬜ optional | **Menu bar app** — sync status, pause/resume, conflict resolution UI, history browser with restore |
| 11 | v1.4.0 | ⬜ planned | **Object-store transport** — an off-LAN backend behind `SyncTransport`, and the first credential this project has had to store |
| 12 | v1.5.0 | ⬜ planned | **Git transport** — `GitTransport` pulling before a pass, committing and pushing its own subtree after |
| 13 | v1.6.0 | ⬜ planned | **Selective sync and retention** — excluding a note or a colour from replication without it reading as a deletion; compaction beyond a fixed count |
| 14 | v1.7.0 | ⬜ planned | **Markdown interoperability** — `.md` import and export as a bridge, never in the sync path |
| 7 | v2.0.0 | ⬜ optional | **LAN peer-to-peer** — Bonjour + TLS, the first network listener |

### Milestone 8 — Trustworthy unattended (v1.0.0)

None of these is a feature. Each is either a way the system can lose a note or a
way it can fail without saying so, and every one of them is cheaper than a menu
bar. They are listed here rather than among the known limitations in
[ARCHITECTURE.md](ARCHITECTURE.md) because a roadmap that lists only capabilities
implies the rest is finished — and because this is the set that has to be closed
before a release can call itself 1.0.0.

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

### Milestone 9 — Footprint (v1.1.0)

- **Count what a pass writes to the folder.** Depends on nothing and is small: a
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

- **Profile the agent with `mac-sitrep`** — the separate project that is the
  source of every figure here that is not the one above. Its workload profiling
  and publishing milestones were both complete as of 2026-08-31, so this waits on
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

### Milestone 10 — Leaving cleanly (v1.2.0)

- **Decide what happens when a Mac leaves.** Today there is exactly one answer —
  `vault reset --force` and re-pair everything else — and it is a fallback rather
  than a choice anyone made. A paired Mac keeps the key and can read anything
  published afterwards; it also still holds, in Stickies, in the clear, every note
  it ever synced, so no amount of rotation retrieves what it already has. That
  argues the current answer is close to right and the work is mostly to say so
  deliberately. Two smaller pieces are separable from that decision: a
  `forget-device` command, because a departed peer's subtree and its counters
  otherwise stay in the folder and in every vector forever, and rotation being a
  named operation rather than a reset that happens to work.

- **Discharge the uninstall promise.** [SPEC.md](SPEC.md) principle 2 says plainly
  that if StickiesSync is uninstalled the user is left with a normal, working
  Stickies. `agent uninstall` removes the `launchd` job; nothing removes the
  replica, the container backups, the vault key, or this Mac's subtree in the
  shared folder. Small, and a principle stated that flatly is worth a command
  that keeps it.

### Milestone 6 — Menu bar app (v1.3.0, optional)

Sync status, pause/resume, conflict resolution, and a history browser with
restore. Most of the groundwork is already deliberate rather than incidental:
`Diagnostics` judges the container so the CLI and the app render the same problem
list rather than each inventing an opinion (#8), `PassReporter` exists so a pass
reads the same way in the log and in the app, and `SyncService` was put in
`StickiesSyncKit` rather than in the executable specifically so something other
than the CLI could drive it (#41). What remains is an app bundle and a UI, not
new sync behaviour.

Two things it drags in. It needs full Xcode, which this Mac has never had — and
installing it retires the injected toolchain paths in the Makefile on their own
(#11). And an app that can pause, resume, or resolve a conflict is a second
writer to the container, which turns Milestone 8's process lock from a
theoretical hazard into a prerequisite.

### Milestone 11 — Object-store transport (v1.4.0)

The same three `SyncTransport` methods against an object store, for the case the
shared folder cannot cover: two Macs that are never on the same LAN and share no
cloud drive. Two properties carry over unchanged and are most of why this is
ordinary work. Encryption sits above the transport (#55), so the backend moves
opaque bytes and contains no crypto; and the write-disjoint layout (#6) maps
directly onto key prefixes, so the reason no underlying service ever has to
resolve a conflict survives the move.

The genuinely new thing is a credential. The vault key lives in an owner-only
file beside the replica, and the argument for that (#54) is that the notes
themselves are plaintext two directories away, so encrypting the cache would
protect nothing. That argument does not transfer to an access key that grants
write access to a remote bucket, which is a different thing to lose. Worth
deciding rather than copying the existing pattern by reflex.

One failure mode to design for up front: an eventually-consistent listing looks
exactly like a peer with fewer notes, which is the same shape as the iCloud
eviction problem Milestone 8 fixes. Whatever distinction that milestone draws
between "absent" and "not here yet" should be the one this transport reuses.

### Milestone 12 — Git transport (v1.5.0)

A `GitTransport` conforming to the same three methods `FolderTransport` does,
pulling before a pass and committing and pushing its own subtree after. Distinct
from the shared-directory transport, which already covers iCloud Drive,
Syncthing, Dropbox and SMB with no code at all, because nothing keeps a
repository in step on its own: the pull and the push are the transport's job.
Points in its favour and against:

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

### Milestone 13 — Selective sync and retention (v1.6.0)

Two things that both come down to deciding what is kept.

**Selective sync — excluding a note, or a colour, from replication.** The
obvious implementation is the dangerous one. Absence is how this system
expresses a deletion: `Replica.reconcile` tombstones everything it did not see,
and the tombstone is published. So an exclusion that works by simply not
offering a note to the replica deletes that note on every other Mac. The
exclusion has to be expressed explicitly, at a layer that never lets an excluded
note arrive at reconciliation looking like an absence — and the peers have to
distinguish "withheld" from "gone". That is the whole design problem, and it is
not visible from the feature description.

**Compaction beyond a fixed count.** Retention today is twenty versions per note
and the ten newest container backups, pruned by count rather than age or size,
so a Mac that syncs heavily keeps a *shorter* history than a quiet one — the
opposite of the intent. The same fixed count is also spent on window moves: a
note dragged around repeatedly consumes its twenty versions on positions rather
than edits, because a version row stores the whole note either way. A policy in
terms of age or total bytes fixes the first; state-only deltas would fix the
second and are the kind of complexity worth demanding evidence for.

### Milestone 14 — Markdown interoperability (v1.7.0)

`.md` import and export as a bridge to other tools, converted through
`NSAttributedString`. The rich-text package stays canonical and Markdown never
enters the sync path, so it costs ordinary syncing nothing. Four things worth
knowing before starting:

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
### Milestone 7 — LAN peer-to-peer (v2.0.0, optional)

Bonjour discovery and a TLS socket between Macs on the same network, behind the
same `SyncTransport` as everything else. Faster than waiting for a cloud service
to move a file, and it works where there is no such service at all.

It is the major version because of what it changes rather than what it adds.
Everything built so far reads and writes files; this advertises a service and
accepts connections, and the adversary the design has been written against so
far — "anything that can write to the folder" — becomes "anything that can reach
this Mac on the LAN". [SPEC.md](SPEC.md) states the current model and would have
to absorb the new one rather than inherit it silently.

The encryption work makes this less alarming than it sounds. Because sealing
sits above the transport (#55), notes are ciphertext before the socket ever sees
them, so TLS here is defence in depth and a mistake in the TLS setup does not
expose a note. The pairing model also transfers unchanged: a code carried
between two screens is what authenticates a peer, and that argument does not
depend on the medium.

It stays optional because the shared folder already covers every case these Macs
actually have.

## Unscheduled

Not ordered, not versioned, and in two cases not obviously wanted.

- **Incremental publish in `localRecords`** — conditional on Milestone 9. If
  bytes-per-pass turns out to track note count, this is the fix and it gets a
  version then; if it does not, the limitation is retired without code. Listing
  it here rather than as a milestone is the point: the measurement decides.
- **Character-level merge of rich text**, replacing conflict copies where the
  change is unambiguous. This sits against a stated position rather than merely
  being unbuilt — [SPEC.md](SPEC.md) argues that an automatic merge right 95% of
  the time is worse than a conflict copy right always, because the 5% is silent.
  Scheduling it would mean revisiting that argument first, which is a different
  kind of task from building it.
- **Syncing Stickies application preferences** (default colour, translucency). A
  v1 non-goal, and nothing has happened since to make it wanted.
- **Verified support for macOS versions other than those tested.** Not a
  milestone but a standing condition: supporting a version means having tested
  against it, so this happens when a Mac running something else turns up.
- **Signed and notarized distribution**, if the project ever stops being
  personal. Gated on a decision rather than on work.
