# Phase 1 notes — mechanism prototype

Scope: SwiftPM (macOS 14, Swift 6.4), no UI or login item. Enforcement by **corrective relocation** (detect and fix; migration is not prevented).

## What was implemented

| Piece | File | Status |
| --- | --- | --- |
| `DisplayIdentity` / enumeration / selector resolution | `DisplayIdentity.swift` | Pure tests; real enumeration run with `displays` |
| `DockLocator` (windows owned by `Dock`, dock layer, midpoint) | `DockLocator.swift` | Pure tests; `locate` run on real hardware |
| `EnforcementPolicy` (pure state machine, injected clock) | `EnforcementPolicy.swift` | 20 tests, one per rule |
| `DockRelocator` (warp + dwell on the bottom edge, restores cursor) | `DockRelocator.swift` | Fake-based tests; later validated by hand on hardware (see Phase 2 notes) |
| CLI `dockpin-probe displays`, `locate`, `relocate --to <uuid or index> --once` | `Sources/dockpin-probe` | Compiled; `relocate` later validated by hand |

Decisions:
- **Identity**: the UUID from `CGDisplayCreateUUIDFromDisplayID`. If two connected displays share a UUID they are flagged `isAmbiguous`: selecting by UUID is rejected (`ambiguousIdentity`), selecting by index is allowed with a warning, the locator returns `unknown(.ambiguousDisplay)` and the relocator refuses. An ambiguous selection is never persisted.
- **Unlocatable Dock = unknown**, never "wrong display"; the policy moves nothing on `unknown`.
- **Policy** (defaults in `EnforcementConfig`): 2 s debounce after display/wake events, 5 s cooldown between attempts (global, survives streak resets), max 3 attempts per streak, 4 s attempt timeout, 1 s of user quiet before starting, 10 s poll. User activity cancels the attempt and counts against the budget. Disconnected display: no moves and no retries until a display event. Attempts exhausted or non-retryable error (e.g. no Accessibility): `gaveUp` until an external trigger.
- **Relocator**: requires `AXIsProcessTrusted`, does not start with a button pressed, refuses if the bottom edge is covered by another display, holds the cursor 1.5 s against the edge with minimal `mouseMoved` events, restores the original position, always calls `CGAssociateMouseAndMouseCursorPosition(1)`, never hides the cursor. If the user moves the mouse it gives up **without** restoring.

## Validated on this machine

- `swift build` and `swift test` (45 tests) pass.
- `dockpin-probe displays`: 2 displays, distinct UUIDs, frames consistent with the arrangement (secondary at x=-1920).
- `dockpin-probe locate`: detected the Dock on display `[1]`. A single observation with a visible Dock; it does not validate auto-hide or Spaces.

## Not validated at runtime (brief checklist)

- [ ] Enforcement during normal use (is corrective relocation enough? perceptible latency?).
- [ ] That warp + dwell really migrates the Dock; minimum dwell; whether `nudge` events help or hurt; local event suppression after the warp.
- [ ] Target coordinates with vertical arrangements, partially exposed edges and mixed scales.
- [ ] Visible Dock vs auto-hide; decide whether a bottom Dock is an MVP prerequisite (the relocator assumes bottom today).
- [ ] Locator: `dockWindowLevel` layer and extra Dock windows; Spaces/fullscreen behavior; permissions needed on macOS 27.
- [ ] That the user's cursor/input is not disturbed (including hot corners on restore).
- [ ] Cancellation, cooldown and limits with real events (the policy was only tested with a manual clock; the driver tying policy + locator + relocator + display/wake notifications did not exist yet).
- [ ] Identical displays: does the UUID really collide on real hardware?
- [ ] Login, wake, disconnect/reconnect, geometry changes.
- [ ] Never run two Dock controllers at once (DockLock, etc.).

## Controlled test plan

Before:
1. **Quit DockLock Lite** (and any other Dock controller); verify no processes remain.
2. Grant **Accessibility** to the terminal running the probe (System Settings > Privacy & Security > Accessibility). Without it `relocate` fails with an actionable message without touching the cursor.
3. Dock at the bottom, no auto-hide on the first pass; known display arrangement (note the output of `displays`).
4. Close menus / Control Center; hands off the mouse during the attempt.

What happens to the cursor: `dockpin-probe relocate --to <uuid or index> --once` makes the cursor jump to the bottom edge of the target display, stay there ~1.5 s and return to its original position. The Dock should migrate in that window. If the user moves the mouse or presses a button the attempt aborts and the cursor stays where the user put it. The probe then waits 1.5 s and prints where the Dock ended up.

Suggested order: `displays`, `locate` (before), `relocate ... --once` (towards the display where the Dock is NOT), `locate` (after); repeat with auto-hide and with a covered edge to see the refusals.
