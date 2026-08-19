# Changelog

All notable changes to StickiesSync. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/).

## [0.6.0] — 2026-08-19

Milestone 5. Nothing in the sync folder is readable any more, and nothing
published without the vault key is believed.

### Added

- **Every record and manifest is sealed** with AES-GCM under one key shared by
  your Macs. The folder gives up note contents, note identifiers, and your Macs'
  names no longer; what remains visible is how many Macs there are, how many notes,
  how big each is, and when each changed.
- **A subtree published without the key is refused by name and skipped.** Before
  this, anything able to write to the folder could invent a `devices/` subtree and
  have its notes applied straight into Stickies. A peer still publishing the
  unencrypted records that predate this release is refused the same way rather
  than believed for compatibility's sake.
- **`stickiesctl vault status|init|reset`.** `status` reports the vault, the key
  file's permissions, and — the part that matters — how many of each peer's
  records actually open, because a Mac holding the wrong key otherwise looks
  exactly like a Mac with nothing to do.
- **`stickiesctl pair request|list|approve|complete`.** Pairing runs over the sync
  folder and is verified by a twelve-character code carried between the two Macs by
  hand. `approve` refuses unless the code matches the request it found: anything
  with write access to the folder can publish a request of its own, so the code is
  what establishes who is asking.
- `doctor` reports the vault, and `agent install` refuses to install without one —
  the same argument as the container preflight in 0.5.4.

### Changed

- **`SyncTransport` now carries opaque bytes under opaque names** rather than
  records and manifests, which is what SPEC.md principle 5 already said a transport
  is. Encryption sits above it in `SealedChannel`, so Milestone 7's transports get
  it without reimplementing it, and no code path reaches a transport without a key.
- **Sealing is deterministic**, so an unchanged note still re-publishes to
  byte-identical bytes and 0.5.2's "an idle pass writes nothing" survives
  encryption. A random nonce would have rewritten the whole folder every pass.
- `DeviceManifest` no longer carries a publication time. Nothing read it, and
  sealed it would have changed the file's bytes on every pass for no purpose; the
  file's modification time answers the same question.

### Fixed

- **A one-shot `stickiesctl sync` printed no warnings.** They were only ever
  emitted by the watching loop, so a single pass stayed silent about the two
  things most worth saying: a note it could not read, and a peer whose records it
  could not open. It also reported "no other Macs have published yet" when the
  truth was "none this vault can read" — the wrong-key state reading as an idle
  folder is exactly the failure encryption introduces.

### Migration

Both Macs need the key before either syncs again, and there is no unencrypted
mode to fall back to:

1. Update the first Mac, then `stickiesctl vault init`.
2. Update the second, then `stickiesctl pair request` and follow what it prints.

Until step 2 finishes, each Mac refuses the other's records and says so. The old
plaintext records are deleted from the folder by the first sealed publish.

## [0.5.5] — 2026-08-19

### Fixed

