import Foundation

public struct DriverConfig: Equatable, Sendable {
    public var enforcement = EnforcementConfig()
    /// How often the driver feeds the policy a tick (policy deadlines are checked here).
    public var tickInterval: TimeInterval = 0.5
    /// How long `stop()` waits for an in-flight relocation to finish and restore the cursor.
    public var stopWaitTimeout: TimeInterval = 1.0

    public init() {}
}

/// Glue between `EnforcementPolicy`, `DockLocator`, `DockRelocator` and the system
/// events. Everything external sits behind a protocol so tests drive it with fakes.
///
/// Threading: every method, the `onStatus` callback and every event handler run on
/// one serial "driver context" (see `Scheduling`). Only the blocking relocation
/// runs elsewhere and reports back through `runOnDriverContext`.
///
/// Safety properties (each covered by a test):
/// - No timers, observers or pending attempts survive `stop()`; after `stop()`
///   nothing moves the cursor and late completions are ignored.
/// - All cursor movement goes through the policy, so the retry budget, cooldown
///   and debounce always apply; there is no loop outside the policy.
/// - A relocation is never launched while another is still in flight.
/// - No selection, a disconnected selection, an ambiguous selection or an
///   unlocatable Dock never produce a relocation.
public final class EnforcementDriver: @unchecked Sendable {
    private let store: PinnedDisplayStore
    private let displayProvider: DisplayProviding
    private let locator: DockLocating
    private let relocator: DockRelocating
    private let trust: AccessibilityTrusting
    private let cursor: CursorControlling
    private let events: SystemEventSource
    private let activity: UserActivityProviding
    private let scheduler: Scheduling
    private let config: DriverConfig
    private let onStatus: @Sendable (DockStatus) -> Void
    private let edgeGuard: EdgeGuarding?
    private let onGuardState: @Sendable (GuardState) -> Void

    private var running = false
    private var policy: EnforcementPolicy?
    private var tickHandle: TimerHandle?
    private var knownSelection: DisplayIdentity?

    private var currentToken: CancellationToken?
    private var inFlight = false
    private let inFlightGroup = DispatchGroup()
    private var lastRelocationEnd: TimeInterval = -.infinity

    // Facts that explain the policy state for the status.
    private var lastAttempt = 0
    private var permissionMissing = false
    private var giveUpCause: GiveUpReason?
    private var lastUnknownReason: UnknownReason?

    public private(set) var status: DockStatus = .stopped
    public private(set) var guardState: GuardState = .inactive

    public init(
        store: PinnedDisplayStore,
        displayProvider: DisplayProviding,
        locator: DockLocating,
        relocator: DockRelocating,
        trust: AccessibilityTrusting,
        cursor: CursorControlling,
        events: SystemEventSource,
        activity: UserActivityProviding,
        scheduler: Scheduling,
        config: DriverConfig = DriverConfig(),
        edgeGuard: EdgeGuarding? = nil,
        onGuardState: @escaping @Sendable (GuardState) -> Void = { _ in },
        onStatus: @escaping @Sendable (DockStatus) -> Void = { _ in }
    ) {
        self.store = store
        self.displayProvider = displayProvider
        self.locator = locator
        self.relocator = relocator
        self.trust = trust
        self.cursor = cursor
        self.events = events
        self.activity = activity
        self.scheduler = scheduler
        self.config = config
        self.onStatus = onStatus
        self.edgeGuard = edgeGuard
        self.onGuardState = onGuardState
    }

    // MARK: - Lifecycle

    public func start() {
        guard !running else { return }
        running = true
        knownSelection = store.selected
        policy = EnforcementPolicy(config: config.enforcement, now: scheduler.now)
        resetFacts()
        edgeGuard?.setPinned(knownSelection)
        edgeGuard?.start()
        refreshGuardState()
        events.start { [weak self] trigger in self?.handle(trigger) }
        scheduleTick()
        refreshStatus()
    }

    /// Cancels timers and the pending attempt, unregisters the system callbacks and
    /// guarantees the cursor is re-associated with the mouse. Idempotent.
    public func stop() {
        guard running else { return }
        running = false
        tickHandle?.cancel()
        tickHandle = nil
        events.stop()
        edgeGuard?.stop()
        refreshGuardState()
        currentToken?.cancel()
        if inFlight {
            // Give the relocator the chance to restore the cursor before returning.
            _ = inFlightGroup.wait(timeout: .now() + config.stopWaitTimeout)
        }
        cursor.reassociate()
        currentToken = nil
        inFlight = false
        policy = nil
        status = .stopped
        onStatus(.stopped)
    }

    /// Call after the pinned display changed in the store (the driver also notices on its own at the next tick).
    public func selectionDidChange() {
        guard running else { return }
        checkSelectionChange()
    }

    // MARK: - Inputs

    private func handle(_ trigger: SystemTrigger) {
        guard running, knownSelection != nil else { return }
        resetFacts()
        switch trigger {
        case .displayConfigurationChanged: feed(.displayConfigurationChanged)
        case .systemDidWake: feed(.systemDidWake)
        }
    }

    private func scheduleTick() {
        tickHandle = scheduler.schedule(after: config.tickInterval) { [weak self] in self?.tick() }
    }

