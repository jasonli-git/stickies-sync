# stickies-sync

Automatic synchronization for Apple's Stickies app. Stickies has no sync of its
own — a note written on one Mac exists only on that Mac — so StickiesSync runs
as a background agent that keeps notes consistent across several Macs owned by
the same person, over a transport the user chooses and controls rather than a
proprietary cloud. It models each sticky as an individual object with an
identity and a history, which is what makes per-note conflict resolution and
deleted-note recovery possible where a directory copy would only overwrite.

Built for its author's own Macs. See [SPEC.md](SPEC.md) for what it is meant to
do and [ARCHITECTURE.md](ARCHITECTURE.md) for how it is built.

## Features

Milestones 0 and 1 are complete: StickiesSync can read a Mac's notes completely
and export them without altering a byte. It writes nothing yet. The rest of this
list is the plan, tracked in [ROADMAP.md](ROADMAP.md).

- **Health check** *(built)* — `stickiesctl doctor` locates the Stickies
  container, reports whether it can be read, counts note packages, checks that
  the window-state file parses, flags entries it cannot classify, notices a
  surviving pre-sandbox database, and reports whether Stickies is running and
  frontmost.
- **Reading notes** *(built)* — `stickiesctl list` shows every note with its
  size, screen position, colour, z-order, floating and translucency flags, and
  first line of text. Anything in the container that could not be read is
  reported rather than skipped.
- **Portable export** *(built)* — `stickiesctl export` writes a versioned
  archive carrying each note's package bytes and window state verbatim, verified
  byte-identical to the container it came from.
- **Per-note change detection** — a change to one sticky syncs that sticky, not
  the whole directory.
- **Safe write-back** — remote changes are applied by quitting Stickies,
  writing, and relaunching it, because Stickies overwrites its files from memory
  while running. Writes are batched, never happen while you are typing in
  Stickies, and are preceded by a container backup.
- **Full fidelity** — text, rich formatting, embedded attachments, colour,
  translucency, window frame, collapsed state, and z-order.
- **Conflict copies** — when the same note changed on two Macs, both versions
  survive and one appears as a new sticky. Nothing is decided silently.
- **Version history and deleted-note recovery.**
- **Choice of transport** — a shared directory first, which covers iCloud Drive,
  Syncthing, Dropbox, or an SMB mount without code changes; LAN peer-to-peer and
  object stores later.
- **End-to-end encryption**, so a transport you do not control never sees
  plaintext.

## Tech stack

- **Language and build:** Swift 6, SwiftPM, deployment target macOS 14.
  `swift-argument-parser` is the only third-party dependency.
- **Format layer:** Foundation and CoreGraphics — RTFD packages held as bytes,
  window state as XML property lists.
- **System integration:** AppKit for application run state and rich-text
  reading; FSEvents for change detection (Milestone 3).
- **Local state:** SQLite under `~/Library/Application Support/StickiesSync/`
  (Milestone 3).
- **Tests:** swift-testing, 78 tests, including golden-file tests against a real
  `.SavedStickiesState`.

## Setup

Requires macOS and the Swift 6 toolchain (Command Line Tools are enough; full
Xcode is not needed until the optional menu-bar app).

```bash
git clone https://github.com/jasonli-git/stickies-sync.git
cd stickies-sync
make check
make doctor
```

Run `make test` rather than `swift test` — on a Mac with Command Line Tools and
no Xcode, SwiftPM does not wire up swift-testing on its own, and the Makefile
injects the missing toolchain paths. See limitation #11 in
[ARCHITECTURE.md](ARCHITECTURE.md).

`stickiesctl doctor` output on a Mac with no stickies yet:

```
StickiesSync doctor

  ✔  Stickies container             /Users/you/Library/Containers/com.apple.Stickies/Data/Library/Stickies/
  !  Note packages                  none — there are no stickies to sync yet
  ✔  Unrecognised entries           none
  ✔  Saved window state             parses as a plist array of 0 entry/entries
  ✔  State/notes agreement          0 note(s), 0 state entry/entries
  ✔  Legacy Stickies database       not present
  ✔  Stickies process               not running — reads and writes are both safe
  ✔  StickiesSync state directory   writable at /Users/you/Library/Application Support/StickiesSync/

Result: warning
```

Add `--json` for machine-readable output. Warnings do not fail the run; failures
exit non-zero.

Listing and exporting notes:

```bash
swift run stickiesctl list
swift run stickiesctl export -o notes.plist
```

`export` writes an XML property list holding every note's package bytes and
window state unchanged. Both commands report anything in the container they could
not read on standard error, and exit non-zero if that included a note's content.

Every command takes `--home <path>` to read a synthetic container instead of the
real one, which is how the test suite exercises them.

**No special permission is needed.** Reading Stickies' container was measured to
require no Full Disk Access grant on macOS 26.6.1 — see decision #19 in
[ARCHITECTURE.md](ARCHITECTURE.md). StickiesSync still cannot be sandboxed or
shipped through the Mac App Store, because the sandbox forbids reading another
application's container regardless.

## Status

v0.2.0 — Milestones 0 and 1 of 7 complete. Notes can be read and exported;
nothing is written and nothing synchronizes yet. Progress is in
[ROADMAP.md](ROADMAP.md); what shipped is in [CHANGELOG.md](CHANGELOG.md).
