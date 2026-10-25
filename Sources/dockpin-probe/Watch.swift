import DockPinCore
import Foundation

/// Keeps the signal sources alive for the lifetime of the process.
nonisolated(unsafe) private var signalSources: [DispatchSourceSignal] = []

private func die(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

private func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: Date())
}

/// Read-only: prints the saved selection and where the Dock is right now.
func runStatus() {
    let displays = SystemDisplayProvider().connectedDisplays()
    let store = PinnedDisplayStore()
    if let selected = store.selected {
        let matches = displays.enumerated().filter { $0.element.identity == selected }
        switch matches.count {
        case 0: print("Saved selection: \(selected.uuid) (not connected right now; kept, waiting for it)")
        case 1: print("Saved selection: \(selected.uuid) (connected, index [\(matches[0].offset)])")
        default: print("Saved selection: \(selected.uuid) (AMBIGUOUS: \(matches.count) connected displays share this UUID)")
        }
    } else {
        print("Saved selection: none (pick one with `dockpin-probe watch --to <uuid|index>`)")
    }
    switch DockLocator().locate(in: displays) {
    case let .onDisplay(identity):
        let index = displays.firstIndex { $0.identity == identity }.map { "[\($0)] " } ?? ""
        let verdict = store.selected.map { $0 == identity ? "on the selected display" : "NOT on the selected display" }
        print("Dock: display \(index)\(identity.uuid)" + (verdict.map { " (\($0))" } ?? ""))
    case let .unknown(reason):
        print("Dock: location UNKNOWN (\(reason)); this does not mean it is misplaced.")
    }
    print("Accessibility: \(SystemAccessibilityTrust().isTrusted ? "granted" : "NOT granted (required to move the Dock)")")
}

/// Runs the enforcement driver in the foreground until SIGINT/SIGTERM. MOVES THE POINTER.
func runWatch(selector: DisplaySelector?, guardEnabled: Bool) -> Never {
    let provider = SystemDisplayProvider()
    let store = PinnedDisplayStore()

    if let selector {
        switch store.select(selector, among: provider.connectedDisplays()) {
        case let .success(identity): print("Selection saved: \(identity.uuid)")
        case let .failure(error): die("Cannot pin that display: \(error)", code: 2)
        }
    }
    guard let selected = store.selected else {
        die("No display selected. Use `dockpin-probe watch --to <uuid|index>` (see `displays`).", code: 2)
    }

    setlinebuf(stdout)
    print("Watching: keeping the Dock on \(selected.uuid). Press Ctrl-C to stop.")
    print("Note: this MOVES THE POINTER when the Dock is on another display. Quit other Dock controllers first.")

    if guardEnabled {
        print("Edge guard: the pointer is held back from the bottom edge of every other display (needs Accessibility).")
        print("Dragging (button held) is not affected. Do not run DockLock Lite or similar tools at the same time.")
    }

    let cursor = SystemCursor()
    let edgeGuard: EdgeGuard? = guardEnabled
        ? EdgeGuard(
            tap: SystemEventTap(),
            trust: SystemAccessibilityTrust(),
            displayProvider: provider,
            events: SystemEventObserver(),
            isMouseButtonDown: { cursor.isMouseButtonDown() })
        : nil
    let driver = EnforcementDriver(
        store: store,
        displayProvider: provider,
        locator: DockLocator(),
        relocator: CursorDockRelocator(cursor: cursor),
        trust: SystemAccessibilityTrust(),
        cursor: cursor,
        events: SystemEventObserver(),
        activity: SystemUserActivity(),
        scheduler: DispatchScheduler(),
        edgeGuard: edgeGuard,
        onGuardState: { print("[\(timestamp())] \($0)") },
        onStatus: { print("[\(timestamp())] \($0)") })

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    signalSources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            driver.stop()
            print("Stopped. Timers and callbacks released; pointer re-associated.")
            exit(0)
        }
        source.resume()
        return source
    }
    driver.start()
    dispatchMain()
}
