import CoreGraphics
import Foundation
import Testing
@testable import DockPinCore

// MARK: - Fakes

private final class FakeScheduler: Scheduling, @unchecked Sendable {
    private final class Timer: TimerHandle {
        let fireAt: TimeInterval
        let action: @Sendable () -> Void
        var cancelled = false
        init(fireAt: TimeInterval, action: @escaping @Sendable () -> Void) {
            self.fireAt = fireAt
            self.action = action
        }
        func cancel() { cancelled = true }
    }

    var now: TimeInterval = 1000
    private var timers: [Timer] = []
    /// When false, background work is queued until `runBackground()`.
    var runsBackgroundInline = true
    private var background: [@Sendable () -> Void] = []

    var pendingTimers: Int { timers.filter { !$0.cancelled }.count }
    var pendingBackground: Int { background.count }

    func schedule(after delay: TimeInterval, _ action: @escaping @Sendable () -> Void) -> TimerHandle {
        let timer = Timer(fireAt: now + delay, action: action)
        timers.append(timer)
        return timer
    }

    func runInBackground(_ work: @escaping @Sendable () -> Void) {
        if runsBackgroundInline { work() } else { background.append(work) }
    }

    func runOnDriverContext(_ action: @escaping @Sendable () -> Void) { action() }

    func runBackground() {
        let work = background
        background.removeAll()
        work.forEach { $0() }
    }

    func advance(by seconds: TimeInterval) {
        let end = now + seconds
        while let next = timers.filter({ !$0.cancelled && $0.fireAt <= end }).min(by: { $0.fireAt < $1.fireAt }) {
            timers.removeAll { $0 === next }
            now = max(now, next.fireAt)
            next.action()
        }
        now = end
    }
}

private final class FakeDisplays: DisplayProviding, @unchecked Sendable {
    var displays: [DisplayInfo]
    init(_ displays: [DisplayInfo]) { self.displays = displays }
    func connectedDisplays() -> [DisplayInfo] { displays }
}

private final class FakeLocator: DockLocating, @unchecked Sendable {
    var placement: DockPlacement
    init(_ placement: DockPlacement) { self.placement = placement }
    func locate(in displays: [DisplayInfo]) -> DockPlacement { placement }
}

private final class FakeRelocator: DockRelocating, @unchecked Sendable {
    var calls = 0
    var result: Result<Void, RelocationError> = .success(())
    /// Called on each relocation (e.g. to move the fake Dock).
    var onRelocate: ((CancellationToken) -> Void)?
    func relocate(to target: DisplayInfo, among displays: [DisplayInfo],
                  cancel: CancellationToken) -> Result<Void, RelocationError> {
        calls += 1
        onRelocate?(cancel)
        return result
    }
}

private final class FakeEvents: SystemEventSource, @unchecked Sendable {
    var handler: (@Sendable (SystemTrigger) -> Void)?
    var startCount = 0
    var stopCount = 0
    func start(_ handler: @escaping @Sendable (SystemTrigger) -> Void) { startCount += 1; self.handler = handler }
    func stop() { stopCount += 1; handler = nil }
    func fire(_ trigger: SystemTrigger) { handler?(trigger) }
}

private final class FakeActivity: UserActivityProviding, @unchecked Sendable {
    var idle: TimeInterval?
    var secondsSinceLastInput: TimeInterval? { idle }
}

private final class FakeTrust: AccessibilityTrusting, @unchecked Sendable {
    var trusted = true
    var isTrusted: Bool { trusted }
}

private final class FakeCursor: CursorControlling, @unchecked Sendable {
    var reassociations = 0
    var warps = 0
    func location() -> CGPoint? { .zero }
    func warp(to point: CGPoint) { warps += 1 }
    func nudge(at point: CGPoint) {}
    func isMouseButtonDown() -> Bool { false }
    func reassociate() { reassociations += 1 }
}

private final class StatusLog: @unchecked Sendable {
    var values: [DockStatus] = []
    var guardValues: [GuardState] = []
}

private final class FakeGuard: EdgeGuarding, @unchecked Sendable {
    var state: GuardState = .inactive
    /// State the guard reaches when started.
    var startsAs: GuardState = .active
    var calls: [String] = []
    var pinned: DisplayIdentity?

    func start() { calls.append("start"); state = startsAs }
    func stop() { calls.append("stop"); state = .inactive }
    func setPinned(_ identity: DisplayIdentity?) { calls.append("pin"); pinned = identity }
    func tick() { calls.append("tick") }
}

