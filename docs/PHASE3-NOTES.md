# Phase 3 notes — edge guard (prevention)

Scope: stop the Dock from leaving the chosen display in the first place, instead of only correcting it afterwards. Phase 2's post-hoc correction stays as a fallback.

## Why

The Dock migrates when the pointer is pushed against the **bottom edge** of another display (not by dragging). So the guard keeps the pointer out of a thin strip along the bottom of every display that is not the pinned one.

## What was implemented

| Piece | File | Notes |
| --- | --- | --- |
| `EdgeGuardGeometry` | `EdgeGuardGeometry.swift` | Pure decision logic (no AppKit / CG calls). A `Layout` is built once per display configuration; `correction(for:)` allocates nothing. |
| `EdgeGuard` | `EdgeGuard.swift` | Lifecycle and state (`GuardState`: `inactive`, `active`, `permissionMissing`). Refreshes the layout on display reconfiguration, wake and selection change. Re-checks Accessibility on each driver tick. |
| `EventTapping` + `SystemEventTap` | `EdgeGuard.swift`, `SystemEventTap.swift` | The CG calls behind a protocol. The real tap is `.cgSessionEventTap`, head insert, active filter, **`mouseMoved` only**, on its own thread and run loop. |
| Driver integration | `EnforcementDriver.swift`, `DockStatus.swift` | Optional `edgeGuard:`; `guardState` / `onGuardState` next to `status`. The policy (budget 3, cooldown 5 s, debounce 2 s) is untouched. |
| CLI | `Sources/dockpin-probe` | `watch --to <uuid\|index> [--guard]`; guard state changes are printed. `status` stays read-only. |

### Geometry rules

- Strip = bottom `stripHeight` px (default 3, configurable) of each non-pinned display, capped at half the display height.
- A point in the strip is corrected to the same x and y just above the strip (`maxY - strip - 1`).
- The pinned display is never clamped.
- A point inside another display's frame is not clamped (overlapping / mirrored layouts).
- Where another display sits directly below (its frame contains the pixel just past the bottom edge), the edge is not a real edge, so that part of the strip is open: the pointer must be able to cross. Offset stacks only open the covered x range.
- Different sizes and negative origins work: each display uses its own frame in global Quartz coordinates (top-left origin).
- Pinned display not connected (or ambiguous, i.e. shared UUID): nothing is guarded, the pointer is never held.
- Dock orientation **bottom** is assumed. Left/right is future work: `GuardedEdge` and the per-display `Guarded` entry are the extension points.

### Tap behavior

- Only `mouseMoved`. Drags are `*MouseDragged` events, so dragging a window across the bottom edge is untouched. A held button also disables the correction (checked only when a correction is due, to keep the callback cheap).
- One correction per event: the corrected location is written into the event and the cursor is warped to the same point so the hidden pointer position does not keep drifting into the strip. A warp posts no event, so there is no feedback loop; a corrected point is outside the strip, so it would not be corrected again anyway.
- The local-events suppression interval is set to 0 while the tap is installed (restored on removal) so the warp does not leave the cursor feeling stuck.
- `tapDisabledByTimeout` / `tapDisabledByUserInput` re-enable the tap.
- `stop()` disables the tap, stops and joins the tap thread, invalidates the port and unregisters the display/wake callbacks.
- If the tap cannot be created (no Accessibility), the guard reports `permissionMissing`, installs nothing and retries on each driver tick.
- The Phase 1 relocator is unaffected: it only touches the bottom edge of the pinned display, which is never clamped.

### Relationship with the post-hoc correction

The guard is the primary mechanism. The Phase 2 driver still runs as a fallback for a Dock already on the wrong display at startup, or anything that slipped past the guard, with the same budget and cooldown.

## Tests

Geometry (many cases: boundaries, sizes, negative origins, stacks, overlaps, missing pinned display, strip height), guard lifecycle with a fake tap (install/remove, permission missing, retry, re-enable, button held, display change, unplug/replug, selection change, idempotent start/stop) and driver integration with a fake guard. No test touches a real tap, cursor or Dock.

## NOT validated at runtime

Nothing in Phase 3 has been run against real hardware. `watch --guard` was never executed (it installs an event tap), only compiled and unit-tested with fakes.

Before: quit DockLock Lite and any other Dock or pointer controller (**DockLock Lite and similar tools must not run at the same time**: two taps fight over the pointer); grant Accessibility to the terminal; note the output of `displays`.

- [ ] Pointer pushed hard against the bottom edge of a non-pinned display does not move the Dock.
- [ ] Pinned display: pushing against its bottom edge still works and shows the Dock (also with auto-hide).
- [ ] Mouse speed: very fast flicks downward (the pointer can jump past a 3 px strip in one event) and slow pushes; decide if the strip needs to be thicker (`stripHeight`) or if the jump case needs extrapolating between consecutive events.
- [ ] The event location alone vs. location + warp: the pointer ends just above the strip without jitter or a stuck feeling; check the suppression-interval tweak.
- [ ] Dragging a window across the bottom edge of a non-pinned display keeps working.
- [ ] Dock auto-hide on the non-pinned display.
- [ ] Display unplug / replug: layout refreshes, the pointer is never held while the pinned display is missing.
- [ ] Sleep / wake and screen wake: the tap survives (or is re-enabled) and the layout is refreshed.
- [ ] `tapDisabledByTimeout` / `tapDisabledByUserInput` actually fire and recovery works.
- [ ] Ctrl-C: tap removed, pointer behaves normally, process exits promptly.
- [ ] Accessibility revoked while running and granted again: `permissionMissing` and recovery without restarting.
- [ ] Compatibility with other pointer tools (Mouse acceleration utilities, Hopper-like launchers, window managers).
- [ ] Hot corners and menu-bar behavior near the strip are not disturbed.
- [ ] Stacked / offset display arrangements: the open part of the edge lets the pointer cross.
- [ ] CPU usage of the tap while moving the mouse continuously.
