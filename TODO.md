# StickiesSync — TODO

Working list for the current milestone. Longer-horizon items live in
[ROADMAP.md](ROADMAP.md).

## Milestone 0 — Scaffolding ✅

- [x] SwiftPM package targeting macOS 14+, Swift 6 language mode, with
      `StickiesFormat`, `StickiesStore`, and the `stickiesctl` executable
- [x] `.gitignore` and a `Makefile` exposing `make build`, `make test`,
      `make check`, and `make doctor`
- [x] `StickyID` — an identifier that tolerates both the modern UUID package
      names and the legacy numeric ones, with package-filename conversion
- [x] `StickiesDirectory` — pure path arithmetic over a container root, with no
      filesystem access, so tests can point it at a fixture directory
- [x] `ContainerLocator` — resolves the real container and legacy database paths
      from a home directory
- [x] `StickiesApp` — reports whether Stickies is running and whether it is
      frontmost
- [x] `ContainerProbe` — produces a `ContainerReport` of observable facts:
      readability, note count, unrecognised directory entries, state-file
      shape, legacy database presence, run state
- [x] `ContainerReport.diagnostics()` — turns facts into pass/warn/fail
      diagnostics, reusable by a future menu-bar app
- [x] `stickiesctl doctor` with human-readable and `--json` output, and a
      non-zero exit code on failure
- [x] Tests for identifier round-tripping, path arithmetic, probing a synthetic
      container, and diagnostic interpretation — 24 tests, all passing
- [x] The six project documents

- Note: `swift test` fails outright on a Command Line Tools-only Mac —
  swift-testing ships but SwiftPM does not wire up its framework, macro plugin,
  or interop dylib, and XCTest is absent entirely. `make test` injects the three
  paths, conditionally on the CLT layout being active, so installing Xcode makes
  the workaround drop out. Recorded as ARCHITECTURE #11. Revisit if Xcode ever
  gets installed for the Milestone 6 app bundle.
- Note: this Mac has no stickies at all, so doctor has only ever been exercised
  against an empty container and synthetic fixtures. Milestone 1 must start by
  creating real notes and re-running doctor — a populated container is what
  will reveal whether `.SavedStickiesState` tracks the note packages live or
  only at quit.
- Note: `StickiesDirectory.packageURL` returns a URL with a trailing slash,
  since an RTFD package genuinely is a directory. Harmless for path
  construction, but string comparisons against it need to expect it.

## Milestone 1 — Read-only fidelity ✅

- [x] Measure the real format on macOS 26.6.1: package layout, where colour
      lives, exact state keys and value types, and write cadence
- [x] `PlistValue` — a typed, `Sendable`, `Equatable` property-list value, so a
      state entry can be carried around and compared without `Any`
- [x] `GeometryString` — strict parsing and formatting of the `{{x, y}, {w, h}}`
      and `{w, h}` strings Stickies stores, rejecting malformed input instead of
      silently yielding a zero rect
- [x] `StickyColor` and `StickyPalette` — the four `{Red, Green, Blue, Alpha}`
      dictionaries
- [x] `StickyWindowState` — typed frame, expanded size, z-order, floating,
      translucency, spell-checking mask, and the palette, retaining the entry's
      unrecognised keys verbatim so a future macOS key survives a read/write
      cycle
- [x] `SavedStickiesState` — parse and serialize the plist array, look entries
      up by identifier, keep unparseable entries verbatim
- [x] `NotePackage` — the `.rtfd` payload as its constituent files, kept as
      bytes rather than a re-serialized `NSAttributedString`, because Milestone
      2 requires a bit-faithful round trip
- [x] `StickyNote` — identity, package, and window state
- [x] `NoteArchive` — versioned portable archive; the shape Milestone 2's
      `import` and Milestone 4's record codec reuse
- [x] `StickiesReader` — reads a container into a snapshot of notes, state
      entries with no package, packages that would not validate, unparseable
      state entries, and unrecognised directory entries
