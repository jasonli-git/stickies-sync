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

Milestone 0 is complete; only the health check below is built so far. The rest
of this list is the plan, tracked in [ROADMAP.md](ROADMAP.md).

- **Health check** *(built)* — `stickiesctl doctor` locates the Stickies
  container, reports whether it can be read, counts note packages, checks that
  the window-state file parses, flags entries it cannot classify, notices a
  surviving pre-sandbox database, and reports whether Stickies is running and
  frontmost.
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
- **Format layer:** Foundation — RTFD packages and XML property lists.
- **System integration:** AppKit for application run state; FSEvents for change
  detection (Milestone 3).
- **Local state:** SQLite under `~/Library/Application Support/StickiesSync/`
  (Milestone 3).
- **Tests:** swift-testing, 24 tests.

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

Add `--json` for machine-readable output, or `--home <path>` to probe a
synthetic layout instead of the real container. Warnings do not fail the run;
failures exit non-zero.

Reading another application's container requires **Full Disk Access**. If doctor
reports `permission denied` on the container, grant it to the terminal or
program running `stickiesctl`. This requirement is also why StickiesSync cannot
be sandboxed or shipped through the Mac App Store.

## Status

v0.1.0 — Milestone 0 of 7 complete. Nothing synchronizes yet. Progress is in
[ROADMAP.md](ROADMAP.md); what shipped is in [CHANGELOG.md](CHANGELOG.md).
