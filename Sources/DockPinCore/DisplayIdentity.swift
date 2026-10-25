import ColorSync
import CoreGraphics
import Foundation

/// Identidad estable de un monitor físico: el UUID que devuelve
/// `CGDisplayCreateUUIDFromDisplayID`. A diferencia del `CGDirectDisplayID`
/// (que puede cambiar entre reinicios o reconexiones), el UUID se deriva de
/// vendor/modelo/serial y sobrevive a reconexiones.
public struct DisplayIdentity: Hashable, Sendable, Codable, CustomStringConvertible {
    public let uuid: String

    public init(uuid: String) {
        self.uuid = uuid.uppercased()
    }

    public var description: String { uuid }
}

/// Un monitor conectado, con su frame en coordenadas globales de CoreGraphics
/// (origen arriba-izquierda del monitor principal, Y crece hacia abajo; el mismo
/// espacio que usan `CGDisplayBounds`, `CGWarpMouseCursorPosition` y los bounds
/// de `CGWindowListCopyWindowInfo`).
public struct DisplayInfo: Sendable, Equatable {
    public let identity: DisplayIdentity
    public let displayID: CGDirectDisplayID
    public let frame: CGRect
    public let isMain: Bool
    public let isBuiltin: Bool
    /// `true` si otro monitor conectado comparte el mismo UUID.
    /// Ver "Decisión sobre monitores idénticos" en `DisplaySelection`.
    public let isAmbiguous: Bool

    public init(
        identity: DisplayIdentity,
        displayID: CGDirectDisplayID,
        frame: CGRect,
        isMain: Bool = false,
        isBuiltin: Bool = false,
        isAmbiguous: Bool = false
    ) {
        self.identity = identity
        self.displayID = displayID
        self.frame = frame
        self.isMain = isMain
        self.isBuiltin = isBuiltin
        self.isAmbiguous = isAmbiguous
    }
}

/// Fuente de monitores conectados (protocolo para poder usar un fake en tests).
public protocol DisplayProviding {
    func connectedDisplays() -> [DisplayInfo]
}

/// Enumeración real vía CoreGraphics (solo lectura).
public struct SystemDisplayProvider: DisplayProviding {
    public init() {}

    public func connectedDisplays() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        let raw: [DisplayInfo] = ids.prefix(Int(count)).compactMap { id in
            guard let uuid = Self.uuid(for: id) else { return nil }
            return DisplayInfo(
                identity: DisplayIdentity(uuid: uuid),
                displayID: id,
                frame: CGDisplayBounds(id),
                isMain: CGDisplayIsMain(id) != 0,
                isBuiltin: CGDisplayIsBuiltin(id) != 0
            )
        }
        return markAmbiguous(raw)
    }

    private static func uuid(for id: CGDirectDisplayID) -> String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, cfUUID) as String?
    }
}

/// Marca como ambiguos los monitores cuyo UUID se repite entre los conectados.
public func markAmbiguous(_ displays: [DisplayInfo]) -> [DisplayInfo] {
    var counts: [DisplayIdentity: Int] = [:]
    for d in displays { counts[d.identity, default: 0] += 1 }
    return displays.map { d in
        DisplayInfo(
            identity: d.identity,
            displayID: d.displayID,
            frame: d.frame,
            isMain: d.isMain,
            isBuiltin: d.isBuiltin,
            isAmbiguous: (counts[d.identity] ?? 0) > 1
        )
    }
}

/// Cómo el usuario/CLI nombra un monitor.
public enum DisplaySelector: Equatable, Sendable {
    case uuid(DisplayIdentity)
    /// Posición en la lista de `displays` (base 0).
    case index(Int)

    /// Acepta un entero (índice) o un UUID.
    public static func parse(_ text: String) -> DisplaySelector? {
        if let n = Int(text), n >= 0 { return .index(n) }
        if UUID(uuidString: text) != nil { return .uuid(DisplayIdentity(uuid: text)) }
        return nil
    }
}

public enum DisplayResolutionError: Error, Equatable, Sendable {
    case notConnected
    case indexOutOfRange(Int, available: Int)
    /// Varios monitores conectados comparten el UUID; no se puede elegir uno solo por UUID.
    case ambiguousIdentity(candidates: Int)
}

extension DisplayResolutionError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notConnected:
            return "El monitor elegido no está conectado."
        case let .indexOutOfRange(i, n):
            return "Índice \(i) fuera de rango (hay \(n) monitor(es))."
        case let .ambiguousIdentity(n):
            return "\(n) monitores conectados comparten el mismo UUID (monitores idénticos); " +
                "elegí por índice y tené en cuenta que no hay identidad estable."
        }
    }
}

/// Resolución de un selector contra los monitores conectados (lógica pura).
///
/// ## Decisión sobre monitores idénticos
/// Dos monitores del mismo modelo sin serial único pueden devolver el mismo UUID.
/// Decisión de Fase 1:
/// - Por UUID: si coinciden varios, se devuelve `.ambiguousIdentity`; NO se adivina.
///   El enforcement automático debe tratarlo como layout no soportado y mostrarlo
///   (criterio de aceptación 5 del brief), no como éxito.
/// - Por índice: se permite (uso manual del probe), marcando `isAmbiguous` en el
///   resultado para que el CLI advierta que ese índice no es persistible.
/// - Persistir una elección ambigua queda fuera de Fase 1 (hay que validar con
///   hardware real si el UUID realmente colisiona).
public enum DisplaySelection {
    public static func resolve(
        _ selector: DisplaySelector,
        in displays: [DisplayInfo]
    ) -> Result<DisplayInfo, DisplayResolutionError> {
        switch selector {
        case let .index(i):
            guard displays.indices.contains(i) else {
                return .failure(.indexOutOfRange(i, available: displays.count))
            }
            return .success(displays[i])
        case let .uuid(identity):
            let matches = displays.filter { $0.identity == identity }
            switch matches.count {
            case 0: return .failure(.notConnected)
            case 1: return .success(matches[0])
            default: return .failure(.ambiguousIdentity(candidates: matches.count))
            }
        }
    }
}