- [x] `stickiesctl list` — one row per note with size, position, colour,
      z-order, flags, and first line of text
- [x] `stickiesctl export` — writes a `NoteArchive`, verified byte-identical to
      the container it came from
- [x] Golden-file tests against a real `.SavedStickiesState` captured from this
      Mac, plus round-trip and reader tests — 78 tests, all passing

- Note: two bugs were found by tests rather than by reading the code, both in
  `GeometryString`. The first miscounted braces and rejected every real frame;
  the second accepted `{{8, 1110} {300, 200}}` with the separating comma
  missing. The parser now matches a punctuation skeleton (ARCHITECTURE #18).
  Lenient geometry parsing is worth distrusting on sight.
- Note: UI scripting is unavailable — `osascript` has no Accessibility grant on
  this Mac, so notes could not be created through the Stickies interface. The
  format was measured by hand-writing packages instead, which incidentally
  proved Stickies accepts foreign notes. If Milestone 2 wants UI-driven test
  fixtures, that grant has to be given first.
- Note: the two test notes created during this milestone are still in the real
  container. They are useful for Milestone 2's round-trip work; delete them from
  Stickies when they stop being useful.
- Note: the `ExpandFrameY` value is written back as an integer when whole. It is
  a y coordinate and could in principle be fractional, in which case it is
  written as a real. Nothing depends on this beyond keeping a rewritten state
  file diffable against one Stickies wrote.

## Milestone 2 — Safe apply ✅

- [x] `StickiesProcessControlling` — run state, quit-and-wait, launch, behind a
      protocol so tests never quit the real Stickies
- [x] `ContainerBackupStore` — copy the container to a timestamped backup,
      restore from one, prune old ones
- [x] `ContainerWriter` — write note packages and merge `.SavedStickiesState`
      via a scratch directory and an atomic replace, preserving entries for notes
      the write does not touch, including ones this version cannot parse
- [x] `ApplyCoordinator` — quit, then validate, back up, write, roll back on
      failure, relaunch only what it quit
- [x] `StickiesSnapshot` carries the parsed `SavedStickiesState`, so the writer
      merges against the document the validation already read
- [x] `stickiesctl import` with `--replace` and `--dry-run`
- [x] Tests: the three guards, rollback on a failed write, state-file merge
      including unparseable entries, and a bit-faithful export→wipe→import round
      trip — 101 tests, all passing
- [x] End-to-end runs against the real Stickies, quitting and relaunching it

- Note: the first draft of the coordinator refused to write whenever *anything*
  in the container was unreadable. A test caught that as over-strict: the writer
  keeps unparseable state entries verbatim, so writing cannot damage them, and
  refusing would disable sync over one odd entry. The rule is now narrow —
  refuse only where the request would overwrite or delete a note whose package
  could not be read (ARCHITECTURE #24).
- Note: **Stickies may move a note's window and renumber z-order after loading
  what we wrote.** Seen once, on an import that introduced a brand-new note:
  two notes ended up repositioned and their z-orders swapped. Six later imports,
  including ones performed while Stickies was running, honoured written frames
  exactly, so it is not reproducible on demand. Content, colour, size, floating
  and translucency were preserved every time. Recorded as a limitation; position
  is best-effort because the final say belongs to Stickies.
- Note: the real container now holds three test notes, one of them created by
  `import` rather than by Stickies. Useful for Milestone 3's watcher; delete them
  when they stop being useful.
- Note: `ApplyOutcome` reports `written` as everything requested rather than
  everything that changed — a note written identically to what was already there
  still counts. Milestone 3's change detection is what makes "actually changed"
  answerable.

## Milestone 3 — Change detection ✅

- [x] `SyncEngine` module, depending on `StickiesFormat` only — it must not learn
      what a Mac or a network is
- [x] `Database` — a thin wrapper over the system SQLite, so the dependency count
      stays at one
- [x] Schema and migrations: `device`, `notes`, `version_vectors`,
      `note_versions`
- [x] `PlistValue.canonicalBytes` — a deterministic encoding, since Swift's own
      hashing is not stable across runs
- [x] `NoteDigest` — separate content and window-state digests, so a note that
      only moved can be told apart from one that was edited
- [x] `VersionVector` — per-note, per-device counters; ordering without clocks
- [x] `Replica.reconcile(with:)` — classify what changed, bump vectors, append
      history, record tombstones, all in one transaction
- [x] `ContainerWatcher` — FSEvents over the container, debounced
- [x] `stickiesctl scan` — one reconcile, printing what changed
- [x] `stickiesctl watch` — the same, continuously
- [x] `stickiesctl history` — versions retained per note, deleted notes included
- [x] `stickiesctl restore` — put a retained version back through the apply
      coordinator
- [x] Tests: digest stability, vector increments, each change classification,
      tombstones and recovery, and no change reported for a container that has
      not changed — 135 tests, all passing

- Note: `watch` printed nothing to a redirected log at first. stdout is
  block-buffered when it is not a terminal, so every report sat in the buffer and
  was lost on Ctrl-C — while the replica recorded the changes correctly, making
  the bug invisible to the tests and visible only when watching a log file.
  Fixed with line buffering. Worth remembering for the Milestone 4 agent, which
  will log to a file by definition.
- Note: an `import` does not update the replica, so the next scan attributes the
  imported change to this Mac. Harmless now — every change really does originate
  here — but Milestone 4 must record an arriving note under the *originating*
  Mac's version instead, or two Macs will keep re-stamping each other's edits and
  never converge. This is the single most important thing to get right next.
- Note: a window move retains a full note version, same as an edit. Twenty
  versions of a note that was only dragged around is a waste, but storing
  state-only deltas is not worth the complexity yet.
- Note: the three test notes are still in the real container and the replica now
  has history for them, including one delete-and-restore cycle. Useful for
  Milestone 4's two-Mac work.

## Milestone 4 — Two Macs sync

- [ ] `SyncRecord` — one note version as it travels: content, full version
      vector, origin device, tombstone flag
- [ ] `DeviceManifest` — what one Mac claims to hold, so a peer fetches only the
      records it lacks
- [ ] `SyncTransport` protocol and `FolderTransport` — write-disjoint layout,
      each device writing only under `devices/<its own id>/`
- [ ] `Replica.integrate(_:)` — adopt a remote version **without** bumping the
      local counter, which is the Milestone 3 limitation this milestone exists to
      fix
- [ ] `Replica.localRecords()` — everything this Mac knows, as publishable
      records
- [ ] `MergePlan` — pure decision logic over local and remote vectors: adopt,
      publish, ignore, or conflict
- [ ] Deterministic conflict copies — both Macs must derive the same winner and
      the same new identifier, or each creates its own copy and they never
      converge
- [ ] `StickiesSyncKit` composition root with `SyncService`: read, reconcile,
      pull, apply, integrate, publish
- [ ] `stickiesctl sync` with `--folder`, `--once`, `--dry-run`
- [ ] Persisted configuration so the agent runs without arguments
- [ ] `launchd` agent, installable from the CLI
- [ ] Tests: merge decisions, deterministic conflict identity, and a full
      two-replica convergence test over one shared folder
- [ ] Local end-to-end with two simulated Macs before touching real hardware

## Parked / needs user input

- [SPEC.md](SPEC.md) says StickiesSync "requires Full Disk Access to read another
  application's container", and gives that as the reason the Mac App Store is out
  of scope. Measurement contradicted the first half (ARCHITECTURE #19): no
  permission is needed. The App Store conclusion still holds, but because of the
  sandbox. The spec is only edited on request — say the word and both sentences
  get corrected.
