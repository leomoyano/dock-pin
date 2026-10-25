import Foundation

/// Reloj monotónico inyectable (segundos). La política es pura: recibe `now`
/// en cada llamada; este protocolo solo lo provee el driver y los tests.
public protocol MonotonicClock {
    var now: TimeInterval { get }
}

public struct SystemClock: MonotonicClock {
    public init() {}
    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

public struct EnforcementConfig: Equatable, Sendable {
    /// Espera tras cambio de display / wake / cambio de selección antes de observar.
    public var settleDebounce: TimeInterval = 2.0
    /// Mínimo entre el inicio de dos intentos de relocación.
    public var cooldown: TimeInterval = 5.0
    /// Intentos consecutivos sin éxito antes de rendirse hasta un disparador externo.
    public var maxAttempts: Int = 3
    /// Tiempo máximo de un intento de relocación.
    public var attemptTimeout: TimeInterval = 4.0
    /// Quietud mínima del usuario (mouse/teclado) antes de empezar un intento.
    public var userQuietPeriod: TimeInterval = 1.0
    /// Intervalo de re-chequeo cuando el Dock está en su lugar o desconocido.
    public var pollInterval: TimeInterval = 10.0
    /// Tiempo máximo esperando una observación pedida.
    public var observationTimeout: TimeInterval = 3.0

    public init() {}
}

/// Qué ve el driver cuando la política pide una observación.
public struct Observation: Equatable, Sendable {
    public enum Placement: Equatable, Sendable {
        case onTarget
        case onOtherDisplay
        case unknown
    }

    public var targetConnected: Bool
    public var placement: Placement

    public init(targetConnected: Bool, placement: Placement) {
        self.targetConnected = targetConnected
        self.placement = placement
    }
}

public enum RelocationOutcome: Equatable, Sendable {
    case completed
    case cancelled
    /// `retryable == false` (p. ej. falta de permisos): no tiene sentido reintentar.
    case failed(retryable: Bool)
}

public enum PolicyEvent: Equatable, Sendable {
    case displayConfigurationChanged
    case systemDidWake
    case selectionChanged
    case userActivity
    case observed(Observation)
    case relocationFinished(RelocationOutcome)
    case tick
}

public enum PolicyAction: Equatable, Sendable {
    case none
    case requestObservation
    /// `attempt` es 1-based dentro de la racha actual.
    case relocate(attempt: Int)
    case cancelRelocation
}

public enum PolicyState: Equatable, Sendable {
    /// Esperando a que el display se asiente tras un cambio.
    case settling(until: TimeInterval)
    /// Observación pedida, esperando respuesta.
    case checking(deadline: TimeInterval)
    /// Dock en el monitor elegido; re-chequeo periódico.
    case satisfied(nextCheck: TimeInterval)
    /// Ubicación desconocida: no se mueve nada; re-chequeo periódico.
    case unknownPlacement(nextCheck: TimeInterval)
    case relocating(attempt: Int, deadline: TimeInterval)
    case cooldown(until: TimeInterval)
    /// Monitor elegido desconectado: no se mueve nada ni se reintenta; solo un
    /// cambio de display/wake/selección reevalúa.
    case waitingForTarget
    /// Intentos agotados o error no reintentable: inactivo hasta un disparador externo.
    case gaveUp
}

/// Máquina de estados PURA del enforcement por corrección posterior.
///
/// Garantías (cada una con test):
/// - Nunca hay más de `maxAttempts` relocaciones consecutivas sin un disparador
///   externo (display/wake/selección) o sin confirmar el Dock en su lugar.
/// - Dos relocaciones están separadas por al menos `cooldown`, incluso si una
///   observación `.onTarget` reinició la racha de intentos.
/// - Tras cambios de display/wake se espera `settleDebounce` (se extiende si
///   llegan más cambios) antes de observar.
/// - Actividad del usuario durante un intento lo cancela; no se empieza un
///   intento hasta `userQuietPeriod` de quietud.
/// - Monitor elegido desconectado, o ubicación desconocida: nunca se relocaliza.
/// - Tiempo agotado de un intento u observación: se cancela/degrada, no se repite en loop.
public struct EnforcementPolicy: Sendable {
    public let config: EnforcementConfig
    public private(set) var state: PolicyState

    private var attempts = 0
    private var lastUserActivity: TimeInterval?
    private var lastRelocationStart: TimeInterval?

    public init(config: EnforcementConfig = EnforcementConfig(), now: TimeInterval) {
        self.config = config
        self.state = .settling(until: now + config.settleDebounce)
    }

    public mutating func handle(_ event: PolicyEvent, now: TimeInterval) -> PolicyAction {
        switch event {
        case .displayConfigurationChanged, .systemDidWake:
            return restart(settleUntil: now + config.settleDebounce)

        case .selectionChanged:
            return restart(settleUntil: now)

        case .userActivity:
            lastUserActivity = now
            if case .relocating = state {
                state = .cooldown(until: cooldownEnd(now: now))
                return .cancelRelocation
            }
            return .none

        case let .observed(observation):
            guard case .checking = state else { return .none }
            return apply(observation, now: now)

        case let .relocationFinished(outcome):
            guard case .relocating = state else { return .none }
            switch outcome {
            case .completed, .cancelled:
                state = .cooldown(until: cooldownEnd(now: now))
            case .failed(retryable: true):
                state = .cooldown(until: cooldownEnd(now: now))
            case .failed(retryable: false):
                state = .gaveUp
            }
            return .none

        case .tick:
            return tick(now: now)
        }
    }

    // MARK: - Internals

    private mutating func restart(settleUntil: TimeInterval) -> PolicyAction {
        let wasRelocating: Bool
        if case .relocating = state { wasRelocating = true } else { wasRelocating = false }
        attempts = 0
        state = .settling(until: settleUntil)
        return wasRelocating ? .cancelRelocation : .none
    }

    private func cooldownEnd(now: TimeInterval) -> TimeInterval {
        max(now, (lastRelocationStart ?? -.infinity) + config.cooldown)
    }

    private mutating func apply(_ observation: Observation, now: TimeInterval) -> PolicyAction {
        guard observation.targetConnected else {
            attempts = 0
            state = .waitingForTarget
            return .none
        }
        switch observation.placement {
        case .onTarget:
            attempts = 0
            state = .satisfied(nextCheck: now + config.pollInterval)
            return .none
        case .unknown:
            state = .unknownPlacement(nextCheck: now + config.pollInterval)
            return .none
        case .onOtherDisplay:
            guard attempts < config.maxAttempts else {
                state = .gaveUp
                return .none
            }
            let notBefore = max(
                cooldownEnd(now: now),
                (lastUserActivity ?? -.infinity) + config.userQuietPeriod
            )
            if notBefore > now {
                state = .cooldown(until: notBefore)
                return .none
            }
            attempts += 1
            lastRelocationStart = now
            state = .relocating(attempt: attempts, deadline: now + config.attemptTimeout)
            return .relocate(attempt: attempts)
        }
    }

    private mutating func tick(now: TimeInterval) -> PolicyAction {
        switch state {
        case let .settling(until) where now >= until,
             let .cooldown(until) where now >= until,
             let .satisfied(until) where now >= until,
             let .unknownPlacement(until) where now >= until:
            state = .checking(deadline: now + config.observationTimeout)
            return .requestObservation
        case let .checking(deadline) where now >= deadline:
            state = .unknownPlacement(nextCheck: now + config.pollInterval)
            return .none
        case let .relocating(_, deadline) where now >= deadline:
            state = .cooldown(until: cooldownEnd(now: now))
            return .cancelRelocation
        default:
            return .none
        }
    }
}
