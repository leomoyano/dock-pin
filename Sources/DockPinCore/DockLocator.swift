import CoreGraphics
import Foundation

/// Ventana de otro proceso tal como la reporta `CGWindowListCopyWindowInfo`.
public struct WindowSnapshot: Sendable, Equatable {
    public let ownerName: String
    public let layer: Int
    public let bounds: CGRect

    public init(ownerName: String, layer: Int, bounds: CGRect) {
        self.ownerName = ownerName
        self.layer = layer
        self.bounds = bounds
    }
}

public protocol WindowListProviding {
    /// `nil` si la lista no se pudo obtener.
    func windows() -> [WindowSnapshot]?
}

/// Lectura real (solo lectura) de las ventanas en pantalla.
public struct SystemWindowListProvider: WindowListProviding {
    public init() {}

    public func windows() -> [WindowSnapshot]? {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        return raw.compactMap { entry in
            guard let owner = entry[kCGWindowOwnerName as String] as? String,
                  let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { return nil }
            return WindowSnapshot(ownerName: owner, layer: layer, bounds: bounds)
        }
    }
}

public enum DockPlacement: Equatable, Sendable {
    case onDisplay(DisplayIdentity)
    case unknown(UnknownReason)
}

/// Un Dock no localizable es DESCONOCIDO, nunca "en el monitor equivocado".
public enum UnknownReason: Equatable, Sendable {
    case windowListUnavailable
    case noDisplays
    /// No hay ventana del Dock en el layer esperado (autohide, Spaces, fullscreen, permisos).
    case noDockWindow
    /// El punto medio de la ventana no cae en ningún monitor conocido.
    case dockOutsideAllDisplays
    /// Varias ventanas candidatas apuntan a monitores distintos.
    case conflictingDockWindows
    /// Hay monitores idénticos (mismo UUID): la identidad no distingue entre ellos.
    case ambiguousDisplay
}

/// Detecta en qué monitor está el Dock.
///
/// Método: ventanas con owner "Dock" en `dockWindowLevel`; se toma el punto medio
/// de sus bounds y se busca el monitor que lo contiene.
///
/// ## Limitaciones (a validar en runtime)
/// - **Autohide**: con el Dock oculto su ventana puede estar fuera de pantalla o
///   ausente → `.unknown(.noDockWindow)`; no se debe "corregir" a ciegas.
/// - **Spaces / fullscreen**: en un Space con app a pantalla completa el Dock no
///   tiene ventana visible en ese monitor → desconocido.
/// - **Permisos**: `ownerName`, `layer` y `bounds` no requieren Screen Recording
///   (sí los títulos, que no usamos), pero hay que confirmarlo en macOS 27.
/// - **Layer**: se asume `CGWindowLevelForKey(.dockWindow)` (20). Si el Dock
///   expone otras ventanas en ese layer (p. ej. zonas activas) el filtro por
///   ventana de mayor área debería bastar; validar con `dockpin-probe locate`.
/// - Dock lateral (izq./der.): el punto medio igual cae en el monitor correcto,
///   pero el relocator solo soporta Dock inferior en Fase 1.
public struct DockLocator {
    public static let dockWindowLevel = Int(CGWindowLevelForKey(.dockWindow))
    public static let dockOwnerName = "Dock"

    private let windowProvider: WindowListProviding

    public init(windowProvider: WindowListProviding = SystemWindowListProvider()) {
        self.windowProvider = windowProvider
    }

    public func locate(in displays: [DisplayInfo]) -> DockPlacement {
        guard let windows = windowProvider.windows() else { return .unknown(.windowListUnavailable) }
        return Self.locate(windows: windows, in: displays)
    }

    /// Núcleo puro y testeable.
    public static func locate(windows: [WindowSnapshot], in displays: [DisplayInfo]) -> DockPlacement {
        guard !displays.isEmpty else { return .unknown(.noDisplays) }

        let candidates = windows.filter {
            $0.ownerName == dockOwnerName
                && $0.layer == dockWindowLevel
                && $0.bounds.width > 0 && $0.bounds.height > 0
        }
        guard !candidates.isEmpty else { return .unknown(.noDockWindow) }

        var hits: [DisplayInfo] = []
        for window in candidates {
            let mid = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
            if let display = displays.first(where: { $0.frame.contains(mid) }) {
                hits.append(display)
            }
        }
        guard let first = hits.first else { return .unknown(.dockOutsideAllDisplays) }
        guard hits.allSatisfy({ $0.displayID == first.displayID }) else {
            return .unknown(.conflictingDockWindows)
        }
        if first.isAmbiguous { return .unknown(.ambiguousDisplay) }
        return .onDisplay(first.identity)
    }
}