    private func tick() {
        guard running else { return }
        edgeGuard?.tick()
        refreshGuardState()
        checkSelectionChange()
        if knownSelection != nil {
            if permissionMissing, trust.isTrusted {
                // The user granted Accessibility: re-evaluate once (a single restart, not a retry loop).
                resetFacts()
                feed(.selectionChanged)
            }
            feedUserActivity()
            feed(.tick)
        } else {
            refreshStatus()
        }
        if running { scheduleTick() }
    }

    private func checkSelectionChange() {
        let current = store.selected
        guard current != knownSelection else { return }
        knownSelection = current
        edgeGuard?.setPinned(current)
        resetFacts()
        if current != nil {
            feed(.selectionChanged)
        } else {
            // Selection cleared: stop any attempt in progress and report it.
            currentToken?.cancel()
            refreshStatus()
        }
    }

    private func feedUserActivity() {
        // While our own relocation runs, input events are ours (the relocator
        // watches for the real user itself). Afterwards, ignore events that
        // our synthetic nudges produced.
        guard !inFlight, let idle = activity.secondsSinceLastInput else { return }
        let eventTime = scheduler.now - idle
        guard idle <= config.tickInterval * 1.5, eventTime > lastRelocationEnd + 0.25 else { return }
        feed(.userActivity)
    }

    // MARK: - Policy plumbing

    private func feed(_ event: PolicyEvent) {
        guard running, var current = policy else { return }
        let action = current.handle(event, now: scheduler.now)
        policy = current
        perform(action)
        refreshStatus()
    }

    private func perform(_ action: PolicyAction) {
        switch action {
        case .none:
            break
        case .cancelRelocation:
            currentToken?.cancel()
        case .requestObservation:
            lastUnknownReason = nil
            feed(.observed(observe()))
        case let .relocate(attempt):
            launchRelocation(attempt: attempt)
        }
    }

    private func observe() -> Observation {
        guard let selected = knownSelection else {
            return Observation(targetConnected: false, placement: .unknown)
        }
        let displays = displayProvider.connectedDisplays()
        let matches = displays.filter { $0.identity == selected }
        guard let target = matches.first else {
            return Observation(targetConnected: false, placement: .unknown)
        }
        guard matches.count == 1, !target.isAmbiguous else {
            lastUnknownReason = .ambiguousDisplay
            return Observation(targetConnected: true, placement: .unknown)
        }
        switch locator.locate(in: displays) {
        case let .onDisplay(identity):
            return Observation(targetConnected: true, placement: identity == selected ? .onTarget : .onOtherDisplay)
        case let .unknown(reason):
            lastUnknownReason = reason
            return Observation(targetConnected: true, placement: .unknown)
        }
    }

    private func launchRelocation(attempt: Int) {
        lastAttempt = attempt
        let displays = displayProvider.connectedDisplays()
        let matches = displays.filter { $0.identity == knownSelection }
        guard !inFlight, matches.count == 1, let target = matches.first, !target.isAmbiguous else {
            // Target vanished between observation and launch, or a previous attempt
            // has not returned yet: do not touch the cursor.
            feed(.relocationFinished(.cancelled))
            return
        }
        let token = CancellationToken()
        currentToken = token
        inFlight = true
        inFlightGroup.enter()
        scheduler.runInBackground { [self] in
            let result = relocator.relocate(to: target, among: displays, cancel: token)
            inFlightGroup.leave()
            scheduler.runOnDriverContext { [self] in relocationFinished(result, token: token) }
        }
    }

    private func relocationFinished(_ result: Result<Void, RelocationError>, token: CancellationToken) {
        guard running else { return }
        if token === currentToken {
            currentToken = nil
            inFlight = false
        }
        lastRelocationEnd = scheduler.now
        switch result {
        case .success:
            feed(.relocationFinished(.completed))
        case let .failure(error):
            if error == .accessibilityNotTrusted {
                permissionMissing = true
            } else if !error.isRetryable {
                giveUpCause = .relocationFailed(error)
            }
            feed(.relocationFinished(error.outcome))
        }
    }

    // MARK: - Status

    private func resetFacts() {
        lastAttempt = 0
        permissionMissing = false
        giveUpCause = nil
        lastUnknownReason = nil
    }

    private func refreshGuardState() {
        guard let edgeGuard, edgeGuard.state != guardState else { return }
        guardState = edgeGuard.state
        onGuardState(guardState)
    }

    private func refreshStatus() {
        let next = computeStatus()
        guard next != status else { return }
        status = next
        onStatus(next)
    }

    private func computeStatus() -> DockStatus {
        guard running, let policy else { return .stopped }
        guard let selected = knownSelection else { return .noSelection }
        switch policy.state {
        case .settling:
            return .checking
        case .checking:
            // A periodic re-check does not invalidate what was already known.
            switch status {
            case .pinned, .unknownPlacement: return status
            default: return .checking
            }
        case .satisfied:
            return .pinned(selected)
        case .unknownPlacement:
            return .unknownPlacement(lastUnknownReason)
        case let .relocating(attempt, _):
            return .relocating(attempt: attempt)
        case .cooldown:
            return .awaitingRecheck(afterAttempt: lastAttempt)
        case .waitingForTarget:
            return .waitingForDisplay(selected)
        case .gaveUp:
            if permissionMissing { return .accessibilityPermissionMissing }
            return .gaveUp(giveUpCause ?? .attemptsExhausted(attempts: lastAttempt))
        }
    }
}
