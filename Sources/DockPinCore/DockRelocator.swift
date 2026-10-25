import ApplicationServices
import CoreGraphics
import Foundation

/// Errores accionables del relocator.
public enum RelocationError: Error, Equatable, Sendable {
    case accessibilityNotTrusted
    case targetAmbiguous
    case bottomEdgeNotExposed
    case mouseButtonPressed
    case cursorUnavailable
    /// El usuario movió el mouse durante el intento; se abandonó sin restaurar.
    case userInterrupted
    case cancelled

    /// Si reintentar tiene sentido sin que cambie algo externo.
    public var isRetryable: Bool {
        switch self {
        case .mouseButtonPressed, .userInterrupted, .cancelled, .cursorUnavailable: return true
        case .accessibilityNotTrusted, .targetAmbiguous, .bottomEdgeNotExposed: return false
        }
    }

    public var outcome: RelocationOutcome {
        switch self {
        case .cancelled, .userInterrupted: return .cancelled
        default: return .failed(retryable: isRetryable)
        }
    }

    /// Mensaje para mostrar al usuario.
    public var guidance: String {
        switch self {
        case .accessibilityNotTrusted:
            return "Falta permiso de Accesibilidad. Habilitá la app (o la terminal que ejecuta el probe) " +
                "en Ajustes del Sistema > Privacidad y seguridad > Accesibilidad y reintentá."
        case .targetAmbiguous:
            return "El monitor elegido es indistinguible de otro (mismo UUID); no se puede relocalizar con seguridad."
        case .bottomEdgeNotExposed:
            return "El borde inferior del monitor elegido está cubierto por otro monitor; " +
                "el Dock no puede migrar ahí moviendo el cursor al borde de abajo."
        case .mouseButtonPressed:
            return "Hay un botón del mouse presionado; se pospone el intento."
        case .cursorUnavailable:
            return "No se pudo leer la posición del cursor."
        case .userInterrupted:
            return "Se detectó movimiento del mouse durante el intento; se abandonó sin tocar el cursor."
        case .cancelled:
            return "Intento cancelado."
        }
    }
}

/// Bandera de cancelación segura entre hilos.
public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    public init() {}

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        flag = true
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }
}

public protocol DockRelocating {
    /// Bloqueante; llamar fuera del hilo principal en una app real.
    func relocate(
        to target: DisplayInfo,
        among displays: [DisplayInfo],
        cancel: CancellationToken
    ) -> Result<Void, RelocationError>
}

/// Acceso al cursor detrás de un protocolo (fake en tests).
public protocol CursorControlling {
    func location() -> CGPoint?
    func warp(to point: CGPoint)
    /// Evento sintético `mouseMoved` mínimo en `point` (empuje hacia abajo de 1 px).
    func nudge(at point: CGPoint)
    func isMouseButtonDown() -> Bool
    /// Garantiza que cursor y mouse sigan asociados (nunca dejarlo desacoplado).
    func reassociate()
}

public protocol AccessibilityTrusting {
    var isTrusted: Bool { get }
}

public struct SystemAccessibilityTrust: AccessibilityTrusting {
    public init() {}
    /// No muestra el prompt del sistema; solo consulta.
    public var isTrusted: Bool { AXIsProcessTrusted() }
}

public struct SystemCursor: CursorControlling, Sendable {
    public init() {}

    public func location() -> CGPoint? { CGEvent(source: nil)?.location }

    public func warp(to point: CGPoint) {
        _ = CGWarpMouseCursorPosition(point)
    }

    public func nudge(at point: CGPoint) {
        guard let event = CGEvent(
            mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: point, mouseButton: .left
        ) else { return }
        event.setIntegerValueField(.mouseEventDeltaX, value: 0)
        event.setIntegerValueField(.mouseEventDeltaY, value: 1)
        event.post(tap: .cghidEventTap)
    }

    public func isMouseButtonDown() -> Bool {
        [CGMouseButton.left, .right, .center].contains {
            CGEventSource.buttonState(.combinedSessionState, button: $0)
        }
    }

    public func reassociate() {
        _ = CGAssociateMouseAndMouseCursorPosition(1)
    }
}

