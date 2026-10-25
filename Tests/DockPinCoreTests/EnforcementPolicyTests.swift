import Foundation
import Testing
@testable import DockPinCore

private final class ManualClock: MonotonicClock {
    var now: TimeInterval = 1000
    func advance(_ seconds: TimeInterval) { now += seconds }
}

/// Arnés mínimo: reloj manual + política.
private struct Harness {
    let clock = ManualClock()
    var policy: EnforcementPolicy
    var config: EnforcementConfig

    init(_ config: EnforcementConfig = EnforcementConfig()) {
        self.config = config
        policy = EnforcementPolicy(config: config, now: 1000)
    }

    @discardableResult
    mutating func send(_ event: PolicyEvent) -> PolicyAction {
        policy.handle(event, now: clock.now)
    }

    mutating func advance(_ s: TimeInterval) { clock.advance(s) }

    /// Avanza hasta que `settle` pasó y pide la observación inicial.
    mutating func reachChecking() {
        advance(config.settleDebounce)
        #expect(send(.tick) == .requestObservation)
    }

    /// Observa Dock en otro monitor y devuelve la acción.
    @discardableResult
    mutating func observeWrong() -> PolicyAction {
        send(.observed(Observation(targetConnected: true, placement: .onOtherDisplay)))
    }

    /// Un ciclo completo: espera cooldown, observa mal, relocaliza, termina ok.
    mutating func failedAttemptCycle() -> PolicyAction {
        advance(config.cooldown)
        let req = send(.tick)
        guard req == .requestObservation else { return req }
        let action = observeWrong()
        if case .relocate = action { send(.relocationFinished(.completed)) }
        return action
    }
}

@Test func waitsForDebounceBeforeFirstObservation() {
    var h = Harness()
    #expect(h.send(.tick) == .none)
    h.advance(1.9)
    #expect(h.send(.tick) == .none)
    h.advance(0.2)
    #expect(h.send(.tick) == .requestObservation)
}

@Test func displayChangesExtendDebounce() {
    var h = Harness()
    h.advance(1.5)
    h.send(.displayConfigurationChanged)
    h.advance(1.5)
    #expect(h.send(.tick) == .none) // 1.5 < 2.0 desde el último cambio
    h.advance(0.6)
    #expect(h.send(.tick) == .requestObservation)
}

@Test func wakeRestartsSettling() {
    var h = Harness()
    h.reachChecking()
    h.send(.systemDidWake)
    #expect(h.send(.tick) == .none)
    h.advance(h.config.settleDebounce)
    #expect(h.send(.tick) == .requestObservation)
}

@Test func dockOnTargetDoesNothingAndRechecksOnPoll() {
    var h = Harness()
    h.reachChecking()
    #expect(h.send(.observed(Observation(targetConnected: true, placement: .onTarget))) == .none)
    #expect(h.send(.tick) == .none)
    h.advance(h.config.pollInterval)
    #expect(h.send(.tick) == .requestObservation)
}

@Test func relocatesWhenDockOnOtherDisplay() {
    var h = Harness()
    h.reachChecking()
    #expect(h.observeWrong() == .relocate(attempt: 1))
}

@Test func unknownPlacementNeverRelocates() {
    var h = Harness()
    h.reachChecking()
    #expect(h.send(.observed(Observation(targetConnected: true, placement: .unknown))) == .none)
    for _ in 0..<20 {
        h.advance(h.config.pollInterval)
        if h.send(.tick) == .requestObservation {
            #expect(h.send(.observed(Observation(targetConnected: true, placement: .unknown))) == .none)
        }
    }
}

@Test func disconnectedTargetMovesNothingAndOnlyRechecksReadOnly() {
    var h = Harness()
    h.reachChecking()
    #expect(h.send(.observed(Observation(targetConnected: false, placement: .unknown))) == .none)
    #expect({ if case .waitingForTarget = h.policy.state { return true } else { return false } }())
    for _ in 0..<50 {
        h.advance(h.config.pollInterval)
        let action = h.send(.tick)
        #expect(action == .none || action == .requestObservation)
        if action == .requestObservation {
            #expect(h.send(.observed(Observation(targetConnected: false, placement: .unknown))) == .none)
        }
    }
}

@Test func reconnectedTargetIsNoticedByPollingWithoutAnyEvent() {
    var h = Harness()
    h.reachChecking()
    _ = h.send(.observed(Observation(targetConnected: false, placement: .unknown)))
    h.advance(h.config.pollInterval)
    #expect(h.send(.tick) == .requestObservation)
    #expect(h.send(.observed(Observation(targetConnected: true, placement: .onOtherDisplay))) != .none)
}

@Test func reconnectResumesEnforcement() {
    var h = Harness()
    h.reachChecking()
    h.send(.observed(Observation(targetConnected: false, placement: .unknown)))
    h.send(.displayConfigurationChanged)
    h.advance(h.config.settleDebounce)
    #expect(h.send(.tick) == .requestObservation)
    #expect(h.observeWrong() == .relocate(attempt: 1))
}