// MARK: - Rig

private func display(_ n: Int) -> DisplayInfo {
    DisplayInfo(
        identity: DisplayIdentity(uuid: "00000000-0000-0000-0000-00000000000\(n)"),
        displayID: UInt32(n),
        frame: CGRect(x: 1920 * (n - 1), y: 0, width: 1920, height: 1080))
}

private let d1 = display(1)
private let d2 = display(2)

private final class Rig {
    let scheduler = FakeScheduler()
    let displays: FakeDisplays
    let locator: FakeLocator
    let relocator = FakeRelocator()
    let events = FakeEvents()
    let activity = FakeActivity()
    let trust = FakeTrust()
    let cursor = FakeCursor()
    let persistence = InMemoryPersistence()
    let log = StatusLog()
    let edgeGuard = FakeGuard()
    let driver: EnforcementDriver
    var store: PinnedDisplayStore { PinnedDisplayStore(persistence: persistence) }

    /// `dockOn`: where the fake Dock starts. The relocator moves it to the target when it succeeds.
    init(connected: [DisplayInfo] = [d1, d2], pinned: DisplayInfo? = d2, dockOn: DisplayInfo = d1) {
        displays = FakeDisplays(connected)
        locator = FakeLocator(.onDisplay(dockOn.identity))
        if let pinned { persistence.saveUUID(pinned.identity.uuid) }
        var config = DriverConfig()
        config.stopWaitTimeout = 0
        let log = self.log
        driver = EnforcementDriver(
            store: PinnedDisplayStore(persistence: persistence),
            displayProvider: displays, locator: locator, relocator: relocator,
            trust: trust, cursor: cursor, events: events, activity: activity,
            scheduler: scheduler, config: config,
            edgeGuard: edgeGuard,
            onGuardState: { log.guardValues.append($0) },
            onStatus: { log.values.append($0) })
        let locator = self.locator
        relocator.onRelocate = { _ in locator.placement = .onDisplay(pinned?.identity ?? d2.identity) }
    }

    func run(_ seconds: TimeInterval) { scheduler.advance(by: seconds) }
}

// MARK: - Tests

@Test func displayReconfigurationBurstProducesASingleDebouncedAttempt() {
    let rig = Rig()
    rig.driver.start()
    // Burst of reconfiguration callbacks, 0.3 s apart.
    for _ in 0..<5 {
        rig.events.fire(.displayConfigurationChanged)
        rig.run(0.3)
    }
    // Last event was ~0.3 s ago: still inside the 2 s debounce.
    rig.run(1.0)
    #expect(rig.relocator.calls == 0)
    #expect(rig.driver.status == .checking)

    rig.run(2.0)
    #expect(rig.relocator.calls == 1)
    rig.run(60)
    #expect(rig.relocator.calls == 1)
    #expect(rig.driver.status == .pinned(d2.identity))
}

@Test func wakeReevaluatesAndRelocatesWhenTheDockDrifted() {
    let rig = Rig(dockOn: d2)
    rig.driver.start()
    rig.run(30)
    #expect(rig.relocator.calls == 0)
    #expect(rig.driver.status == .pinned(d2.identity))

    rig.locator.placement = .onDisplay(d1.identity) // drifted while asleep
    rig.events.fire(.systemDidWake)
    rig.run(1.0)
    #expect(rig.relocator.calls == 0) // still settling
    rig.run(3.0)
    #expect(rig.relocator.calls == 1)
    // Not claimed as success until the re-check after the cooldown sees the Dock there.
    #expect(!rig.driver.status.isPinned)
    rig.run(10)
    #expect(rig.driver.status == .pinned(d2.identity))
}

@Test func disconnectedSelectionWaitsWithoutMovingAndReconnectResumes() {
    let rig = Rig(connected: [d1])
    rig.driver.start()
    rig.run(120)
    #expect(rig.relocator.calls == 0)
    #expect(rig.driver.status == .waitingForDisplay(d2.identity))
    #expect(rig.store.selected == d2.identity) // selection kept

    rig.displays.displays = [d1, d2]
    rig.events.fire(.displayConfigurationChanged)
    rig.run(10)
    #expect(rig.relocator.calls == 1)
    #expect(rig.driver.status == .pinned(d2.identity))
}

