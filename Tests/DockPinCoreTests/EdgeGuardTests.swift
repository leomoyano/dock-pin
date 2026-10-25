import CoreGraphics
import Foundation
import Testing
@testable import DockPinCore

// MARK: - Fakes

private final class FakeTap: EventTapping, @unchecked Sendable {
    var canInstall = true
    var installCount = 0
    var removeCount = 0
    var reenableCount = 0
    var onMove: EdgeMoveHandler?
    var onDisabled: (@Sendable () -> Void)?

    func install(onMove: @escaping EdgeMoveHandler, onDisabled: @escaping @Sendable () -> Void) -> Bool {
        installCount += 1
        guard canInstall else { return false }
        self.onMove = onMove
        self.onDisabled = onDisabled
        return true
    }

    func reenable() { reenableCount += 1 }

    func remove() {
        removeCount += 1
        onMove = nil
        onDisabled = nil
    }

    /// What the real tap does per event: ask for a correction exactly once.
    func move(to point: CGPoint) -> CGPoint? { onMove?(point) }
}

private final class FakeTrust: AccessibilityTrusting, @unchecked Sendable {
    var trusted = true
    var isTrusted: Bool { trusted }
}

private final class FakeDisplays: DisplayProviding, @unchecked Sendable {
    var displays: [DisplayInfo]
    init(_ displays: [DisplayInfo]) { self.displays = displays }
    func connectedDisplays() -> [DisplayInfo] { displays }
}

private final class FakeEvents: SystemEventSource, @unchecked Sendable {
    var handler: (@Sendable (SystemTrigger) -> Void)?
    var startCount = 0
    var stopCount = 0
    func start(_ handler: @escaping @Sendable (SystemTrigger) -> Void) { startCount += 1; self.handler = handler }
    func stop() { stopCount += 1; handler = nil }
    func fire(_ trigger: SystemTrigger) { handler?(trigger) }
}

private final class ButtonState: @unchecked Sendable {
    var down = false
}

// MARK: - Rig

private func display(_ n: Int, x: CGFloat) -> DisplayInfo {
    DisplayInfo(
        identity: DisplayIdentity(uuid: "00000000-0000-0000-0000-00000000000\(n)"),
        displayID: UInt32(n),
        frame: CGRect(x: x, y: 0, width: 1920, height: 1080))
}

private let d1 = display(1, x: 0)
private let d2 = display(2, x: 1920)

private final class Rig {
    let tap = FakeTap()
    let trust = FakeTrust()
    let displays: FakeDisplays
    let events = FakeEvents()
    let button = ButtonState()
    let guardian: EdgeGuard

    init(connected: [DisplayInfo] = [d1, d2], pinned: DisplayInfo? = d2) {
        displays = FakeDisplays(connected)
        let button = self.button
        guardian = EdgeGuard(
            tap: tap, trust: trust, displayProvider: displays, events: events,
            isMouseButtonDown: { button.down })
        guardian.setPinned(pinned?.identity)
    }
}

// MARK: - Tests

@Test func startInstallsTheTapAndReportsActive() {
    let rig = Rig()
    #expect(rig.guardian.state == .inactive)
    rig.guardian.start()
    #expect(rig.guardian.state == .active)
    #expect(rig.tap.installCount == 1)
    #expect(rig.events.startCount == 1)
}

@Test func pointerPushedAgainstTheBottomOfANonPinnedDisplayIsCorrectedOncePerEvent() {
    let rig = Rig()
    rig.guardian.start()
    #expect(rig.tap.move(to: CGPoint(x: 500, y: 1079)) == CGPoint(x: 500, y: 1076))
    // The corrected point is outside the strip: a re-delivery would not correct again (no loop).
    #expect(rig.tap.move(to: CGPoint(x: 500, y: 1076)) == nil)
    #expect(rig.tap.move(to: CGPoint(x: 500, y: 600)) == nil)
}

@Test func pinnedDisplayBottomEdgeIsLeftAlone() {
    let rig = Rig()
    rig.guardian.start()
    #expect(rig.tap.move(to: CGPoint(x: 3000, y: 1079)) == nil)
}

@Test func heldMouseButtonDisablesTheCorrection() {
    let rig = Rig()
    rig.guardian.start()
    rig.button.down = true
    #expect(rig.tap.move(to: CGPoint(x: 500, y: 1079)) == nil)
    rig.button.down = false
    #expect(rig.tap.move(to: CGPoint(x: 500, y: 1079)) == CGPoint(x: 500, y: 1076))
}

@Test func failedTapCreationReportsPermissionMissingAndGuardsNothing() {
    let rig = Rig()
    rig.tap.canInstall = false
    rig.guardian.start()
    #expect(rig.guardian.state == .permissionMissing)
    #expect(rig.tap.move(to: CGPoint(x: 500, y: 1079)) == nil)
    #expect(rig.events.startCount == 0)
}