- **A note that could not be read was published as a deletion, and the other Mac
  deleted it.** `StickiesReader` keeps an unreadable package out of the snapshot's
  notes, `Replica.reconcile` read that absence as a deletion, and `SyncService`
  published the tombstone. Found in the field rather than by review: on 2026-08-19
  the mini's agent hit a transient `EINTR` reading a package, reported
  `- 53975D6B… deleted (here)`, published the tombstone, and reported
  `^ … reappeared` on the next pass — so the note vanished on the MacBook Pro and
  came back. The unexplained container-access lapse seen earlier on the laptop
  fails every read at once, which would have tombstoned the entire container.
  `reconcile` now takes the identifiers that are present but unread and leaves
  them exactly as it already believed them to be (ARCHITECTURE #53). The exemption
  is per-note: a genuine deletion alongside an unreadable note still travels.

### Added

- Four tests, each verified to fail before the change — two over the replica and
  two over the two-Mac pair, the latter reproducing the observed log including the
  tombstone arriving in the peer's recoverable list.

## [0.5.4] — 2026-08-18

### Fixed

- **The Full Disk Access claim was wrong, and is withdrawn rather than replaced
  with another guess.** 0.5.3 said reading Stickies' container needs no TCC grant,
  inferred from a process that was denied `TCC.db` and `~/Library/Safari` yet read
  the container anyway. A second Mac disproved it: container *and* iCloud-folder
  reads failed with `Operation not permitted` — Unix permissions and the sandbox
  both ruled out — and recovered only when Full Disk Access was granted.
  Re-measuring with the sandbox disabled shows the pattern is not uniform either:
  Stickies, Calculator and Preview containers read fine while **Notes**, Safari,
  Mail and Messages are denied in the same run, so Apple gates specific
  applications rather than containers as a class. No rule this project understands
  explains both Macs, so the code and the docs now say "grant Full Disk Access"
  instead of asserting an answer.
- `doctor`'s permission-denied message no longer calls the denial "unexpected,
  since the container needs no special permission" — which sent the reader looking
  anywhere but at the grant. It now names the remedy and where to find it.

### Added

- `agent install` refuses to install when the container is unreadable, before it
  writes any persistent configuration. An agent that cannot read the container
  still launches, still logs and syncs nothing, failing every thirty seconds into a
  file nobody opens; failing once in front of whoever typed the command is worth
  more than any amount of logging.
- `sync --watch` states container readability in its opening banner, because after
  a reboot the log's first lines are the only evidence available for the one
  question a `launchd` job cannot answer in advance.

## [0.5.3] — 2026-08-18

### Changed

- **SPEC.md corrected on two points, at the user's request.** F2 is split: F2 now
  covers what is replicated (text, formatting, attachments, colour, translucency,
  float-on-top) and a new F2a covers what is captured but belongs to the Mac it
  was set on (frame, expanded state, multi-screen frames, z-order). The vision
  paragraph and a new user-experience bullet say the same. Existing requirement
  numbers are undisturbed.
- Both Full Disk Access claims in SPEC.md are corrected. Reading Stickies'
  container needs no TCC grant of any kind, measured on macOS 26.6.1; the Mac App
  Store remains closed off, but by the App Sandbox, which forbids reading another
  application's container whatever TCC requires. ARCHITECTURE #7 keeps its
  original rationale as the record of what was believed at the time, marked as
  superseded in part by #19.

## [0.5.2] — 2026-08-18

### Fixed

- **A window move no longer writes anything to the shared folder.** It was still
  stamping the note's `updated_at`, which republished the record with a new
  `RecordedAt` and nothing else. That mattered twice over: `recordedAt` is the
  last-writer-wins tiebreak, so dragging a window could decide a future conflict
  over the note's text; and it put a file on the wire for a change that is not
  supposed to travel.
- **Idle sync passes no longer rewrite the manifest.** It carries a publication
  time, so every pass produced a new file and a syncing service re-uploads
  anything whose mtime moved — an agent polling every thirty seconds would have
  pushed thousands of identical manifests a day and woken every other device for
  each one. Measured on a real iCloud Drive folder: three idle passes now write
  nothing.

## [0.5.1] — 2026-08-18

### Fixed

- **Window geometry no longer replicates.** Found by running two real Macs, a
  2560×1440 and a 1512×982: opening Stickies on the smaller display clamps notes
  placed on the larger one and rewrites some of the frames to disk. Those
  rewrites read as ordinary edits and replicated, so every Mac's layout collapsed
  to the smallest screen in the set — opening Stickies on a laptop rearranged the
  desktop Mac's notes, with no user action at all.

  `NoteDigest` now hashes a note in three parts rather than two: content,
  appearance (colour, translucency, floating, and unrecognised keys) and geometry
  (frame, size, z-order, per-screen frames). A geometry-only change is recorded
  so the replica stops noticing it, but advances no version and retains no
  version, so nothing about it can reach another Mac. Adopting a peer's edit
  keeps this Mac's placement; only a note arriving for the first time is seeded
  with the sender's frame.

  This also explains the Milestone 2 note that recorded window drift as "seen
  once, not reproducible on demand". It was always reproducible — the trigger is
  two Macs with different displays, which was not yet possible to arrange.

### Changed

- `NoteChange.isWindowStateOnly` became `isGeometryOnly`, and now means something:
  these changes never leave the Mac. It was previously a display label with no
  effect.
- Migration 3 splits `state_hash` into `appearance_hash` and `geometry_hash`, and
  recomputes both from retained history when the replica opens. Left stale, the
  first scan after upgrading would report every note as edited and two Macs would
  conflict over all of them at once.

## [0.5.0] — 2026-08-17

### Added

- **Milestone 4** — notes sync between Macs. `SyncEngine` gained `SyncRecord`
  (one note version as it travels, carrying its whole vector), `DeviceManifest`
  (what a Mac holds, without the content, so a peer fetches only what it lacks),
  the `SyncTransport` seam with `FolderTransport` over a write-disjoint shared
  directory, and `MergeDecision` — the deterministic resolution rules that let
  two Macs that never speak reach the same answer. `Replica.integrate(_:)` adopts
  a peer's version under *its* identity rather than restamping it locally, which
  is the Milestone 3 limitation this milestone existed to fix.
- `StickiesSyncKit`, the composition root, with `SyncService.syncOnce`: read the
  container, reconcile, pull from peers, apply everything in one batch, integrate,
  publish. Ten notes arriving cause one quit-and-relaunch of Stickies, not ten.
- `stickiesctl sync` (`--folder`, `--watch`, `--dry-run`, `--interval`) and
  `stickiesctl agent install|uninstall|status` for a `launchd` job that syncs at
  login. 149 tests, including a two-simulated-Mac convergence suite covering
  propagation, deletion, relaying, concurrent edits, and edit-versus-delete.
- Conflicts produce a visible second note: the later edit keeps the original
  identifier, the loser becomes a copy in a distinctive colour, offset from the
  original. Both Macs derive the same copy and the same identifier independently.

### Fixed

- `Replica.integrate` wrote a history row with no content when a resolution kept
  local content and only advanced the vector. The row collided with the one
  already holding that content and erased it, after which the Mac published an
  older version and overwrote its peer's correct text with stale text. Found by
  the convergence test, not by review.

## [0.4.0] — 2026-08-17

### Added

- **Milestone 3** — change detection. A new `SyncEngine` module, depending on
  `StickiesFormat` alone so it never learns what a Mac or a network is. It holds
  a SQLite replica at `~/Library/Application Support/StickiesSync/replica.sqlite3`
  with four tables — `device`, `notes`, `version_vectors`, `note_versions` —
  applied through numbered migrations. `Replica.reconcile(with:)` compares the
  container against what the replica believed and records every difference in one
  transaction: additions, edits, deletions as tombstones, and the reappearance of
  a note that had been deleted. `NoteDigest` hashes a note's content and its
  window state separately, so a note that only moved is distinguishable from one
  that was edited. `VersionVector` gives ordering between Macs without consulting
  any clock, including the concurrency detection Milestone 4 will turn into
  conflict copies. `PlistValue.canonicalBytes` supplies the stable encoding the
  digests need.
- `ContainerWatcher` in `StickiesStore` — FSEvents over the container subtree,
  since a note's text lives inside its `.rtfd` package and a directory-only watch
  would miss every edit.
- Four commands: `stickiesctl scan`, `watch`, `history`, and `restore`. Together
  they make deleted-note recovery real — a note deleted from Stickies keeps its
  content in the replica and `restore` puts it back through the same apply path
  as `import`. 135 tests.

### Changed

- `stickiesctl` gained a `--settle` option on `watch` for the FSEvents coalescing
  window.

## [0.3.0] — 2026-08-17

### Added

- **Milestone 2** — the write path. `StickiesSync` can now put notes into the
  Stickies container safely on one Mac. `StickiesProcessControl` (behind
  `StickiesProcessControlling`, so tests never quit the developer's own Stickies)
  reports run state and quits and relaunches the app; `ContainerBackupStore`
  takes timestamped copies of the container, restores them, and prunes old ones;
  `ContainerWriter` installs packages through a scratch directory and an atomic
  replace, merging `.SavedStickiesState` rather than regenerating it; and
  `ApplyCoordinator` sequences the whole thing — quit, validate, back up, write,
  roll back on failure, relaunch only what it quit. `stickiesctl import` applies
  an archive, with `--replace` and `--dry-run`. 101 tests, including the three
  guards, rollback of a failed write, and an export→wipe→import round trip
  verified byte-for-byte.
- Verified against the real Stickies: an import quits it, writes, and relaunches
  it, and Stickies then loads the written notes and keeps their text, colours,
  size, floating and translucency exactly. Window position and z-order turn out
  to be best-effort — see "Fidelity of a write" in
  [ARCHITECTURE.md](ARCHITECTURE.md).

### Changed

- `StickiesSnapshot` now carries the parsed `SavedStickiesState`, so the writer
  merges into the document that validation already read instead of re-reading the
  file. `unreadableStateEntries` became a computed property of it.
- `SavedStickiesState` gained `upsert(_:)` and `remove(_:)`, which replace an
  entry in place so a rewritten state file still diffs cleanly against one
  Stickies wrote.

## [0.2.0] — 2026-08-17

### Added

- **Milestone 1** — read-only fidelity. `StickiesFormat` now models the real
  format: `PlistValue` (typed property-list values), `GeometryString` (strict
  `{{x, y}, {w, h}}` parsing), `StickyColor`/`StickyPalette`,
  `StickyWindowState` (frame, expanded size, z-order, floating, translucency,
  spell-checking mask, four colours, and verbatim retention of keys this version
  does not know), `SavedStickiesState` (per-entry parsing, so one bad entry costs
  one note), `NotePackage` (package contents as bytes, never a re-serialized
  attributed string), `StickyNote`, and `NoteArchive` (a versioned portable
  archive). `StickiesStore` gained `StickiesReader`, producing a
  `StickiesSnapshot` that separates notes read completely from state without a
  package, packages that would not validate, unparseable state entries, and
  unrecognised directory entries. Two new commands: `stickiesctl list` and
  `stickiesctl export`. 78 tests, including golden-file tests against a real
  `.SavedStickiesState`.
- Answers to all five open format questions, measured against a live Stickies
  10.3 on macOS 26.6.1 and recorded in [ARCHITECTURE.md](ARCHITECTURE.md):
  packages are flat `TXT.rtf` plus attachments; **colour lives in
  `.SavedStickiesState`, not the RTF**; the state file is written live rather
  than at quit; and **reading the container needs no Full Disk Access**. Stickies
  was also shown to accept a hand-written note package unchanged, which is the
  foundation Milestone 2's write path stands on.

### Changed

- `doctor`'s permission-denied message no longer presents Full Disk Access as a
  requirement, since it is not one; a denial is now described as unexpected.
- `hasUnreadableData` moved from the CLI onto `StickiesSnapshot`, so the commands
  and the tests share one definition of what counts as data loss.
- `--home` is now a shared option group used by every command rather than a flag
  private to `doctor`.

## [0.1.0] — 2026-08-17

### Added

- **Milestone 0** — scaffolding and health check. A SwiftPM package
  (Swift 6, macOS 14+) with two library targets and a CLI:
  `StickiesFormat` models note identity (`StickyID`, tolerant of both UUID and
  legacy decimal package names) and path arithmetic over a container root
  (`StickiesDirectory`, which classifies a directory listing into notes, the
  state file, and entries it cannot account for); `StickiesStore` resolves the
  real container, legacy database, and application-support paths
  (`ContainerLocator`), reports whether Stickies is running and frontmost
  (`StickiesApp`), and probes a container into a `ContainerReport` of facts that
  `diagnostics()` judges into pass/warn/fail results. `stickiesctl doctor`
  renders those eight diagnostics as text or `--json`, takes a `--home` override
  for probing a synthetic layout, and exits non-zero on failure. `make check`
  builds and runs 24 tests.
- Project documentation: [SPEC.md](SPEC.md), [ARCHITECTURE.md](ARCHITECTURE.md)
  — including the reverse-engineered Stickies 10.3 / macOS 26.6.1 format
  findings and the twelve decisions behind the design —
  [ROADMAP.md](ROADMAP.md), [TODO.md](TODO.md), and this file.