@Test func missingPermissionReportsStatusAndDoesNotRetry() {
    let rig = Rig()
    rig.relocator.result = .failure(.accessibilityNotTrusted)
    rig.relocator.onRelocate = nil
    rig.trust.trusted = false
    rig.driver.start()
    rig.run(300)
    #expect(rig.relocator.calls == 1)
    #expect(rig.driver.status == .accessibilityPermissionMissing)
    #expect(!rig.log.values.contains { $0.isPinned })
}

@Test func grantingPermissionLaterResumesOnce() {
    let rig = Rig()
    let locator = rig.locator
    rig.relocator.result = .failure(.accessibilityNotTrusted)
    rig.relocator.onRelocate = nil
    rig.trust.trusted = false
    rig.driver.start()
    rig.run(60)
    #expect(rig.driver.status == .accessibilityPermissionMissing)

    rig.trust.trusted = true
    rig.relocator.result = .success(())
    rig.relocator.onRelocate = { _ in locator.placement = .onDisplay(d2.identity) }
    rig.run(10)
    #expect(rig.relocator.calls == 2)
    #expect(rig.driver.status == .pinned(d2.identity))
}

@Test func stopCancelsTimersUnregistersAndTakesNoFurtherActions() {
    let rig = Rig()
    rig.driver.start()
    rig.run(0.5)
    rig.driver.stop()
    #expect(rig.driver.status == .stopped)
    #expect(rig.events.stopCount >= 1)
    #expect(rig.events.handler == nil)
    #expect(rig.scheduler.pendingTimers == 0)
    #expect(rig.cursor.reassociations >= 1)

    rig.run(600)
    #expect(rig.relocator.calls == 0)
    #expect(rig.cursor.warps == 0)
}

@Test func stopWhileRelocatingCancelsTheAttemptAndIgnoresItsLateCompletion() {
    let rig = Rig()
    rig.scheduler.runsBackgroundInline = false
    var observedToken: CancellationToken?
    rig.relocator.onRelocate = { observedToken = $0 }
    rig.driver.start()
    rig.run(5)
    #expect(rig.scheduler.pendingBackground == 1)
    #expect(rig.driver.status == .relocating(attempt: 1))

    rig.driver.stop()
    rig.scheduler.runBackground() // the blocked attempt finally returns
    #expect(observedToken?.isCancelled == true)
    #expect(rig.driver.status == .stopped)
    #expect(rig.cursor.reassociations >= 1)
    rig.run(600)
    #expect(rig.relocator.calls == 1)
}

@Test func displayChangeDuringAnAttemptCancelsItAndNeverOverlapsAnother() {
    let rig = Rig()
    rig.scheduler.runsBackgroundInline = false
    var tokens: [CancellationToken] = []
    rig.relocator.onRelocate = { tokens.append($0) }
    rig.driver.start()
    rig.run(5)
    #expect(rig.scheduler.pendingBackground == 1)

    rig.events.fire(.displayConfigurationChanged)
    rig.run(10) // debounce passes while the first attempt has not returned
    #expect(rig.scheduler.pendingBackground == 1) // no second concurrent attempt
    rig.scheduler.runBackground()
    #expect(tokens.first?.isCancelled == true)
    #expect(rig.relocator.calls == 1)
}

@Test func noSelectionNeverMovesAnythingAndSelectingStartsEnforcement() {
    let rig = Rig(pinned: nil)
    rig.driver.start()
    rig.run(60)
    #expect(rig.relocator.calls == 0)
    #expect(rig.driver.status == .noSelection)

    _ = rig.store.select(d2)
    rig.driver.selectionDidChange()
    rig.run(10)
    #expect(rig.relocator.calls == 1)
    #expect(rig.driver.status == .pinned(d2.identity))
}

@Test func unknownPlacementIsReportedAndNeverCorrected() {
    let rig = Rig()
    rig.locator.placement = .unknown(.noDockWindow)
    rig.driver.start()
    rig.run(120)
    #expect(rig.relocator.calls == 0)
    #expect(rig.driver.status == .unknownPlacement(.noDockWindow))
    #expect(!rig.log.values.contains { $0.isPinned })
}

@Test func ambiguousSelectedDisplayIsUnsupportedAndNeverMoved() {
    let twin = DisplayInfo(identity: d2.identity, displayID: 9, frame: CGRect(x: 4000, y: 0, width: 10, height: 10))
    let rig = Rig(connected: markAmbiguous([d1, d2, twin]))
    rig.driver.start()
    rig.run(120)
    #expect(rig.relocator.calls == 0)
    #expect(rig.driver.status == .unknownPlacement(.ambiguousDisplay))
}

