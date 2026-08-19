# Changelog

All notable changes to StickiesSync. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/).

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
