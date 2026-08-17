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

## Parked / needs user input

- [SPEC.md](SPEC.md) says StickiesSync "requires Full Disk Access to read another
  application's container", and gives that as the reason the Mac App Store is out
  of scope. Measurement contradicted the first half (ARCHITECTURE #19): no
  permission is needed. The App Store conclusion still holds, but because of the
  sandbox. The spec is only edited on request — say the word and both sentences
  get corrected.
