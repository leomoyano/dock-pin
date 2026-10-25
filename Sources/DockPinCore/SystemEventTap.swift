@preconcurrency import ApplicationServices
@preconcurrency import CoreFoundation
import CoreGraphics
import Foundation
import os

/// The real `CGEventTap`: session level, head insert, active filter, mouse-moved only
/// (so drags, which are `*MouseDragged` events, are never touched).
///
/// It runs on its own thread and run loop, so a busy main thread cannot make the system
/// disable the tap by timeout. Each event is corrected at most once: the correction is
/// written into the event and the cursor is warped to the same point so the hidden pointer
/// position does not keep drifting into the strip. A warp posts no event, so there is no feedback loop.
///
/// NOT validated against real hardware (see docs/PHASE3-NOTES.md): that the event location
/// alone is not enough, that the warp does not leave the cursor stuck, and the effect of
/// the suppression interval tweak below.
public final class SystemEventTap: EventTapping, @unchecked Sendable {
    private final class Context: @unchecked Sendable {
        let onMove: EdgeMoveHandler
        let onDisabled: @Sendable () -> Void
        var port: CFMachPort?
        init(onMove: @escaping EdgeMoveHandler, onDisabled: @escaping @Sendable () -> Void) {
            self.onMove = onMove
            self.onDisabled = onDisabled
        }
    }

    private final class Installed: @unchecked Sendable {
        let context: Context
        let port: CFMachPort
        let source: CFRunLoopSource
        let stopRequested = OSAllocatedUnfairLock(initialState: false)
        let runLoop = OSAllocatedUnfairLock<CFRunLoop?>(initialState: nil)
        let finished = DispatchSemaphore(value: 0)
        init(context: Context, port: CFMachPort, source: CFRunLoopSource) {
            self.context = context
            self.port = port
            self.source = source
        }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let context = Unmanaged<Context>.fromOpaque(refcon).takeUnretainedValue()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            context.onDisabled()
        case .mouseMoved:
            if let corrected = context.onMove(event.location) {
                event.location = corrected
                _ = CGWarpMouseCursorPosition(corrected)
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private let lock = NSLock()
    private var installed: Installed?
    /// Separate from `lock`: `reenable()` runs on the tap thread and must never wait for `install`.
    private let livePort = OSAllocatedUnfairLock<CFMachPort?>(initialState: nil)
    private var previousSuppression: CFTimeInterval?

    public init() {}

    deinit { remove() }

    public func install(onMove: @escaping EdgeMoveHandler, onDisabled: @escaping @Sendable () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard installed == nil else { return true }

        let context = Context(onMove: onMove, onDisabled: onDisabled)
        let refcon = Unmanaged.passRetained(context).toOpaque()
        let mask = CGEventMask(1) << CGEventType.mouseMoved.rawValue
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: Self.callback, userInfo: refcon),
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        else {
            Unmanaged<Context>.fromOpaque(refcon).release()
            return false
        }
        context.port = port
        livePort.withLock { $0 = port }

        // A warp suppresses hardware events for a moment by default, which would feel like a stuck cursor.
        if let eventSource = CGEventSource(stateID: .combinedSessionState) {
            previousSuppression = eventSource.localEventsSuppressionInterval
            eventSource.localEventsSuppressionInterval = 0
        }

        let handles = Installed(context: context, port: port, source: source)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            let loop = CFRunLoopGetCurrent()
            handles.runLoop.withLock { $0 = loop }
            CFRunLoopAddSource(loop, handles.source, .commonModes)
            CGEvent.tapEnable(tap: handles.port, enable: true)
            ready.signal()
            while !handles.stopRequested.withLock({ $0 }) {
                CFRunLoopRunInMode(.defaultMode, 0.25, false)
            }
            CFRunLoopRemoveSource(loop, handles.source, .commonModes)
            handles.finished.signal()
        }
        thread.name = "dockpin.edgeguard"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        installed = handles
        return true
    }

    public func reenable() {
        if let port = livePort.withLock({ $0 }) { CGEvent.tapEnable(tap: port, enable: true) }
    }

    public func remove() {
        lock.lock()
        guard let handles = installed else { lock.unlock(); return }
        installed = nil
        livePort.withLock { $0 = nil }
        lock.unlock()

        CGEvent.tapEnable(tap: handles.port, enable: false)
        handles.stopRequested.withLock { $0 = true }
        if let loop = handles.runLoop.withLock({ $0 }) { CFRunLoopStop(loop) }
        _ = handles.finished.wait(timeout: .now() + 1)
        CFMachPortInvalidate(handles.port)
        Unmanaged.passUnretained(handles.context).release()
        if let previous = previousSuppression, let eventSource = CGEventSource(stateID: .combinedSessionState) {
            eventSource.localEventsSuppressionInterval = previous
        }
        previousSuppression = nil
    }
}