@Test func untrustedProcessNeverTriesToCreateTheTap() {
    let rig = Rig()
    rig.trust.trusted = false
    rig.guardian.start()
    #expect(rig.guardian.state == .permissionMissing)
    #expect(rig.tap.installCount == 0)
}

@Test func tickStartsTheGuardOnceAccessibilityIsGranted() {
    let rig = Rig()
    rig.trust.trusted = false
    rig.guardian.start()
    rig.guardian.tick()
    #expect(rig.tap.installCount == 0)
    rig.trust.trusted = true
    rig.guardian.tick()
    #expect(rig.guardian.state == .active)
    #expect(rig.tap.installCount == 1)
    rig.guardian.tick()
    #expect(rig.tap.installCount == 1)
}

@Test func disabledTapIsReenabled() {
    let rig = Rig()
    rig.guardian.start()
    rig.tap.onDisabled?()
    rig.tap.onDisabled?()
    #expect(rig.tap.reenableCount == 2)
    #expect(rig.guardian.state == .active)
}

@Test func stopRemovesTheTapAndTheSystemCallbacks() {
    let rig = Rig()
    rig.guardian.start()
    rig.guardian.stop()
    #expect(rig.guardian.state == .inactive)
    #expect(rig.tap.removeCount == 1)
    #expect(rig.events.stopCount == 1)
    #expect(rig.events.handler == nil)
    #expect(rig.tap.move(to: CGPoint(x: 500, y: 1079)) == nil)
}

@Test func startAndStopAreIdempotent() {
    let rig = Rig()
    rig.guardian.stop()
    #expect(rig.tap.removeCount == 0)
    rig.guardian.start()
    rig.guardian.start()
    #expect(rig.tap.installCount == 1)
    rig.guardian.stop()
    rig.guardian.stop()
    #expect(rig.tap.removeCount == 1)
}

@Test func canRestartAfterStop() {
    let rig = Rig()
    rig.guardian.start()
    rig.guardian.stop()
    rig.guardian.start()
    #expect(rig.guardian.state == .active)
    #expect(rig.tap.installCount == 2)
    #expect(rig.tap.move(to: CGPoint(x: 500, y: 1079)) == CGPoint(x: 500, y: 1076))
}

@Test func disconnectedPinnedDisplayNeverHoldsThePointerAndResumesOnReconnect() {
    let rig = Rig()
    rig.guardian.start()
    #expect(rig.tap.move(to: CGPoint(x: 500, y: 1079)) == CGPoint(x: 500, y: 1076))

    rig.displays.displays = [d1] // the pinned display was unplugged
    rig.events.fire(.displayConfigurationChanged)
    #expect(rig.tap.move(to: CGPoint(x: 500, y: 1079)) == nil)
    #expect(rig.guardian.state == .active) // tap stays installed; the layout is inert

    rig.displays.displays = [d1, d2]
    rig.events.fire(.displayConfigurationChanged)
    #expect(rig.tap.move(to: CGPoint(x: 500, y: 1079)) == CGPoint(x: 500, y: 1076))
}

@Test func displayChangeRefreshesTheLayout() {
    let rig = Rig()
    rig.guardian.start()
    // A third display appears on the right of the pinned one.
    rig.displays.displays = [d1, d2, display(3, x: 3840)]
    #expect(rig.tap.move(to: CGPoint(x: 4000, y: 1079)) == nil) // stale layout
    rig.events.fire(.displayConfigurationChanged)
    #expect(rig.tap.move(to: CGPoint(x: 4000, y: 1079)) == CGPoint(x: 4000, y: 1076))
}

@Test func changingThePinnedDisplayMovesTheGuard() {
    let rig = Rig()
    rig.guardian.start()
    rig.guardian.setPinned(d1.identity)
    #expect(rig.tap.move(to: CGPoint(x: 500, y: 1079)) == nil)
    #expect(rig.tap.move(to: CGPoint(x: 3000, y: 1079)) == CGPoint(x: 3000, y: 1076))
    rig.guardian.setPinned(nil)
    #expect(rig.tap.move(to: CGPoint(x: 3000, y: 1079)) == nil)
}

@Test func ambiguousPinnedDisplayGuardsNothing() {
    let twin = DisplayInfo(
        identity: d2.identity, displayID: 7, frame: CGRect(x: 3840, y: 0, width: 1920, height: 1080),
        isAmbiguous: true)
    let ambiguousD2 = DisplayInfo(
        identity: d2.identity, displayID: 2, frame: d2.frame, isAmbiguous: true)
    let rig = Rig(connected: [d1, ambiguousD2, twin], pinned: d2)
    rig.guardian.start()
    #expect(rig.tap.move(to: CGPoint(x: 500, y: 1079)) == nil)
}

@Test func noPinnedSelectionGuardsNothing() {
    let rig = Rig(pinned: nil)
    rig.guardian.start()
    #expect(rig.guardian.state == .active)
    #expect(rig.tap.move(to: CGPoint(x: 500, y: 1079)) == nil)
}
