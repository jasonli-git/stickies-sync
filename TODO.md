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

## Milestone 4 — Two Macs sync ✅

- [x] `SyncRecord` — one note version as it travels: content, full version
      vector, origin device, tombstone flag
- [x] `DeviceManifest` — what one Mac claims to hold, so a peer fetches only the
      records it lacks
- [x] `SyncTransport` protocol and `FolderTransport` — write-disjoint layout,
      each device writing only under `devices/<its own id>/`
- [x] `Replica.integrate(_:)` — adopt a remote version **without** bumping the
      local counter, which is the Milestone 3 limitation this milestone exists to
      fix
- [x] `Replica.localRecords()` — everything this Mac knows, as publishable
      records
- [x] `MergePlan` — pure decision logic over local and remote vectors: adopt,
      publish, ignore, or conflict
- [x] Deterministic conflict copies — both Macs must derive the same winner and
      the same new identifier, or each creates its own copy and they never
      converge
- [x] `StickiesSyncKit` composition root with `SyncService`: read, reconcile,
      pull, apply, integrate, publish
- [x] `stickiesctl sync` with `--folder`, `--once`, `--dry-run`
- [x] Persisted configuration so the agent runs without arguments
- [x] `launchd` agent, installable from the CLI
- [x] Tests: merge decisions, deterministic conflict identity, and a full
      two-replica convergence test over one shared folder
- [x] Local end-to-end with two simulated Macs before touching real hardware —
      149 tests, plus the same thing driven through the real CLI with two
      `--home` directories and one shared folder

- Note: the convergence test found a bug that review did not. Integrating a
  resolution that kept local content wrote an empty history row onto the key
  already holding that content, erasing it; the Mac then published an older
  version and overwrote its peer's correct text with stale text. Two-Mac
  behaviour is not reviewable by reading — it needed the pair harness.
- Note: **verification between two real Macs is partly done** (2026-08-18,
  mac-mini.local → jasons-macbook-pro.local over iCloud Drive). Confirmed on real
  hardware: iCloud delivered the folder unprompted, the peer resolved by name,
  three records arrived and applied, Stickies rendered all three correctly, and a
  note created on the second Mac published back. Records relayed onward kept the
  originating Mac in `Origin`, against real bytes rather than a stub. A second
  round after 0.5.1 confirmed the geometry fix on the laptop: `make check` at 170
  tests, migration 3 applied, and the first scan on a replica whose history was
  built independently of the mini's reported `No changes.` — the digest backfill
  holds where the histories differ, which is the case the mini alone could not
  test. Still untested: clock skew changing the conflict tiebreak, a sync landing
  while Stickies is running on the receiving Mac, and delivery through Syncthing.
- Note: **a smaller display rewrites geometry, and the drift syncs back.** The
  mini's notes carry frames from its larger screen; two of the three sat outside
  the laptop's 1512×982 desktop (`2000,1000` and `8,1110`). Stickies drew both
  clamped on screen, and on quit had rewritten one of them to `8,749` while
  leaving the other at `2000,1000` — a partial, inconsistent rewrite, not a
  uniform clamp. Z-orders shifted too. The next `sync` then classified all three
  of the peer's notes as `edited: window only (here)` and published them, so
  simply opening Stickies on the second Mac moves the first Mac's notes. This
  makes the "seen once, not reproducible" window-move note under Milestone 2
  reproducible: mismatched display sizes are the trigger. `window only` is
  currently just a label in `Replica.swift`; there is no way to keep
  geometry-only changes local, and that is the obvious fix to consider.
  **Fixed in 0.5.1** by hashing geometry separately and never travelling it.
  Verified on the laptop: moving a note reports `moved (stays on this Mac)`,
  `sync` then says `Up to date.`, and a re-scan says `No changes.` — the move is
  absorbed exactly once. On the wire the manifest is byte-identical apart from
  `PublishedAt`, and the note's record differs only in `RecordedAt`; frame,
  digests and version vector are unchanged. An idle sync rewrites nothing at all,
  so the agent will not churn iCloud on its backstop timer.
- Note: **the pre-0.5.1 drift left permanent residue in `Origin`.** Those spurious
  `window only` publishes were genuine authored versions at the time, so the
  laptop became the origin of all three of the mini's notes; every record in both
  subtrees now reads `8C9EF3BF…` (the laptop), where before the drift the mini's
  own three read `8120F0D9…`. Stopping the geometry travelling does not unwind
  attribution already written. This is not cosmetic: `MergeDecision` uses `origin`
  as the last-writer-wins tiebreak and seeds `conflictCopyID` from it, so a future
  tie on these notes resolves differently than it would have, and it contradicts
  the intent stated in `Schema.swift` that a note keep its originating device
  rather than be re-attributed. Harmless here because these are test notes with no
  contested history; worth deciding before real notes accumulate, since there is
  currently no way to re-attribute a note short of re-authoring it.
