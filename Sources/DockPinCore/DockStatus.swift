import Foundation

public enum GiveUpReason: Equatable, Sendable {
    /// The retry budget was spent without the Dock reaching the selected display.
    case attemptsExhausted(attempts: Int)
    /// A non-retryable relocation error (other than missing Accessibility).
    case relocationFailed(RelocationError)
}

/// What the Dock pinning engine is doing, for the future UI to observe.
///
/// Never reports success unless the Dock was actually seen on the selected
/// display: `.checking` and `.unknownPlacement` are explicitly not success.
public enum DockStatus: Equatable, Sendable {
    /// The driver is not running.
    case stopped
    /// Running, but no display has been selected yet.
    case noSelection
    /// Waiting for the display state to settle or for an observation. Nothing is claimed.
    case checking
    /// The Dock was observed on the selected display.
    case pinned(DisplayIdentity)
    /// A relocation attempt is in progress (`attempt` is 1-based).
    case relocating(attempt: Int)
    /// The Dock is not (yet) confirmed on the selected display; it is re-checked after the cooldown.
    case awaitingRecheck(afterAttempt: Int)
    /// The selected display is not connected; the selection is kept and nothing is moved.
    case waitingForDisplay(DisplayIdentity)
    case accessibilityPermissionMissing
    /// Retries stopped until a display/wake event or a new selection.
    case gaveUp(GiveUpReason)
    /// The Dock could not be located (`nil` reason: the observation timed out).
    /// This is not "wrong display" and not success.
    case unknownPlacement(UnknownReason?)

    /// `true` only when the Dock was observed on the selected display.
    public var isPinned: Bool {
        if case .pinned = self { return true }
        return false
    }
}

extension DockStatus: CustomStringConvertible {
    public var description: String {
        switch self {
        case .stopped:
            return "Stopped."
        case .noSelection:
            return "No display selected. Choose the display to pin the Dock to."
        case .checking:
            return "Checking where the Dock is (waiting for the display state to settle)…"
        case let .pinned(identity):
            return "Dock is on the selected display (\(identity.uuid))."
        case let .relocating(attempt):
            return "Moving the Dock to the selected display (attempt \(attempt))…"
        case let .awaitingRecheck(last):
            return "Dock not confirmed on the selected display yet; re-checking after the cooldown " +
                "(attempts so far: \(last))."
        case let .waitingForDisplay(identity):
            return "Selected display \(identity.uuid) is not connected; waiting for it to return."
        case .accessibilityPermissionMissing:
            return "Accessibility permission is missing. Grant it in System Settings > " +
                "Privacy & Security > Accessibility; it is re-checked automatically."
        case let .gaveUp(reason):
            switch reason {
            case let .attemptsExhausted(n):
                return "Gave up after \(n) attempts; will retry after the next display change, wake or new selection."
            case let .relocationFailed(error):
                return "Gave up: \(error.guidance)"
            }
        case let .unknownPlacement(reason):
            let detail = reason.map { "\($0)" } ?? "observation timed out"
            return "Dock location unknown (\(detail)); nothing is being moved."
        }
    }
}
