# Dock Pin

A native macOS app that keeps the Dock on one chosen monitor. It remembers the selected physical display and moves the Dock back when it drifts (after wake, display changes, or ordinary use).

## Requirements

- macOS 14 or later
- Swift 6 toolchain
- Accessibility permission, needed to move the pointer (see below)

## Build

```sh
swift build
swift test
```

## Probe CLI

`dockpin-probe` is a development CLI around the core library (`DockPinCore`).

```sh
swift run dockpin-probe displays                          # list displays (index, UUID, frame); read-only
swift run dockpin-probe locate                            # which display holds the Dock; read-only
swift run dockpin-probe status                            # saved selection + current Dock location; read-only
swift run dockpin-probe relocate --to <uuid|index> --once # ONE bounded attempt; MOVES THE POINTER
swift run dockpin-probe watch --to <uuid|index>           # keep the Dock pinned until Ctrl-C; MOVES THE POINTER
```

`watch` saves the selection (unless the display is ambiguous), so `watch` without `--to` reuses it.

## Accessibility permission

Moving the Dock works by moving the pointer to the bottom edge of the target display, which requires Accessibility access. Grant it to the app (or to the terminal running the probe) in System Settings > Privacy & Security > Accessibility. Without it, the tool reports the problem and does not touch the pointer.

Do not run another Dock controller (for example DockLock) at the same time.

## Status

Early development. No GUI yet.

- Phase 1: display identity, Dock locator, enforcement policy, relocator, probe CLI. See `docs/PHASE1-NOTES.md`.
- Phase 2: persisted selection, enforcement driver, observable status, `watch` and `status` commands. See `docs/PHASE2-NOTES.md`.

Scope and background: `docs/initial-brief.md`.