@Test func retryBudgetIsBoundedWhenTheDockNeverMoves() {
    let rig = Rig()
    rig.relocator.onRelocate = nil // the Dock stays on the wrong display
    rig.driver.start()
    rig.run(600)
    #expect(rig.relocator.calls == EnforcementConfig().maxAttempts)
    #expect(rig.driver.status == .gaveUp(.attemptsExhausted(attempts: 3)))
    rig.run(3600)
    #expect(rig.relocator.calls == EnforcementConfig().maxAttempts)
}

@Test func attemptsAreSeparatedByAtLeastTheCooldown() {
    let rig = Rig()
    var times: [TimeInterval] = []
    let scheduler = rig.scheduler
    rig.relocator.onRelocate = { _ in times.append(scheduler.now) }
    rig.driver.start()
    rig.run(120)
    #expect(times.count == 3)
    for (a, b) in zip(times, times.dropFirst()) {
        #expect(b - a >= EnforcementConfig().cooldown)
    }
}

@Test func recentUserActivityDefersTheAttempt() {
    let rig = Rig()
    rig.activity.idle = 0.1 // the user keeps moving the mouse
    rig.driver.start()
    rig.run(30)
    #expect(rig.relocator.calls == 0)

    rig.activity.idle = nil
    rig.run(10)
    #expect(rig.relocator.calls == 1)
}

@Test func startIsIdempotentAndRestartable() {
    let rig = Rig()
    rig.driver.start()
    rig.driver.start()
    #expect(rig.events.startCount == 1)
    #expect(rig.scheduler.pendingTimers == 1)
    rig.driver.stop()
    rig.driver.stop()
    rig.driver.start()
    rig.run(10)
    #expect(rig.driver.status == .pinned(d2.identity))
}

@Test func statusIsNeverPinnedBeforeTheDockIsObserved() {
    let rig = Rig(dockOn: d2)
    rig.driver.start()
    #expect(rig.driver.status == .checking)
    rig.run(1.0)
    #expect(rig.driver.status == .checking)
    rig.run(2.0)
    #expect(rig.driver.status == .pinned(d2.identity))
}

// MARK: - Edge guard integration

@Test func driverStartsTheGuardWithTheSelectionAndStopsItWithTheDriver() {
    let rig = Rig()
    rig.driver.start()
    #expect(rig.edgeGuard.calls.prefix(2) == ["pin", "start"])
    #expect(rig.edgeGuard.pinned == d2.identity)
    #expect(rig.driver.guardState == .active)
    #expect(rig.log.guardValues == [.active])

    rig.driver.stop()
    #expect(rig.edgeGuard.calls.last == "stop")
    #expect(rig.driver.guardState == .inactive)
    #expect(rig.log.guardValues == [.active, .inactive])
}

@Test func guardPermissionMissingIsReportedAndPostHocCorrectionStillRuns() {
    let rig = Rig()
    rig.edgeGuard.startsAs = .permissionMissing
    rig.driver.start()
    #expect(rig.driver.guardState == .permissionMissing)
    rig.run(10)
    // The Dock was on the wrong display at startup: the fallback relocates it.
    #expect(rig.relocator.calls == 1)
    #expect(rig.driver.status == .pinned(d2.identity))
}

@Test func postHocCorrectionKeepsItsBudgetWhileTheGuardIsActive() {
    let rig = Rig()
    rig.relocator.onRelocate = { _ in } // the Dock never moves
    rig.driver.start()
    rig.run(120)
    #expect(rig.driver.guardState == .active)
    #expect(rig.relocator.calls == 3)
}

@Test func driverTicksTheGuardAndFollowsSelectionChanges() {
    let rig = Rig()
    rig.driver.start()
    rig.run(1)
    #expect(rig.edgeGuard.calls.contains("tick"))

    rig.persistence.saveUUID(d1.identity.uuid)
    rig.run(1)
    #expect(rig.edgeGuard.pinned == d1.identity)
}

@Test func guardStateChangeAfterATickIsReported() {
    let rig = Rig()
    rig.edgeGuard.startsAs = .permissionMissing
    rig.driver.start()
    rig.edgeGuard.state = .active // granted later; the guard started itself on its tick
    rig.run(1)
    #expect(rig.log.guardValues == [.permissionMissing, .active])
}
