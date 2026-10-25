import Testing
@testable import DockPinCore

@Test func versionIsSet() {
    #expect(!DockPinCore.version.isEmpty)
}
