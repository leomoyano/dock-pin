import CoreGraphics
import Testing
@testable import DockPinCore

private let main = GuardDisplay(displayID: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
private let right = GuardDisplay(displayID: 2, frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440))
private let geometry = EdgeGuardGeometry()

private func fix(_ x: CGFloat, _ y: CGFloat, _ displays: [GuardDisplay], pinned: CGDirectDisplayID?,
                 geometry: EdgeGuardGeometry = geometry) -> CGPoint? {
    geometry.correction(for: CGPoint(x: x, y: y), displays: displays, pinned: pinned)
}

@Test func lastPixelRowOfNonPinnedDisplayIsClampedAboveTheStrip() {
    #expect(fix(500, 1079, [main, right], pinned: 2) == CGPoint(x: 500, y: 1076))
    #expect(fix(500, 1079.9, [main, right], pinned: 2) == CGPoint(x: 500, y: 1076))
}

@Test func stripBoundariesAreExact() {
    // Strip of 3 px on a 1080-high display: rows 1077..1079.
    #expect(fix(500, 1077, [main, right], pinned: 2) == CGPoint(x: 500, y: 1076))
    #expect(fix(500, 1076.9, [main, right], pinned: 2) == nil)
    #expect(fix(500, 1076, [main, right], pinned: 2) == nil)
    #expect(fix(500, 500, [main, right], pinned: 2) == nil)
}

@Test func correctedPointIsNeverInsideTheStripAndKeepsX() throws {
    let corrected = try #require(fix(123.5, 1079, [main, right], pinned: 2))
    #expect(corrected.x == 123.5)
    #expect(fix(corrected.x, corrected.y, [main, right], pinned: 2) == nil)
}

@Test func pinnedDisplayIsNeverClamped() {
    #expect(fix(3000, 1439, [main, right], pinned: 2) == nil)
    #expect(fix(3000, 1438, [main, right], pinned: 2) == nil)
    // Same point is clamped when the other display is the pinned one.
    #expect(fix(3000, 1439, [main, right], pinned: 1) == CGPoint(x: 3000, y: 1436))
}

@Test func eachDisplayUsesItsOwnBottomEdgeWhenSizesDiffer() {
    // Main is 1080 high, right is 1440 high. Row 1100 is inside right (not its strip).
    #expect(fix(3000, 1100, [main, right], pinned: 1) == nil)
    #expect(fix(3000, 1437, [main, right], pinned: 1) == CGPoint(x: 3000, y: 1436))
    #expect(fix(10, 1078, [main, right], pinned: 2) == CGPoint(x: 10, y: 1076))
}

@Test func negativeOriginsAreSupported() {
    let left = GuardDisplay(displayID: 3, frame: CGRect(x: -1440, y: -200, width: 1440, height: 900))
    // Left spans y -200..700; its strip is 697..700.
    #expect(fix(-700, 699, [left, main], pinned: 1) == CGPoint(x: -700, y: 696))
    #expect(fix(-700, 696, [left, main], pinned: 1) == nil)
    #expect(fix(-700, 699, [left, main], pinned: 3) == nil)
}

@Test func displayAboveAnotherLeavesTheSharedEdgeOpen() {
    // `top` is stacked directly above `main`; crossing top's bottom edge is a real transition.
    let top = GuardDisplay(displayID: 4, frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080))
    #expect(fix(500, -1, [top, main], pinned: 1) == nil)
    // The bottom display's own bottom edge is a real edge and stays guarded.
    #expect(fix(500, 1079, [top, main], pinned: 4) == CGPoint(x: 500, y: 1076))
}

@Test func offsetStackOnlyOpensTheCoveredPartOfTheEdge() {
    // The display below covers x 960..2880 only. Top spans x 0..1920.
    let top = GuardDisplay(displayID: 5, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    let below = GuardDisplay(displayID: 6, frame: CGRect(x: 960, y: 1080, width: 1920, height: 1080))
    #expect(fix(100, 1079, [top, below], pinned: 6) == CGPoint(x: 100, y: 1076)) // free part of the edge
    #expect(fix(1500, 1079, [top, below], pinned: 6) == nil)                     // open: leads into `below`
}

@Test func pointInsideAnotherDisplaysFrameIsNotClamped() {
    // Overlapping frames (e.g. mirroring): the pinned frame covers the strip of the other.
    let a = GuardDisplay(displayID: 7, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    let b = GuardDisplay(displayID: 8, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    #expect(fix(500, 1079, [a, b], pinned: 8) == nil)
}

@Test func missingPinnedDisplayGuardsNothing() {
    #expect(fix(500, 1079, [main, right], pinned: 99) == nil)
    #expect(fix(500, 1079, [main, right], pinned: nil) == nil)
    #expect(geometry.layout(displays: [main, right], pinned: 99).isInert)
}

@Test func emptyAndSingleDisplayLayoutsAreInert() {
    #expect(fix(10, 10, [], pinned: 1) == nil)
    #expect(fix(500, 1079, [main], pinned: 1) == nil)
    #expect(geometry.layout(displays: [main], pinned: 1).isInert)
}

@Test func stripHeightIsConfigurable() {
    let thick = EdgeGuardGeometry(stripHeight: 10)
    #expect(fix(500, 1070, [main, right], pinned: 2, geometry: thick) == CGPoint(x: 500, y: 1069))
    #expect(fix(500, 1069, [main, right], pinned: 2, geometry: thick) == nil)
    let off = EdgeGuardGeometry(stripHeight: 0)
    #expect(fix(500, 1079, [main, right], pinned: 2, geometry: off) == nil)
}

@Test func stripNeverExceedsHalfOfASmallDisplay() {
    let tiny = GuardDisplay(displayID: 9, frame: CGRect(x: 5000, y: 0, width: 100, height: 4))
    // Strip capped at 2 px: rows 2..3. Row 1 stays free.
    #expect(fix(5050, 3, [main, tiny], pinned: 1) == CGPoint(x: 5050, y: 1))
    #expect(fix(5050, 1, [main, tiny], pinned: 1) == nil)
}

@Test func pointsOutsideEveryDisplayAreLeftAlone() {
    #expect(fix(-50, 1079, [main, right], pinned: 2) == nil)
    #expect(fix(500, 2000, [main, right], pinned: 2) == nil)
}

@Test func horizontalFrameEdgesAreHalfOpen() {
    #expect(fix(0, 1079, [main, right], pinned: 2) == CGPoint(x: 0, y: 1076))
    #expect(fix(1919.5, 1079, [main, right], pinned: 2) == CGPoint(x: 1919.5, y: 1076))
    // x == 1920 belongs to the pinned display on the right.
    #expect(fix(1920, 1079, [main, right], pinned: 2) == nil)
}