public struct RelocatorConfig: Equatable, Sendable {
    /// Cuánto se sostiene el cursor contra el borde inferior (el Dock migra tras un empuje sostenido).
    public var dwell: TimeInterval = 1.5
    public var step: TimeInterval = 0.05
    /// Desvío (px) respecto de la posición fijada a partir del cual se asume mouse del usuario.
    public var userMovementTolerance: CGFloat = 4
    /// Cuánto antes del borde físico se posiciona (px).
    public var edgeInset: CGFloat = 1

    public init() {}
}

/// Primer intento de relocación: lleva el cursor al borde inferior del monitor
/// objetivo y lo sostiene ahí; luego restaura la posición original.
///
/// Reglas de seguridad implementadas:
/// - Requiere `AXIsProcessTrusted` (eventos sintéticos); si no, error accionable.
/// - Nunca oculta el cursor ni lo desacopla (`reassociate()` en todos los caminos).
/// - Si hay un botón presionado, no empieza.
/// - Si el cursor se aleja de la posición fijada (usuario), aborta SIN restaurar,
///   para no pelear con la mano del usuario.
/// - Cancelable vía `CancellationToken`; el intento es acotado en tiempo (`dwell`).
///
/// ## A validar en runtime (nada de esto se probó con hardware real)
/// - Si basta un warp + dwell para que el Dock migre o hace falta empuje real.
/// - Duración mínima del dwell; si los `nudge` sintéticos ayudan o estorban.
/// - Supresión de eventos locales tras `CGWarpMouseCursorPosition`.
/// - Monitores en disposición vertical, bordes parcialmente expuestos, autohide.
/// - Que la restauración del cursor no dispare hot corners ni menús.
public struct CursorDockRelocator: DockRelocating {
    private let cursor: CursorControlling
    private let trust: AccessibilityTrusting
    private let config: RelocatorConfig
    private let sleep: (TimeInterval) -> Void

    public init(
        cursor: CursorControlling = SystemCursor(),
        trust: AccessibilityTrusting = SystemAccessibilityTrust(),
        config: RelocatorConfig = RelocatorConfig(),
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.cursor = cursor
        self.trust = trust
        self.config = config
        self.sleep = sleep
    }

    /// Punto sobre el borde inferior del monitor que NO esté cubierto por otro monitor.
    public static func bottomEdgePoint(
        of target: DisplayInfo,
        among displays: [DisplayInfo],
        inset: CGFloat = 1
    ) -> CGPoint? {
        let f = target.frame
        let y = f.maxY - inset
        let probes: [CGFloat] = [f.midX, f.minX + f.width / 4, f.minX + f.width * 3 / 4]
        return probes
            .map { CGPoint(x: $0, y: y) }
            .first { point in
                // Cubierto si justo debajo del borde cae otro monitor.
                let below = CGPoint(x: point.x, y: f.maxY + 1)
                return !displays.contains { $0.displayID != target.displayID && $0.frame.contains(below) }
            }
    }

    public func relocate(
        to target: DisplayInfo,
        among displays: [DisplayInfo],
        cancel: CancellationToken
    ) -> Result<Void, RelocationError> {
        guard trust.isTrusted else { return .failure(.accessibilityNotTrusted) }
        guard !target.isAmbiguous else { return .failure(.targetAmbiguous) }
        guard let edge = Self.bottomEdgePoint(of: target, among: displays, inset: config.edgeInset) else {
            return .failure(.bottomEdgeNotExposed)
        }
        guard !cursor.isMouseButtonDown() else { return .failure(.mouseButtonPressed) }
        guard let original = cursor.location() else { return .failure(.cursorUnavailable) }
        if cancel.isCancelled { return .failure(.cancelled) }

        defer { cursor.reassociate() }

        cursor.warp(to: edge)
        let steps = max(1, Int((config.dwell / config.step).rounded(.up)))
        for _ in 0..<steps {
            sleep(config.step)
            guard let now = cursor.location() else { return .failure(.cursorUnavailable) }
            if hypot(now.x - edge.x, now.y - edge.y) > config.userMovementTolerance {
                return .failure(.userInterrupted)
            }
            if cursor.isMouseButtonDown() { return .failure(.userInterrupted) }
            // Programmatic cancel (stop, display change) with the user's hand still:
            // put the cursor back where it was.
            if cancel.isCancelled {
                cursor.warp(to: original)
                return .failure(.cancelled)
            }
            cursor.nudge(at: edge)
        }

        cursor.warp(to: original)
        return .success(())
    }
}
