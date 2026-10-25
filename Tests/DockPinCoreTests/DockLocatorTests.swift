import CoreGraphics
import Testing
@testable import DockPinCore

private let left = DisplayInfo(
    identity: DisplayIdentity(uuid: "AAAAAAAA-0000-0000-0000-000000000001"),
    displayID: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
private let right = DisplayInfo(
    identity: DisplayIdentity(uuid: "BBBBBBBB-0000-0000-0000-000000000002"),
    displayID: 2, frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080))

private func dock(_ rect: CGRect, layer: Int = DockLocator.dockWindowLevel, owner: String = "Dock") -> WindowSnapshot {
    WindowSnapshot(ownerName: owner, layer: layer, bounds: rect)
}

private let bottomOfRight = CGRect(x: 2400, y: 1000, width: 960, height: 80)

@Test func dockWindowOnRightDisplay() {
    let result = DockLocator.locate(windows: [dock(bottomOfRight)], in: [left, right])
    #expect(result == .onDisplay(right.identity))
}

@Test func missingDockWindowIsUnknownNotWrongMonitor() {
    #expect(DockLocator.locate(windows: [], in: [left, right]) == .unknown(.noDockWindow))
}

@Test func ignoresOtherOwnersAndOtherLayers() {
    let windows = [
        dock(bottomOfRight, owner: "Finder"),
        dock(bottomOfRight, layer: 0),
    ]
    #expect(DockLocator.locate(windows: windows, in: [left, right]) == .unknown(.noDockWindow))
}

@Test func offscreenMidpointIsUnknown() {
    let offscreen = CGRect(x: 9000, y: 9000, width: 100, height: 80)
    #expect(DockLocator.locate(windows: [dock(offscreen)], in: [left, right]) == .unknown(.dockOutsideAllDisplays))
}

@Test func conflictingWindowsAreUnknown() {
    let windows = [dock(bottomOfRight), dock(CGRect(x: 400, y: 1000, width: 960, height: 80))]
    #expect(DockLocator.locate(windows: windows, in: [left, right]) == .unknown(.conflictingDockWindows))
}

@Test func emptyDisplaysAndEmptyBoundsAreUnknown() {
    #expect(DockLocator.locate(windows: [dock(bottomOfRight)], in: []) == .unknown(.noDisplays))
    #expect(DockLocator.locate(windows: [dock(.zero)], in: [left]) == .unknown(.noDockWindow))
}

@Test func ambiguousDisplayIsUnknown() {
    let twinA = DisplayInfo(identity: left.identity, displayID: 1, frame: left.frame, isAmbiguous: true)
    let result = DockLocator.locate(windows: [dock(CGRect(x: 400, y: 1000, width: 960, height: 80))], in: [twinA])
    #expect(result == .unknown(.ambiguousDisplay))
}

private struct FakeWindows: WindowListProviding {
    var list: [WindowSnapshot]?
    func windows() -> [WindowSnapshot]? { list }
}

@Test func unavailableWindowListIsUnknown() {
    let locator = DockLocator(windowProvider: FakeWindows(list: nil))
    #expect(locator.locate(in: [left]) == .unknown(.windowListUnavailable))
}
