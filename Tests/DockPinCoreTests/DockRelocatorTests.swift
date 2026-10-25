import CoreGraphics
import Foundation
import Testing
@testable import DockPinCore

private final class FakeCursor: CursorControlling, @unchecked Sendable {
    var position: CGPoint
    var buttonDown = false
    var events: [String] = []
    /// Si se define, se ejecuta tras cada `sleep` simulado (para simular al usuario).
    var onTick: ((FakeCursor) -> Void)?

    init(at p: CGPoint) { position = p }

    func location() -> CGPoint? { position }
    func warp(to point: CGPoint) { position = point; events.append("warp") }
    func nudge(at point: CGPoint) { events.append("nudge") }
    func isMouseButtonDown() -> Bool { buttonDown }
    func reassociate() { events.append("reassociate") }
}

/// `Void` no es Equatable; comparación puntual para los resultados del relocator.
private func == (lhs: Result<Void, RelocationError>, rhs: Result<Void, RelocationError>) -> Bool {
    switch (lhs, rhs) {
    case (.success, .success): return true
    case let (.failure(a), .failure(b)): return a == b
    default: return false
    }
}

private struct FakeTrust: AccessibilityTrusting { var isTrusted: Bool }

private func display(_ id: UInt32, _ frame: CGRect) -> DisplayInfo {
    DisplayInfo(identity: DisplayIdentity(uuid: "00000000-0000-0000-0000-00000000000\(id)"),
                displayID: id, frame: frame)
}

private let left = display(1, CGRect(x: 0, y: 0, width: 1920, height: 1080))
private let right = display(2, CGRect(x: 1920, y: 0, width: 1920, height: 1080))

private func makeRelocator(
    _ cursor: FakeCursor, trusted: Bool = true
) -> CursorDockRelocator {
    CursorDockRelocator(
        cursor: cursor, trust: FakeTrust(isTrusted: trusted),
        sleep: { _ in cursor.onTick?(cursor) })
}

@Test func untrustedProcessFailsWithoutTouchingCursor() {
    let cursor = FakeCursor(at: CGPoint(x: 10, y: 10))
    let result = makeRelocator(cursor, trusted: false)
        .relocate(to: right, among: [left, right], cancel: CancellationToken())
    #expect(result == .failure(.accessibilityNotTrusted))
    #expect(cursor.events.isEmpty)
    #expect(RelocationError.accessibilityNotTrusted.isRetryable == false)
}

@Test func successRestoresOriginalPositionAndReassociates() {
    let origin = CGPoint(x: 300, y: 400)
    let cursor = FakeCursor(at: origin)
    let result = makeRelocator(cursor).relocate(to: right, among: [left, right], cancel: CancellationToken())
    #expect(result == .success(()))
    #expect(cursor.position == origin)
    #expect(cursor.events.first == "warp")
    #expect(cursor.events.last == "reassociate")
    #expect(cursor.events.contains("nudge"))
}

@Test func userMovementAbortsWithoutRestoring() {
    let cursor = FakeCursor(at: CGPoint(x: 300, y: 400))
    let userSpot = CGPoint(x: 2500, y: 200)
    cursor.onTick = { $0.position = userSpot }
    let result = makeRelocator(cursor).relocate(to: right, among: [left, right], cancel: CancellationToken())
    #expect(result == .failure(.userInterrupted))
    #expect(cursor.position == userSpot) // no se pelea con el usuario
    #expect(cursor.events.last == "reassociate")
}

@Test func cancellationAbortsAndReassociates() {
    let cursor = FakeCursor(at: CGPoint(x: 300, y: 400))
    let token = CancellationToken()
    cursor.onTick = { _ in token.cancel() }
    let result = makeRelocator(cursor).relocate(to: right, among: [left, right], cancel: token)
    #expect(result == .failure(.cancelled))
    #expect(cursor.position == CGPoint(x: 300, y: 400)) // programmatic cancel restores the cursor
    #expect(cursor.events.last == "reassociate")
}

@Test func pressedButtonPreventsStart() {
    let cursor = FakeCursor(at: .zero)
    cursor.buttonDown = true
    let result = makeRelocator(cursor).relocate(to: right, among: [left, right], cancel: CancellationToken())
    #expect(result == .failure(.mouseButtonPressed))
    #expect(cursor.events.isEmpty)
}

@Test func coveredBottomEdgeIsRefused() {
    let below = display(3, CGRect(x: 1920, y: 1080, width: 1920, height: 1080))
    let cursor = FakeCursor(at: .zero)
    let result = makeRelocator(cursor).relocate(to: right, among: [left, right, below], cancel: CancellationToken())
    #expect(result == .failure(.bottomEdgeNotExposed))
    #expect(cursor.events.isEmpty)
}

@Test func partiallyExposedBottomEdgePicksExposedPoint() throws {
    // Debajo solo cubre la mitad izquierda del monitor objetivo.
    let below = display(3, CGRect(x: 1920, y: 1080, width: 960, height: 1080))
    let point = try #require(CursorDockRelocator.bottomEdgePoint(of: right, among: [left, right, below]))
    #expect(point.x >= 2880)
    #expect(point.y == right.frame.maxY - 1)
}

@Test func ambiguousTargetIsRefused() {
    let twin = DisplayInfo(identity: right.identity, displayID: 2, frame: right.frame, isAmbiguous: true)
    let cursor = FakeCursor(at: .zero)
    let result = makeRelocator(cursor).relocate(to: twin, among: [left, twin], cancel: CancellationToken())
    #expect(result == .failure(.targetAmbiguous))
}

@Test func errorsMapToPolicyOutcomes() {
    #expect(RelocationError.userInterrupted.outcome == .cancelled)
    #expect(RelocationError.accessibilityNotTrusted.outcome == .failed(retryable: false))
    #expect(RelocationError.mouseButtonPressed.outcome == .failed(retryable: true))
}
