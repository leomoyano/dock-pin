/// Dock Pin core: mecanismo para mantener el Dock en un monitor elegido.
///
/// Piezas (Fase 1, sin UI):
/// - `DisplayIdentity` / `DisplayEnumerator`: identidad estable de monitores.
/// - `DockLocator`: detecta en qué monitor está el Dock (solo lectura).
/// - `EnforcementPolicy`: lógica pura de reintentos/cooldown/debounce.
/// - `DockRelocator`: mueve el cursor al borde inferior para que el Dock migre.
public enum DockPinCore {
    public static let version = "0.1.0-fase1"
}