@Test func attemptsAreBoundedThenGivesUp() {
    var h = Harness()
    h.reachChecking()
    var relocations = 0
    if case .relocate = h.observeWrong() { relocations += 1; h.send(.relocationFinished(.completed)) }
    for _ in 0..<20 {
        if case .relocate = h.failedAttemptCycle() { relocations += 1 }
    }
    #expect(relocations == h.config.maxAttempts)
    #expect(h.policy.state == .gaveUp)
    h.advance(1000)
    #expect(h.send(.tick) == .none)
}

@Test func externalTriggerResetsAttemptBudget() {
    var h = Harness()
    h.reachChecking()
    if case .relocate = h.observeWrong() { h.send(.relocationFinished(.completed)) }
    for _ in 0..<5 { _ = h.failedAttemptCycle() }
    #expect(h.policy.state == .gaveUp)
    h.send(.systemDidWake)
    h.advance(h.config.settleDebounce)
    #expect(h.send(.tick) == .requestObservation)
    #expect(h.observeWrong() == .relocate(attempt: 1))
}

@Test func cooldownBetweenAttempts() {
    var h = Harness()
    h.reachChecking()
    #expect(h.observeWrong() == .relocate(attempt: 1))
    h.send(.relocationFinished(.completed))
    h.advance(1)
    #expect(h.send(.tick) == .none) // aún en cooldown
    h.advance(h.config.cooldown)
    #expect(h.send(.tick) == .requestObservation)
}

@Test func cooldownSurvivesOnTargetResetOfBudget() {
    var h = Harness()
    h.reachChecking()
    h.observeWrong()
    h.send(.relocationFinished(.completed))
    // Dock confirmado en su lugar (reinicia la racha) y vuelve a salirse enseguida.
    h.advance(h.config.cooldown)
    h.send(.tick)
    h.send(.observed(Observation(targetConnected: true, placement: .onTarget)))
    h.advance(h.config.cooldown / 2)
    h.send(.displayConfigurationChanged) // vuelve a asentar; no cambia lastRelocationStart
    h.advance(h.config.settleDebounce)
    h.send(.tick)
    // Se superó el cooldown real desde el último intento, así que ya puede relocalizar.
    #expect(h.observeWrong() == .relocate(attempt: 1))
}

@Test func userActivityCancelsRunningAttempt() {
    var h = Harness()
    h.reachChecking()
    #expect(h.observeWrong() == .relocate(attempt: 1))
    #expect(h.send(.userActivity) == .cancelRelocation)
    #expect(h.send(.relocationFinished(.cancelled)) == .none)
    h.advance(h.config.cooldown)
    #expect(h.send(.tick) == .requestObservation)
}

@Test func cancelledAttemptStillCountsTowardsBudget() {
    var h = Harness()
    h.reachChecking()
    var relocations = 0
    for i in 0..<10 {
        let action = i == 0 ? h.observeWrong() : h.failedAttemptCycle()
        if case .relocate = action {
            relocations += 1
            // El usuario interrumpe cada intento.
            h.send(.userActivity)
        }
    }
    #expect(relocations == h.config.maxAttempts)
}

@Test func noAttemptStartsDuringUserActivity() {
    var h = Harness()
    h.reachChecking()
    h.send(.userActivity)
    // Sigue moviendo el mouse: se difiere, no se relocaliza.
    #expect(h.observeWrong() == .none)
    #expect(h.policy.state == .cooldown(until: h.clock.now + h.config.userQuietPeriod))
    h.advance(h.config.userQuietPeriod)
    #expect(h.send(.tick) == .requestObservation)
    #expect(h.observeWrong() == .relocate(attempt: 1))
}

@Test func attemptTimeoutCancelsAndCoolsDown() {
    var h = Harness()
    h.reachChecking()
    h.observeWrong()
    h.advance(h.config.attemptTimeout)
    #expect(h.send(.tick) == .cancelRelocation)
    guard case .cooldown = h.policy.state else {
        Issue.record("esperaba cooldown, estado: \(h.policy.state)")
        return
    }
}

@Test func nonRetryableFailureGivesUpImmediately() {
    var h = Harness()
    h.reachChecking()
    h.observeWrong()
    h.send(.relocationFinished(.failed(retryable: false)))
    #expect(h.policy.state == .gaveUp)
    h.advance(1000)
    #expect(h.send(.tick) == .none)
}

@Test func displayChangeDuringAttemptCancelsIt() {
    var h = Harness()
    h.reachChecking()
    h.observeWrong()
    #expect(h.send(.displayConfigurationChanged) == .cancelRelocation)
}

@Test func observationTimeoutDegradesToUnknownWithoutMoving() {
    var h = Harness()
    h.reachChecking()
    h.advance(h.config.observationTimeout)
    #expect(h.send(.tick) == .none)
    guard case .unknownPlacement = h.policy.state else {
        Issue.record("esperaba unknownPlacement, estado: \(h.policy.state)")
        return
    }
}

@Test func staleObservationOutsideCheckingIsIgnored() {
    var h = Harness()
    #expect(h.observeWrong() == .none) // aún settling
}

@Test func selectionChangeChecksImmediately() {
    var h = Harness()
    h.reachChecking()
    h.send(.observed(Observation(targetConnected: true, placement: .onTarget)))
    h.send(.selectionChanged)
    #expect(h.send(.tick) == .requestObservation)
}
