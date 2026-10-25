/// Dock Pin core: mechanism to keep the Dock on a chosen monitor.
///
/// Pieces (no UI yet):
/// - `DisplayIdentity` / `DisplayEnumerator`: stable monitor identity.
/// - `DockLocator`: detects which monitor holds the Dock (read-only).
/// - `EnforcementPolicy`: pure retry / cooldown / debounce logic.
/// - `DockRelocator`: moves the cursor to the bottom edge so the Dock migrates.
/// - `PinnedDisplayStore`: persisted display selection.
/// - `EnforcementDriver`: ties the policy to the locator, relocator and system events.
/// - `DockStatus`: what the driver reports to the UI.
public enum DockPinCore {
    public static let version = "0.2.0-phase2"
}
