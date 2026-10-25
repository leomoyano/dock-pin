import CoreGraphics
import Foundation
import os

/// Whether the pointer guard is doing its job.
public enum GuardState: Equatable, Sendable {
    /// Not running (never started, stopped, or disabled).
    case inactive
    /// The event tap is installed and the pointer is kept out of the forbidden strips.
    case active
    /// The event tap could not be created, which on macOS means Accessibility is not granted.
    case permissionMissing
}

extension GuardState: CustomStringConvertible {
    public var description: String {
        switch self {
        case .inactive:
            return "Edge guard inactive."
        case .active:
            return "Edge guard active: the pointer cannot reach the bottom edge of the other displays."
        case .permissionMissing:
            return "Edge guard unavailable: Accessibility permission is missing. Grant it in System Settings > " +
                "Privacy & Security > Accessibility; it is re-checked automatically."
        }
    }
}

/// Decides, per mouse-moved event, a corrected location (or `nil` to leave it alone).
/// Runs on the tap's thread: keep it fast and allocation-free.
public typealias EdgeMoveHandler = @Sendable (CGPoint) -> CGPoint?

/// The CoreGraphics event tap behind a protocol, so the guard lifecycle is testable with fakes.
///
/// A real implementation applies a returned correction to the event itself (and warps the
/// cursor if needed) exactly once per event.
public protocol EventTapping: AnyObject {
    /// Installs an active filter for mouse-moved events only. Returns `false` when the tap
    /// cannot be created (no Accessibility). Calling it while installed is a no-op returning `true`.
    func install(onMove: @escaping EdgeMoveHandler, onDisabled: @escaping @Sendable () -> Void) -> Bool
    /// Re-enables a tap the system disabled (timeout or user input). Safe from the tap thread.
    func reenable()
    /// Removes the tap and its run-loop source. Idempotent.
    func remove()
}

/// What `EnforcementDriver` needs from the guard.
public protocol EdgeGuarding: AnyObject {
    var state: GuardState { get }
    func start()
    func stop()
    /// Tells the guard which display is pinned (`nil`: guard nothing).
    func setPinned(_ identity: DisplayIdentity?)
    /// Periodic hook: starts the guard once Accessibility is granted.
    func tick()
}

/// Keeps the pointer out of the bottom strip of every display except the pinned one, so
/// the Dock never gets the push that makes it migrate.
///
/// Threading: lifecycle methods and system-event handlers run on one serial context
/// (the main queue in the real build). Only the layout is shared with the tap thread, behind
/// an unfair lock; the tap callback never allocates and applies at most one correction per event.
///
/// Safety properties (each covered by a test):
/// - If the tap cannot be created, nothing is installed and the state is `.permissionMissing`.
/// - No pinned display connected (or an ambiguous one): the layout is inert, so the pointer is never held.
/// - A held mouse button disables the correction, so dragging a window across the edge works.
/// - `stop()` removes the tap and unregisters the system callbacks.
public final class EdgeGuard: EdgeGuarding, @unchecked Sendable {
    private let tap: EventTapping
    private let trust: AccessibilityTrusting
    private let displayProvider: DisplayProviding
    private let events: SystemEventSource
    private let isMouseButtonDown: @Sendable () -> Bool
    private let geometry: EdgeGuardGeometry
    private let layout = OSAllocatedUnfairLock(initialState: EdgeGuardGeometry.Layout(
        displays: [], pinned: nil, stripHeight: 0, edge: .bottom))

    private var pinned: DisplayIdentity?
    private var running = false
    public private(set) var state: GuardState = .inactive

    public init(
        tap: EventTapping,
        trust: AccessibilityTrusting,
        displayProvider: DisplayProviding,
        events: SystemEventSource,
        isMouseButtonDown: @escaping @Sendable () -> Bool,
        geometry: EdgeGuardGeometry = EdgeGuardGeometry()
    ) {
        self.tap = tap
        self.trust = trust
        self.displayProvider = displayProvider
        self.events = events
        self.isMouseButtonDown = isMouseButtonDown
        self.geometry = geometry
    }

    // MARK: - Lifecycle

    public func start() {
        guard !running else { return }
        running = true
        attemptInstall()
    }

    public func stop() {
        guard running else { return }
        running = false
        tap.remove()
        events.stop()
        layout.withLock { $0 = Self.inertLayout }
        state = .inactive
    }

    public func setPinned(_ identity: DisplayIdentity?) {
        guard identity != pinned else { return }
        pinned = identity
        if running { refreshLayout() }
    }

    public func tick() {
        guard running, state == .permissionMissing, trust.isTrusted else { return }
        attemptInstall()
    }

    // MARK: - Internals

    private static let inertLayout = EdgeGuardGeometry.Layout(displays: [], pinned: nil, stripHeight: 0, edge: .bottom)

    private func attemptInstall() {
        guard trust.isTrusted else {
            state = .permissionMissing
            return
        }
        refreshLayout()
        let installed = tap.install(
            onMove: { [weak self] location in self?.correction(for: location) },
            onDisabled: { [weak self] in self?.tap.reenable() })
        guard installed else {
            layout.withLock { $0 = Self.inertLayout }
            state = .permissionMissing
            return
        }
        state = .active
        events.start { [weak self] _ in self?.refreshLayout() }
    }

    /// Rebuilds the forbidden strips from the current displays (display change, wake, new selection).
    private func refreshLayout() {
        var pinnedID: CGDirectDisplayID?
        let displays = displayProvider.connectedDisplays()
        if let pinned {
            let matches = displays.filter { $0.identity == pinned }
            if matches.count == 1, let match = matches.first, !match.isAmbiguous { pinnedID = match.displayID }
        }
        let next = geometry.layout(
            displays: displays.map { GuardDisplay(displayID: $0.displayID, frame: $0.frame) },
            pinned: pinnedID)
        layout.withLock { $0 = next }
    }

    /// Tap thread. One lock read, one geometry query; the button check only when a correction is due.
    private func correction(for location: CGPoint) -> CGPoint? {
        guard let corrected = layout.withLock({ $0.correction(for: location) }) else { return nil }
        return isMouseButtonDown() ? nil : corrected
    }
}
