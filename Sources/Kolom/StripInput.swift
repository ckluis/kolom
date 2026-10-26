import AppKit
import CoreGraphics

/// Observe only horizontal/modified scrolling; ordinary vertical scrolling stays
/// with the application. No keystrokes or text are captured or stored.
final class StripInput {
    var tap: CFMachPort?
    var source: CFRunLoopSource?
    var consume: ((CGPoint, Double, Double, CGEventFlags) -> Bool)?
    var onUnavailable: (() -> Void)?
    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, ref in
                guard let ref else { return Unmanaged.passUnretained(event) }
                let input = Unmanaged<StripInput>.fromOpaque(ref).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = input.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
                let dx =
                    event.getDoubleValueField(
                        continuous ? .scrollWheelEventPointDeltaAxis2 : .scrollWheelEventDeltaAxis2)
                    * (continuous ? 1 : 20)
                let dy =
                    event.getDoubleValueField(
                        continuous ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventDeltaAxis1)
                    * (continuous ? 1 : 20)
                if input.consume?(event.location, dx, dy, event.flags) == true { return nil }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else {
            onUnavailable?()
            return
        }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }
    deinit { stop() }
}

final class ResizeHandle: NSView {
    var began: (() -> Void)?
    var changed: ((Double) -> Void)?
    var ended: (() -> Void)?
    var vertical = false
    var sample: ((String, Double, Double) -> Void)?
    private(set) var isDragging = false
    private var origin = NSPoint.zero
    var value: (() -> Double)?
    private var startingValue: Double = 0
    private var lastDelta: Double = 0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: vertical ? .resizeUpDown : .resizeLeftRight) }
    private func screenPoint(_ event: NSEvent) -> NSPoint {
        event.window?.convertPoint(toScreen: event.locationInWindow) ?? origin
    }
    override func mouseDown(with event: NSEvent) {
        origin = screenPoint(event)
        startingValue = value?() ?? 0
        lastDelta = 0
        isDragging = true
        began?()
        sample?("began", startingValue, 0)
    }
    private func update(_ event: NSEvent, phase: String) {
        guard isDragging else { return }
        let p = screenPoint(event)
        let delta = vertical ? origin.y - p.y : p.x - origin.x
        lastDelta = delta
        changed?(startingValue + delta)
        sample?(phase, startingValue, delta)
    }
    override func mouseDragged(with event: NSEvent) { update(event, phase: "dragged") }
    override func mouseUp(with event: NSEvent) {
        // The handle itself has moved with the edge. Mouse-up commits the last
        // drag value rather than recalculating movement in its new coordinates.
        guard isDragging else { return }
        sample?("ended", startingValue, lastDelta)
        isDragging = false
        ended?()
    }
    override func accessibilityValue() -> Any? { value?() }
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(setAccessibilityValue(_:)) { return true }
        return super.isAccessibilitySelectorAllowed(selector)
    }
    override func setAccessibilityValue(_ value: Any?) {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return }
        began?()
        changed?(number.doubleValue)
        ended?()
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.37, green: 0.50, blue: 0.29, alpha: 0.60).setFill()
        let rect =
            vertical
            ? NSRect(x: bounds.midX - 24, y: bounds.midY - 1, width: 48, height: 2)
            : NSRect(x: bounds.midX - 1, y: bounds.midY - 24, width: 2, height: 48)
        NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
    }
}
