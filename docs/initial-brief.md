# Dock Pin — initial brief

Build an independent native macOS app that keeps the Dock on one user-selected monitor. This document records the agreed scope and investigation handoff; it is not an approved implementation design.

## Agreed scope

- Provide a monitor selector and remember the selected physical display across launches.
- Start at login so placement can be restored after reboot and sign-in.
- Recheck placement after wake and display connection or arrangement changes.
- Keep the Dock on the selected monitor during ordinary use, not just at startup.
- If the selected monitor is disconnected, preserve the selection and wait for reconnection without repeatedly moving the pointer.
- Proposed stack: Swift + AppKit. No application code or project scaffolding exists yet.

Out of scope: purchases, trials, licensing, DockLock feature parity, unrelated Dock customization, and advanced menu-bar features. Minimal permission guidance and actionable failure status are still necessary.

## Investigation and confidence

Static REA/Hopper inspection examined the installed DockLock Lite 1.5.2 (build 631):

- Artifact: `/Applications/DockLock Lite.app/Contents/MacOS/DockLock Lite`
- SHA-256: `75c20e10a0bd5ce780890abca3248c71afc154a4e7d4874d8ae75286e13639cd`
- Universal Mach-O; analysis selected arm64.
- No target execution, runtime tracing, cursor manipulation, or display rearrangement was performed during this investigation.

| Finding | Status and provenance |
| --- | --- |
| Display reconfiguration callback registration | Observed in `sub_100047560`, calling `CGDisplayRegisterReconfigurationCallback`. Evidence `ev_31dc558b7be4a142c0eeebb3ce19dc7ca0720f113ef7fde32eef1d22bfb6721d`. |
| Accessibility trust check | Observed in `sub_100046cb4`, calling `AXIsProcessTrusted`. Evidence `ev_7166998e8e3f81e6a0fbc0801b82a7b1eb9d340223012b5a81ffa988e707cef2`. |
| Pointer warp and synthetic mouse movement | Observed in `sub_100003dc0`: conditional `CGWarpMouseCursorPosition` or `CGEventCreateMouseEvent` / `CGEventPost`. Evidence `ev_44ac86969de6bd103190686609d77f3aac5b9b0dba0dfed50cc1d83a4c86d8f5`. |
| Event monitoring infrastructure | Observed in `sub_10000586c`: `CGEventTapCreate`, run-loop source, enablement checks and failure handling. Evidence `ev_2bb7d32c44462c141fea60fc818eb6dd15a8797db5882592c415004c0c4e298d`. Its exact role in blocking Dock migration remains unverified. |
| Dock location detection | Inspected `sub_1000019e0`: enumerates windows, filters owner `Dock` and window layer, parses bounds, and tests the midpoint against display rectangles. The complete dossier was returned by REA but its evidence ID was not recorded in this handoff. |
| Relocation failure guidance | `sub_100016924` constructs advice to keep the mouse still and close menus/Control Center. Evidence `ev_8af085c9a97d9b197a229e70280718d1810c0e087d46fd937a8f9e874de24692`. |

REA Evidence IDs refer to the investigation session, not files embedded in this repository. No portable evidence bundle has been exported; later sessions may need to re-inspect the artifact.

### Corrections and limits

- Mouse automation is a plausible relocation mechanism, but the complete call path from a selected monitor to those APIs was not established. The `moveDockToMonitor` name appeared in RTTI strings; searching analyzed procedure names returned no match.
- The investigation does not prove that no direct Dock-placement API exists or that this app never uses another mechanism.
- `DockHandlerHelper` was initially hypothesized to handle relocation. Its inspected method handles application reopen/delegate forwarding; it must not be treated as a confirmed relocation component.
- A window-based location detector may have limitations with auto-hide, Spaces, fullscreen, or OS permissions. A missing window is unknown placement, not proof that the Dock is on the wrong monitor.
- Relocation alone does not establish persistent locking. How the app prevents or corrects migration during ordinary mouse use still needs investigation or an independent prototype.

## Validation before claiming reliability

- [ ] Establish the enforcement mechanism during ordinary use: prevention versus corrective relocation.
- [ ] Validate target coordinates and timing on a real multi-monitor setup, including exposed bottom edges and vertically arranged displays.
- [ ] Validate Dock visible and auto-hide modes; decide whether bottom orientation is an explicit MVP prerequisite.
- [ ] Validate position detection and required permissions on the target macOS version.
- [ ] Verify that pointer position and user input are not disrupted; cancel or defer when the user interacts.
- [ ] Validate bounded retries, cooldowns, cancellation and cleanup; never run an endless cursor-moving loop.
- [ ] Select a stable display identity and define behavior for ambiguous/identical monitors.
- [ ] Verify login startup, wake, disconnect/reconnect and changed display geometry.
- [ ] Avoid running two Dock controllers concurrently during tests.

## Acceptance criteria

1. The user can select a connected monitor and the selection survives app restart.
2. With the selected monitor connected and permissions granted, the Dock remains there during ordinary use within a documented, tested enforcement policy.
3. After login, wake or display changes, placement is re-evaluated once display state settles and restored when needed.
4. Disconnecting the selected monitor causes no repeated pointer movement; reconnecting resumes enforcement.
5. Permission failures, unsupported layouts and unknown placement are visible rather than reported as success.
6. Quitting stops monitoring and pending actions without leaving the pointer hidden or interfering with input.

## Next step

Open this repository in Pi and read this brief. Before implementation, agree on the minimum macOS version, controlled runtime-test scope, and enforcement policy. Design and validate the narrow Dock-placement mechanism before expanding UI or distribution work. Do not modify the REA repository or reuse DockLock code/assets.
