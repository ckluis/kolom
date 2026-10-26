import AppKit
import KolomCore

/// Keeps pointer crossings on the user's desk while the display staircase is
/// applied. Runs its own event tap on its own thread, so Accessibility work on
/// the main thread can never delay a crossing. Maps are swapped atomically.
final class PointerRouter {
    private let lock = NSLock()
    private var technical: [UInt32: CGRect] = [:]
    private var desk: [UInt32: CGRect] = [:]
    private var tap: CFMachPort?
    private var thread: Thread?
    private(set) var warps = 0
    // A warp otherwise freezes physical pointer motion for 0.25 s after each crossing.
    private let source: CGEventSource? = {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()

    /// Equal maps (including empty ones) turn routing off.
    func update(technical: [UInt32: CGRect], desk: [UInt32: CGRect]) {
        lock.lock()
        self.technical = technical
        self.desk = desk
        lock.unlock()
        if technical != desk { start() }
    }
    var warpCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return warps
    }

    private func start() {
        guard thread == nil else {
            if let tap, !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let motion: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask = motion.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                callback: { _, type, event, info in
                    guard let info else { return Unmanaged.passUnretained(event) }
                    let router = Unmanaged<PointerRouter>.fromOpaque(info).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if let tap = router.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    } else if router.route(event) {
                        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: 0)
                    }
                    return Unmanaged.passUnretained(event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }
        self.tap = tap
        let thread = Thread {
            guard let loopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), loopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "Kolom pointer router"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    private func route(_ event: CGEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard technical != desk,
            let point = displayPointerDestination(
                x: event.location.x, y: event.location.y,
                deltaX: event.getDoubleValueField(.mouseEventDeltaX),
                deltaY: event.getDoubleValueField(.mouseEventDeltaY), technical: technical, desk: desk)
        else { return false }
        // Keep a map change ordered after any in-flight warp.
        guard withExtendedLifetime(source, { CGWarpMouseCursorPosition(point) }) == .success else { return false }
        CGAssociateMouseAndMouseCursorPosition(1)
        event.location = point
        warps += 1
        return true
    }
}
