# Changelog

All notable changes to StickiesSync. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/).

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
