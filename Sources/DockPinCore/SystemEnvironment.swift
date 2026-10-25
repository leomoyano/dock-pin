import AppKit
import CoreGraphics
import Foundation

/// System events that make the driver re-evaluate the Dock placement.
public enum SystemTrigger: Equatable, Sendable {
    case displayConfigurationChanged
    case systemDidWake
}

public protocol SystemEventSource {
    /// Starts delivering triggers on the driver context. Replaces any previous handler.
    func start(_ handler: @escaping @Sendable (SystemTrigger) -> Void)
    /// Unregisters every callback. Idempotent.
    func stop()
}

/// How long the user has been idle (no mouse/keyboard input), if known.
public protocol UserActivityProviding {
    var secondsSinceLastInput: TimeInterval? { get }
}

public protocol TimerHandle {
    func cancel()
}

/// Time, timers and threading, so the driver can be tested with a manual clock.
///
/// The driver is single-threaded: every driver method and every handler runs on
/// the "driver context" (the main queue in the real implementation). Only the
/// blocking relocation runs in the background and hops back when it finishes.
public protocol Scheduling: MonotonicClock {
    func schedule(after delay: TimeInterval, _ action: @escaping @Sendable () -> Void) -> TimerHandle
    func runInBackground(_ work: @escaping @Sendable () -> Void)
    func runOnDriverContext(_ action: @escaping @Sendable () -> Void)
}

public protocol DockLocating {
    func locate(in displays: [DisplayInfo]) -> DockPlacement
}

extension DockLocator: DockLocating {}

// MARK: - Real implementations

public final class DispatchScheduler: Scheduling, @unchecked Sendable {
    private final class Handle: TimerHandle, @unchecked Sendable {
        let item: DispatchWorkItem
        init(_ item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }

    private let driverQueue: DispatchQueue
    private let backgroundQueue = DispatchQueue(label: "dockpin.relocation", qos: .userInitiated)

    public init(driverQueue: DispatchQueue = .main) {
        self.driverQueue = driverQueue
    }

    public var now: TimeInterval { SystemClock().now }

    public func schedule(after delay: TimeInterval, _ action: @escaping @Sendable () -> Void) -> TimerHandle {
        let item = DispatchWorkItem(block: action)
        driverQueue.asyncAfter(deadline: .now() + delay, execute: item)
        return Handle(item)
    }

    public func runInBackground(_ work: @escaping @Sendable () -> Void) {
        backgroundQueue.async(execute: work)
    }

    public func runOnDriverContext(_ action: @escaping @Sendable () -> Void) {
        driverQueue.async(execute: action)
    }
}

/// Idle time from the session event state. Read-only; needs no permission.
public struct SystemUserActivity: UserActivityProviding {
    public init() {}

    public var secondsSinceLastInput: TimeInterval? {
        // kCGAnyInputEventType (~0): any input event.
        guard let anyInput = CGEventType(rawValue: ~0) else { return nil }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}

/// Display reconfiguration + wake notifications.
///
/// Registers `CGDisplayRegisterReconfigurationCallback` and the `NSWorkspace`
/// wake notifications; `stop()` (or deinit) unregisters all of them. Handlers
/// are delivered on the main queue. The "begin configuration" half of each
/// reconfiguration is ignored; the policy debounce absorbs the rest.
public final class SystemEventObserver: SystemEventSource, @unchecked Sendable {
    private var handler: (@Sendable (SystemTrigger) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var callbackRegistered = false

    public init() {}

    deinit { stop() }

    private static let reconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, info in
        guard let info, !flags.contains(.beginConfigurationFlag) else { return }
        Unmanaged<SystemEventObserver>.fromOpaque(info).takeUnretainedValue().deliver(.displayConfigurationChanged)
    }

    public func start(_ handler: @escaping @Sendable (SystemTrigger) -> Void) {
        stop()
        self.handler = handler
        // Make sure the CoreGraphics connection exists before registering (CLI tools).
        _ = CGMainDisplayID()
        CGDisplayRegisterReconfigurationCallback(
            Self.reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        callbackRegistered = true

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.deliver(.systemDidWake)
            })
        }
    }

    public func stop() {
        if callbackRegistered {
            CGDisplayRemoveReconfigurationCallback(
                Self.reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
            callbackRegistered = false
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
        handler = nil
    }

    private func deliver(_ trigger: SystemTrigger) {
        DispatchQueue.main.async { [weak self] in self?.handler?(trigger) }
    }
}
