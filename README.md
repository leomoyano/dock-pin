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
swift run dockpin-probe watch --to <uuid|index> --guard   # same, plus the edge guard (event tap); HOLDS THE POINTER BACK
```

`watch` saves the selection (unless the display is ambiguous), so `watch` without `--to` reuses it.

### Edge guard

The Dock migrates when the pointer is pushed against the bottom edge of another display. With `--guard`, an event tap keeps the pointer out of a thin strip (3 px) along the bottom of every display except the pinned one, so the Dock never gets that push. Dragging and other displays' sides are unaffected, and if the pinned display is unplugged nothing is guarded. The post-hoc correction stays as a fallback. Details and the validation checklist: `docs/PHASE3-NOTES.md`.

## Accessibility permission

Moving the Dock works by moving the pointer to the bottom edge of the target display, which requires Accessibility access. Grant it to the app (or to the terminal running the probe) in System Settings > Privacy & Security > Accessibility. Without it, the tool reports the problem and does not touch the pointer.

The edge guard needs the same permission (an active event tap cannot be created without it).

Do not run another Dock controller (for example DockLock Lite) or a similar pointer tool at the same time.

## Status

Early development. No GUI yet.

- Phase 1: display identity, Dock locator, enforcement policy, relocator, probe CLI. See `docs/PHASE1-NOTES.md`.
- Phase 2: persisted selection, enforcement driver, observable status, `watch` and `status` commands. See `docs/PHASE2-NOTES.md`.
- Phase 3: edge guard (prevention) with `watch --guard`; the Phase 2 correction is the fallback. See `docs/PHASE3-NOTES.md`.

Scope and background: `docs/initial-brief.md`.
