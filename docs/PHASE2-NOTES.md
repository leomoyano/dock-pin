# Phase 2 notes — enforcement driver

Scope: the engine that keeps the Dock pinned automatically, in `DockPinCore`, plus CLI commands to exercise it. No GUI yet.

Starting point: the Phase 1 mechanism was validated by hand on the development machine (`relocate --to <n> --once` moves the Dock in both directions and restores the cursor).

## What was implemented

| Piece | File | Notes |
| --- | --- | --- |
| `PinnedDisplayStore` | `PinnedDisplayStore.swift` | Persists the display UUID (UserDefaults suite `com.dockpin.shared`, behind `PinnedDisplayPersisting`). Ambiguous identities are never saved; a saved UUID that is not connected is kept; a corrupted value reads as "no selection". |
| `DockStatus` | `DockStatus.swift` | Observable state: `stopped`, `noSelection`, `checking`, `pinned`, `relocating(attempt)`, `awaitingRecheck`, `waitingForDisplay`, `accessibilityPermissionMissing`, `gaveUp(reason)`, `unknownPlacement(reason)`. `pinned` only after the Dock was actually observed on the selected display. |
| `EnforcementDriver` | `EnforcementDriver.swift` | Feeds `EnforcementPolicy` with system events and ticks, performs the actions it returns (observe, relocate, cancel). |
| System glue | `SystemEnvironment.swift` | `CGDisplayRegisterReconfigurationCallback`, `NSWorkspace` wake / screens-wake notifications, idle time via `CGEventSource.secondsSinceLastEventType`, GCD scheduler. All behind protocols (`SystemEventSource`, `UserActivityProviding`, `Scheduling`, `DockLocating`). |
| CLI | `Sources/dockpin-probe` | `watch [--to <uuid\|index>]` (foreground, status changes printed, Ctrl-C/SIGTERM clean stop) and read-only `status`. |

### Driver behavior

- Single serial "driver context" (the main queue in the real build). Only the blocking relocation runs on a background queue and hops back to report its result.
- All cursor movement is decided by the policy, so its retry budget (3 attempts per streak), 5 s cooldown and 2 s debounce always apply. There is no loop outside the policy.
- A display reconfiguration burst only restarts the debounce; one attempt happens after the display state settles.
- Wake restarts the same flow. A change of selection (including one made by another process through the shared store) is noticed at the next tick.
- No selection, selected display disconnected, selected display ambiguous, or Dock unlocatable: nothing is ever moved. A reconnect (display event) resumes.
- Accessibility missing: the relocator refuses before touching the cursor; status shows the permission problem and there are no retries. The driver re-checks trust on each tick and, once granted, restarts evaluation exactly once.
- User input is polled (read-only idle time). Recent input defers a new attempt; input produced by the relocator's own nudges is ignored. The relocator itself aborts if the real mouse moves during the dwell.
- `stop()` cancels the tick timer and the pending attempt token, unregisters the system callbacks, waits (bounded, 1 s) for an in-flight attempt to restore the cursor, then always re-associates mouse and cursor. A late completion after `stop()` is ignored. The cursor is never hidden.
- Change in the Phase 1 relocator: a programmatic cancellation (stop, display change) now restores the original cursor position, unless the user moved the mouse (then it still leaves the cursor alone).

### Known limitation by design

After the policy gives up (attempts exhausted), the Dock is not touched again until a display change, wake or new selection. This bounds cursor movement; whether it is acceptable in daily use is part of the controlled test below.

## Tests

`swift test`: 69 tests, all fakes (no real display, cursor or Dock). Driver tests cover: reconfiguration burst gives a single debounced attempt; wake re-evaluates; disconnected selection makes no moves and reconnect resumes; missing permission reports status with no retries and resumes once after it is granted; `stop()` leaves no timers, callbacks or further actions (also while an attempt is in flight); a display change during an attempt cancels it and never overlaps a second one; no selection, unknown placement and ambiguous display never move anything; the retry budget and cooldown hold when the Dock never moves; user activity defers attempts; start/stop are idempotent.

## NOT validated at runtime (checklist for a controlled test with Leo)

Nothing in Phase 2 has been run against real hardware: `watch` was only compiled. `status` (read-only) was run.

Before: quit DockLock Lite and any other Dock controller; grant Accessibility to the terminal; note the output of `displays`; hands off the mouse during attempts.

- [ ] `watch --to <index>` end to end: Dock on the wrong display gets moved and the status goes `checking` → `relocating` → `awaitingRecheck` → `pinned`.
- [ ] Ctrl-C during an attempt: the cursor ends where it started, not at the screen edge; the process exits promptly.
- [ ] Real display unplug / replug (and sleeping or disconnecting the cable): `CGDisplayRegisterReconfigurationCallback` fires in a CLI process (no `NSApplication`), the debounce absorbs the burst, no cursor movement while unplugged, resumes on replug.
- [ ] Real sleep/wake and screen wake: `NSWorkspace` notifications are delivered to a CLI process; re-evaluation after wake; behavior when the displays take several seconds to come back.
- [ ] Dock auto-hide: `locate` probably reports unknown placement. Check that the status stays `unknownPlacement` and nothing is moved. Decide whether a visible bottom Dock is an MVP prerequisite.
- [ ] Spaces / full-screen apps on either display: Dock window missing → unknown placement, no moves.
- [ ] Dock on the left/right side (the relocator assumes bottom).
- [ ] Normal use: drag the Dock to the other display by hand with the mouse; confirm it is corrected within the documented policy, that the delay is acceptable and the pointer is not disturbed (hot corners on restore, menus open).
- [ ] The idle-time heuristic: moving the mouse defers attempts; the relocator's own synthetic events do not cause self-cancellation or perpetual deferral.
- [ ] Retry budget with a real failure (e.g. a covered bottom edge, or a Dock that refuses to move): at most 3 attempts, then `gaveUp`, no further cursor movement for several minutes.
- [ ] Accessibility revoked while running, then granted again: status `accessibilityPermissionMissing` and recovery without restarting.
- [ ] Identical monitors: does the UUID really collide on real hardware, and is the "ambiguous" status shown?
- [ ] Selection shared through the `com.dockpin.shared` UserDefaults suite survives a reboot and is readable by `status`.
- [ ] CPU / wake-ups of the 0.5 s tick over an hour (should be negligible; consider event-driven deadlines if not).
- [ ] Login startup is out of scope until there is an app bundle.
