# Changelog

All notable changes to StickiesSync. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/).

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
