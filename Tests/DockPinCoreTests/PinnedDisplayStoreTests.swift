import CoreGraphics
import Foundation
import Testing
@testable import DockPinCore

final class InMemoryPersistence: PinnedDisplayPersisting, @unchecked Sendable {
    var value: String?
    func loadUUID() -> String? { value }
    func saveUUID(_ uuid: String) { value = uuid }
    func clearUUID() { value = nil }
}

private func display(_ n: Int, ambiguous: Bool = false) -> DisplayInfo {
    DisplayInfo(
        identity: DisplayIdentity(uuid: "00000000-0000-0000-0000-00000000000\(n)"),
        displayID: UInt32(n),
        frame: CGRect(x: 1920 * (n - 1), y: 0, width: 1920, height: 1080),
        isAmbiguous: ambiguous)
}

@Test func selectionSurvivesANewStoreInstance() {
    let persistence = InMemoryPersistence()
    let first = PinnedDisplayStore(persistence: persistence)
    #expect(first.selected == nil)
    _ = first.select(.index(1), among: [display(1), display(2)])
    let restarted = PinnedDisplayStore(persistence: persistence)
    #expect(restarted.selected == display(2).identity)
}

@Test func ambiguousDisplayIsNeverPersisted() {
    let persistence = InMemoryPersistence()
    let store = PinnedDisplayStore(persistence: persistence)
    let twin = display(1, ambiguous: true)
    #expect(store.select(twin) == .failure(.ambiguousIdentity))
    #expect(store.select(.index(0), among: [twin, display(2)]) == .failure(.ambiguousIdentity))
    #expect(persistence.value == nil)
}

@Test func ambiguousUUIDSelectorIsRejectedAndNotPersisted() {
    let persistence = InMemoryPersistence()
    let store = PinnedDisplayStore(persistence: persistence)
    let a = display(1, ambiguous: true)
    let b = DisplayInfo(identity: a.identity, displayID: 9, frame: CGRect(x: 5000, y: 0, width: 10, height: 10),
                        isAmbiguous: true)
    #expect(store.select(.uuid(a.identity), among: [a, b]) == .failure(.ambiguousIdentity))
    #expect(persistence.value == nil)
}

@Test func disconnectedUUIDIsKeptSoTheDriverCanWait() {
    let store = PinnedDisplayStore(persistence: InMemoryPersistence())
    let absent = DisplayIdentity(uuid: "AAAAAAAA-0000-0000-0000-000000000001")
    #expect(store.select(.uuid(absent), among: [display(1)]) == .success(absent))
    #expect(store.selected == absent)
}

@Test func outOfRangeIndexIsRejectedAndKeepsPreviousSelection() {
    let store = PinnedDisplayStore(persistence: InMemoryPersistence())
    _ = store.select(.index(0), among: [display(1)])
    let result = store.select(.index(5), among: [display(1)])
    #expect(result == .failure(.resolution(.indexOutOfRange(5, available: 1))))
    #expect(store.selected == display(1).identity)
}

@Test func corruptedStoredValueReadsAsNoSelection() {
    let persistence = InMemoryPersistence()
    persistence.value = "not-a-uuid"
    #expect(PinnedDisplayStore(persistence: persistence).selected == nil)
}

@Test func clearRemovesSelection() {
    let store = PinnedDisplayStore(persistence: InMemoryPersistence())
    _ = store.select(display(1))
    store.clear()
    #expect(store.selected == nil)
}

@Test func userDefaultsPersistenceRoundTrips() throws {
    let suite = "dockpin.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let persistence = UserDefaultsPinnedDisplayPersistence(defaults: defaults)
    persistence.saveUUID("00000000-0000-0000-0000-000000000001")
    #expect(persistence.loadUUID() == "00000000-0000-0000-0000-000000000001")
    persistence.clearUUID()
    #expect(persistence.loadUUID() == nil)
}