- Note: nothing on the wire is encrypted. Anything with read access to the sync
  folder can read every note, and could publish a `devices/` subtree of its own
  and be believed. Milestone 5 closes both.
- Note: the first records published to the real iCloud folder carried an *empty*
  origin. `ALTER TABLE … DEFAULT ''` left every Milestone 3 row blank, and the
  migration could not fill it because it runs before the device row exists. Now
  backfilled on open (ARCHITECTURE #43). No test caught this — only looking at
  the bytes that actually landed in the folder did.
- Note: a peer that goes away is never forgotten — its subtree stays in the
  folder and its counters stay in every vector. Harmless, untidy, and there is
  no `forget-device` command.
- Note: **a note that cannot be read is published as a deletion.** Observed on the
  mini's live agent, 2026-08-19, in `~/Library/Logs/StickiesSync.log`: one pass
  reported `- 53975D6B… deleted (here)` and published the tombstone, and the
  warning printed with it names the cause — `NSPOSIXErrorDomain Code=4`,
  "Interrupted system call", a transient EINTR reading the package. The next pass
  read it fine and reported `^ … reappeared`, so the note blinked out and back on
  the peer. `StickiesReader` keeps unreadable notes out of `snapshot.notes`,
  `Replica.reconcile` treats any note missing from the snapshot as deleted, and
  `SyncService` publishes that. One flaky read costs one note; the container-access
  lapse seen on the laptop fails *every* read at once, which would tombstone the
  whole container on the peer. Recoverable through history (F8), but it is SPEC
  principle 1 failing in the field. Fix: `reconcile` has to be told which
  identifiers exist-but-were-not-read and must not tombstone them — narrow, in the
  spirit of #16 and #24, so one bad note still costs only that note.
- Note: nothing locks the container between processes. A hand-run `stickiesctl`
  command and the installed agent can both be inside `ApplyCoordinator` at once,
  each having quit Stickies and each writing. Not observed; avoided by hand here
  by stopping the agent before deleting the test notes, which is not a guarantee.

- [x] **The agent survives a reboot** — verified on the laptop 2026-08-18: cold
      `launchd` start at login, new pid, no granted ancestor, `container:
      readable`, initial pass completed, peer resolved, and zero occurrences of
      `denied`, `permission` or `NOT READABLE` in the whole log. Milestone 4's last
      open question, closed.
- Note: the prediction that the agent would fail was wrong twice over — first
  that it would not work at all, then that it only worked by inheriting from the
  process that bootstrapped it. What survived was the request behind it rather
  than the diagnosis: the install preflight and the `container:` banner line exist
  because of it, and they turn this from an afternoon of probing into a one-glance
  check.
- Note: container access lapsed once mid-session on the laptop with nobody
  touching System Settings, and neither Mac can reconstruct why. Today's green
  result does not rule out a recurrence; it only shows the agent starts correctly.
  Worth glancing at `~/Library/Logs/StickiesSync.log` occasionally rather than
  assuming silence means syncing.
- [x] ~~Confirm the agent survives a reboot.~~ Installing it inside a session that
      already holds Full Disk Access proves nothing: `launchd` starting the job at
      login, with no granted process anywhere in the chain, is the case that could
      fail. Reinstall, reboot, read the first lines of
      `~/Library/Logs/StickiesSync.log` — the banner now states container
      readability there precisely so this is a one-glance check. Milestone 4 is not
      closed until one Mac has done it.
- Note: my own "no Full Disk Access needed" measurement was the weakest link in
  the project and stood for three milestones. It inferred an absent grant from two
  denials without checking what caused them; two Macs and a sandbox-disabled
  re-run were needed to break it. Worth distrusting any conclusion of the form
  "X is not required" that rests on a negative observation from a single machine.

## Parked / needs user input

- Done 2026-08-18: F2 split into F2 (replicated: text, formatting, attachments,
  colour, translucency, float-on-top) and F2a (captured but machine-local: frame,
  expanded state, multi-screen frames, z-order). The vision paragraph and a new
  user-experience bullet say the same. The "vanish and reappear in place" line was
  left alone on inspection — it describes the receiving Mac, where a note now
  reappears in place more reliably than before, so it was never wrong.

- **Still open.** [SPEC.md](SPEC.md) says StickiesSync "requires Full Disk Access
  to read another application's container", and gives that as the reason the Mac
  App Store is out of scope. Measurement contradicted the first half (ARCHITECTURE #19): no
  permission is needed. The App Store conclusion still holds, but because of the
  sandbox. The spec is only edited on request — say the word and both sentences
  get corrected.
