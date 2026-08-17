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

## Milestone 1 — Read-only fidelity

Not started; tasks will be written when the milestone is approved. The open
format questions it must answer are listed under "The Stickies data format" in
[ARCHITECTURE.md](ARCHITECTURE.md).

## Parked / needs user input

- Nothing currently parked.
