import CoreGraphics
import Testing
@testable import DockPinCore

private func display(_ uuid: String, id: UInt32, x: CGFloat) -> DisplayInfo {
    DisplayInfo(
        identity: DisplayIdentity(uuid: uuid),
        displayID: id,
        frame: CGRect(x: x, y: 0, width: 1920, height: 1080)
    )
}

@Test func markAmbiguousFlagsOnlyDuplicates() {
    let list = markAmbiguous([
        display("AAAAAAAA-0000-0000-0000-000000000001", id: 1, x: 0),
        display("BBBBBBBB-0000-0000-0000-000000000002", id: 2, x: 1920),
        display("BBBBBBBB-0000-0000-0000-000000000002", id: 3, x: 3840),
    ])
    #expect(list.map(\.isAmbiguous) == [false, true, true])
}

@Test func resolveByUUIDIsCaseInsensitive() throws {
    let list = [display("AAAAAAAA-0000-0000-0000-000000000001", id: 1, x: 0)]
    let selector = try #require(DisplaySelector.parse("aaaaaaaa-0000-0000-0000-000000000001"))
    #expect(try DisplaySelection.resolve(selector, in: list).get().displayID == 1)
}

@Test func resolveByUUIDRefusesAmbiguous() {
    let list = markAmbiguous([
        display("BBBBBBBB-0000-0000-0000-000000000002", id: 2, x: 0),
        display("BBBBBBBB-0000-0000-0000-000000000002", id: 3, x: 1920),
    ])
    let result = DisplaySelection.resolve(
        .uuid(DisplayIdentity(uuid: "BBBBBBBB-0000-0000-0000-000000000002")), in: list)
    #expect(result == .failure(.ambiguousIdentity(candidates: 2)))
}

@Test func resolveByUUIDNotConnected() {
    let result = DisplaySelection.resolve(
        .uuid(DisplayIdentity(uuid: "CCCCCCCC-0000-0000-0000-000000000003")), in: [])
    #expect(result == .failure(.notConnected))
}

@Test func resolveByIndexWorksEvenForAmbiguousAndChecksRange() throws {
    let list = markAmbiguous([
        display("BBBBBBBB-0000-0000-0000-000000000002", id: 2, x: 0),
        display("BBBBBBBB-0000-0000-0000-000000000002", id: 3, x: 1920),
    ])
    let second = try DisplaySelection.resolve(.index(1), in: list).get()
    #expect(second.displayID == 3 && second.isAmbiguous)
    #expect(DisplaySelection.resolve(.index(2), in: list) == .failure(.indexOutOfRange(2, available: 2)))
}

@Test func selectorParsing() {
    #expect(DisplaySelector.parse("1") == .index(1))
    #expect(DisplaySelector.parse("-1") == nil)
    #expect(DisplaySelector.parse("nope") == nil)
    #expect(DisplaySelector.parse("aaaaaaaa-0000-0000-0000-000000000001")
        == .uuid(DisplayIdentity(uuid: "AAAAAAAA-0000-0000-0000-000000000001")))
}
