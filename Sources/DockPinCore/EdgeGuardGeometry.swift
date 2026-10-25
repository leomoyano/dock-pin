import CoreGraphics

/// Which screen edge the Dock sits on. Only `.bottom` is implemented; the geometry
/// is parameterised on it so `.left` / `.right` can be added without changing callers.
public enum GuardedEdge: Equatable, Sendable {
    case bottom
}

/// One display as the guard sees it: global Quartz coordinates (top-left origin, Y down).
public struct GuardDisplay: Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    public let frame: CGRect

    public init(displayID: CGDirectDisplayID, frame: CGRect) {
        self.displayID = displayID
        self.frame = frame
    }
}

/// Pure decision logic of the edge guard (no AppKit, no CoreGraphics calls).
///
/// The Dock migrates to another display when the pointer is pushed against that
/// display's bottom edge. The guard keeps the pointer out of a thin "forbidden
/// strip" along the bottom of every display except the pinned one.
///
/// A `Layout` is built once per display configuration, so the per-event query
/// (`correction(for:)`) allocates nothing.
///
/// Rules:
/// - The strip is the bottom `stripHeight` px of each non-pinned display (capped at
///   half the display height so a tiny display is never fully forbidden).
/// - The pinned display is never clamped.
/// - A point inside any other display's frame is never clamped (overlapping or mirrored layouts).
/// - Where another display is directly below (its frame contains the pixel just past
///   the bottom edge), the bottom edge is not a real edge: the pointer must be able
///   to cross into that display, so that part of the strip is not guarded.
/// - If the pinned display is not connected, nothing is guarded: the pointer is never locked.
public struct EdgeGuardGeometry: Equatable, Sendable {
    public static let defaultStripHeight: CGFloat = 3

    public var stripHeight: CGFloat
    public var edge: GuardedEdge

    public init(stripHeight: CGFloat = EdgeGuardGeometry.defaultStripHeight, edge: GuardedEdge = .bottom) {
        self.stripHeight = stripHeight
        self.edge = edge
    }

    public func layout(displays: [GuardDisplay], pinned: CGDirectDisplayID?) -> Layout {
        Layout(displays: displays, pinned: pinned, stripHeight: stripHeight, edge: edge)
    }

    /// Convenience for one-off queries and tests; the guard itself caches a `Layout`.
    public func correction(
        for point: CGPoint, displays: [GuardDisplay], pinned: CGDirectDisplayID?
    ) -> CGPoint? {
        layout(displays: displays, pinned: pinned).correction(for: point)
    }

    public struct Layout: Equatable, Sendable {
        private struct Guarded: Equatable, Sendable {
            let index: Int
            let frame: CGRect
            let stripTop: CGFloat
            let safeY: CGFloat
        }

        private let frames: [CGRect]
        private let guarded: [Guarded]

        /// `true` when no display is guarded (pinned display missing, or a single display).
        public var isInert: Bool { guarded.isEmpty }

        public init(displays: [GuardDisplay], pinned: CGDirectDisplayID?, stripHeight: CGFloat, edge: GuardedEdge) {
            frames = displays.map(\.frame)
            guard let pinned, stripHeight > 0, displays.contains(where: { $0.displayID == pinned }) else {
                guarded = []
                return
            }
            guarded = displays.enumerated().compactMap { index, display in
                guard display.displayID != pinned, !display.frame.isEmpty else { return nil }
                let frame = display.frame
                let strip = min(stripHeight, frame.height / 2)
                let stripTop = frame.maxY - strip
                return Guarded(index: index, frame: frame, stripTop: stripTop, safeY: stripTop - 1)
            }
        }

        /// The corrected location when `point` is inside a forbidden strip (same x, y just
        /// above the strip); `nil` when the pointer may stay where it is.
        public func correction(for point: CGPoint) -> CGPoint? {
            for entry in guarded {
                let frame = entry.frame
                guard point.x >= frame.minX, point.x < frame.maxX,
                      point.y >= entry.stripTop, point.y < frame.maxY
                else { continue }
                if isCovered(point, exceptIndex: entry.index) { return nil }
                // Another display directly below: this part of the edge is not a real edge.
                if isCovered(CGPoint(x: point.x, y: frame.maxY), exceptIndex: entry.index) { return nil }
                return CGPoint(x: point.x, y: entry.safeY)
            }
            return nil
        }

        private func isCovered(_ point: CGPoint, exceptIndex own: Int) -> Bool {
            for (index, frame) in frames.enumerated() where index != own && contains(frame, point) { return true }
            return false
        }

        private func contains(_ frame: CGRect, _ point: CGPoint) -> Bool {
            point.x >= frame.minX && point.x < frame.maxX && point.y >= frame.minY && point.y < frame.maxY
        }
    }
}
