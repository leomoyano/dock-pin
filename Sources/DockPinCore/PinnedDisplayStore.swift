import Foundation

/// Raw persistence of the pinned display UUID (a fake is used in tests).
public protocol PinnedDisplayPersisting {
    func loadUUID() -> String?
    func saveUUID(_ uuid: String)
    func clearUUID()
}

/// `UserDefaults`-backed persistence. The CLI and the future app share the same
/// suite so a selection made in one is visible in the other.
public struct UserDefaultsPinnedDisplayPersistence: PinnedDisplayPersisting {
    public static let defaultSuiteName = "com.dockpin.shared"
    private static let key = "pinnedDisplayUUID"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public init(suiteName: String = Self.defaultSuiteName) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    public func loadUUID() -> String? { defaults.string(forKey: Self.key) }
    public func saveUUID(_ uuid: String) { defaults.set(uuid, forKey: Self.key) }
    public func clearUUID() { defaults.removeObject(forKey: Self.key) }
}

public enum PinnedDisplayError: Error, Equatable, Sendable {
    /// The identity is shared by several connected displays; it cannot be persisted.
    case ambiguousIdentity
    case resolution(DisplayResolutionError)
}

extension PinnedDisplayError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .ambiguousIdentity:
            return "This display shares its UUID with another connected display (identical monitors), " +
                "so it has no stable identity and cannot be saved as the pinned display."
        case let .resolution(error):
            return "\(error)"
        }
    }
}

/// The pinned display selection, persisted across launches.
///
/// Rules:
/// - An ambiguous identity is never persisted.
/// - A saved selection is kept even when that display is not connected: the
///   driver waits for it to come back instead of clearing it.
/// - A corrupted stored value reads as "no selection" rather than crashing.
public struct PinnedDisplayStore {
    private let persistence: PinnedDisplayPersisting

    public init(persistence: PinnedDisplayPersisting = UserDefaultsPinnedDisplayPersistence()) {
        self.persistence = persistence
    }

    public var selected: DisplayIdentity? {
        guard let raw = persistence.loadUUID(), UUID(uuidString: raw) != nil else { return nil }
        return DisplayIdentity(uuid: raw)
    }

    /// Resolves `selector` against the connected displays and saves the result.
    /// A UUID that is not connected right now is saved as-is (the display may be
    /// unplugged); an index must point at a connected display.
    @discardableResult
    public func select(
        _ selector: DisplaySelector,
        among displays: [DisplayInfo]
    ) -> Result<DisplayIdentity, PinnedDisplayError> {
        switch DisplaySelection.resolve(selector, in: displays) {
        case let .success(display):
            return select(display)
        case let .failure(error):
            if case let .uuid(identity) = selector, error == .notConnected {
                persistence.saveUUID(identity.uuid)
                return .success(identity)
            }
            if case .ambiguousIdentity = error { return .failure(.ambiguousIdentity) }
            return .failure(.resolution(error))
        }
    }

    @discardableResult
    public func select(_ display: DisplayInfo) -> Result<DisplayIdentity, PinnedDisplayError> {
        guard !display.isAmbiguous else { return .failure(.ambiguousIdentity) }
        persistence.saveUUID(display.identity.uuid)
        return .success(display.identity)
    }

    public func clear() {
        persistence.clearUUID()
    }
}
