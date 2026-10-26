import AppKit
import ApplicationServices
import KolomCore

struct NativeWindow {
    let id: String
    let pid: pid_t
    let element: AXUIElement
    var title: String
    let appName: String
    let bundleID: String
    let icon: NSImage
    var frame: CGRect
    var minimized: Bool
}
struct OriginalWindow: Codable {
    let id: String
    let pid: pid_t
    let frame: CGRect
    let minimized: Bool
    var bundleID: String? = nil
    var title: String? = nil
}
final class AccessibilityBridge {
    var observers: [pid_t: AXObserver] = [:]
    var onChange: (() -> Void)?
    var writeFailures: Set<String> = []
    var lastError: String?
    private var frameGenerations: [String: UUID] = [:]
    private var probeDate = Date.distantPast
    private var probeAllowed = false
    private(set) var permissionReport = "Window access has not been checked."
    /// Apps whose window list could not be read during the last discovery pass
    /// (busy, hung or timed out). Their windows are not known to be closed.
    private(set) var unresponsivePIDs: Set<pid_t> = []
    init() {
        // Bound every AX call, including writes to window elements, so one hung
        // app cannot block Kolom's main thread for the system default of ~6 s.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
    }
    var trusted: Bool { checkPermission() }
    @discardableResult func checkPermission(force: Bool = false) -> Bool {
        if AXIsProcessTrusted() {
            probeAllowed = true
            permissionReport = "macOS confirms Kolom can control windows."
            return true
        }
        if !force && Date().timeIntervalSince(probeDate) < 1.5 { return probeAllowed }
        probeDate = Date()
        probeAllowed = false
        var lastStatus: AXError = .apiDisabled
        // Read only: verify another app exposes a controllable standard window.
        // This handles a false-negative preflight; AX still enforces every actual write.
        let candidates = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != getpid() && !$0.isHidden
        }
        for app in candidates.prefix(4) {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.15)
            var raw: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &raw)
            lastStatus = status
            if status == .apiDisabled { break }
            guard status == .success, let windows = raw as? [AXUIElement] else { continue }
            for window in windows {
                if settable(window, kAXPositionAttribute) && settable(window, kAXSizeAttribute) {
                    probeAllowed = true
                    permissionReport =
                        "Window access verified directly. macOS’s preflight check still reports unavailable."
                    return true
                }
            }
        }
        permissionReport =
            "macOS has not given this running copy window access. AX preflight: false; window probe: \(lastStatus.rawValue)."
        return false
    }
    func requestPermission() {
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!
        )
    }
    func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
    func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element, kAXPositionAttribute), let s = value(element, kAXSizeAttribute),
            CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point),
            AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size)
        else { return nil }
        return CGRect(origin: point, size: size)
    }
    func settable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var yes: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &yes) == .success && yes.boolValue
    }
    func discover(
        retaining parked: [String: NativeWindow] = [:], includeMinimized: Bool = false, adoptMinimized: Bool = false
    ) -> [NativeWindow] {
        guard trusted else { return [] }
        let cgWindows =
            (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]])
            ?? []
        var result: [NativeWindow] = []
        var unresponsive = Set<pid_t>()
        defer { unresponsivePIDs = unresponsive }
        var emitted = Set<String>()
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != getpid() {
            let pid = app.processIdentifier
            let ax = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(ax, 0.15)
            observe(pid, element: ax)
            var raw: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &raw)
            guard status == .success, let windows = raw as? [AXUIElement] else {
                if status != .noValue && status != .attributeUnsupported { unresponsive.insert(pid) }
                continue
            }
            // Some apps report the same window element more than once.
            var elements: [AXUIElement] = []
            for element in windows where !elements.contains(where: { CFEqual($0, element) }) {
                elements.append(element)
            }
            var accepted: [(element: AXUIElement, rect: CGRect, title: String, minimized: Bool)] = []
            for element in elements {
                guard (value(element, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole,
                    (value(element, "AXFullScreen") as? Bool) != true,
                    let rect = frame(element), rect.width >= 100, rect.height >= 80,
                    settable(element, kAXPositionAttribute), settable(element, kAXSizeAttribute)
                else { continue }
                let title = (value(element, kAXTitleAttribute) as? String) ?? "Untitled window"
                let minimized = (value(element, kAXMinimizedAttribute) as? Bool) == true
                accepted.append((element, rect, title, minimized))
            }
            let appRows = cgWindows.filter {
                ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
            }
            let rows = appRows.map { row in
                WindowServerRow(
                    number: (row[kCGWindowNumber as String] as? UInt32) ?? 0,
                    frame: (row[kCGWindowBounds as String] as? [String: Any]).flatMap {
                        CGRect(dictionaryRepresentation: $0 as CFDictionary)
                    }, name: row[kCGWindowName as String] as? String)
            }
            let retainedForApp = parked.values.filter { $0.pid == pid }
            let identities = assignWindowIdentities(
                pid: pid,
                candidates: accepted.map { window in
                    WindowIdentityCandidate(
                        frame: window.rect, title: window.title,
                        retainedID: retainedForApp.first { CFEqual($0.element, window.element) }?.id,
                        fallbackKey: String(CFHash(window.element)))
                }, rows: rows, reserved: Set(retainedForApp.map(\.id)))
            for (window, identity) in zip(accepted, identities) where !emitted.contains(identity.id) {
                let id = identity.id
                // Skip windows on other Spaces; retain our own deliberately parked windows.
                let onScreen =
                    identity.row.map { (appRows[$0][kCGWindowIsOnscreen as String] as? Bool) == true } ?? false
                guard
                    includeMinimized || (!app.isHidden && (onScreen || (adoptMinimized && window.minimized)))
                        || parked[id] != nil
                else { continue }
                emitted.insert(id)
                result.append(
                    NativeWindow(
                        id: id, pid: pid, element: window.element,
                        title: window.title.isEmpty ? "Untitled window" : window.title,
                        appName: app.localizedName ?? "App", bundleID: app.bundleIdentifier ?? "",
                        icon: app.icon ?? NSImage(size: NSSize(width: 32, height: 32)), frame: window.rect,
                        minimized: window.minimized))
            }
        }
        let pids = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        for pid in Array(observers.keys) where !pids.contains(pid) { removeObserver(pid) }
        return result
    }
    func observe(_ pid: pid_t, element: AXUIElement) {
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, ref in
            guard let ref else { return }
            let bridge = Unmanaged<AccessibilityBridge>.fromOpaque(ref).takeUnretainedValue()
            bridge.onChange?()
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let ref = Unmanaged.passUnretained(self).toOpaque()
        for name in [
            kAXWindowCreatedNotification, kAXUIElementDestroyedNotification, kAXFocusedWindowChangedNotification,
            kAXWindowMovedNotification, kAXWindowResizedNotification, kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
        ] {
            AXObserverAddNotification(observer, element, name as CFString, ref)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }
    func removeObserver(_ pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }
    func stopObserving() {
        frameGenerations.removeAll()
        Array(observers.keys).forEach(removeObserver)
    }
    @discardableResult func setFrame(_ window: NativeWindow, _ frame: CGRect, resize: Bool = true) -> Bool {
        let generation = UUID()
        frameGenerations[window.id] = generation
        if !resize {
            var point = frame.origin
            guard let position = AXValueCreate(.cgPoint, &point) else { return false }
            let status = AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, position)
            if status == .success {
                writeFailures.remove(window.id)
                return true
            }
            writeFailures.insert(window.id)
            lastError = "\(window.appName) declined a window move (\(status.rawValue))."
            return false
        }
        var point = frame.origin
        var size = frame.size
        guard let position = AXValueCreate(.cgPoint, &point), let dimensions = AXValueCreate(.cgSize, &size) else {
            return false
        }
        // A growing window must have room at its current origin. Otherwise
        // AppKit may constrain the resize before the final position is applied.
        let top = Double(NSScreen.screens.first?.frame.maxY ?? 0)
        let screens = NSScreen.screens.map { accessibilityRect($0.frame, primaryTop: top) }
        let currentScreen = screens.firstIndex { $0.contains(CGPoint(x: window.frame.midX, y: window.frame.midY)) }
        let targetScreen = screens.firstIndex { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }
        let growingAtEdge =
            currentScreen.map { index in
                let bounds = screens[index]
                return (size.height > window.frame.height + 4 && window.frame.minY + size.height > bounds.maxY)
                    || (size.width > window.frame.width + 4 && window.frame.minX + size.width > bounds.maxX)
            } ?? false
        if currentScreen != targetScreen || growingAtEdge {
            let moved = AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, position)
            guard moved == .success else {
                writeFailures.insert(window.id)
                lastError = "\(window.appName) declined its resize staging move (\(moved.rawValue))."
                return false
            }
            // AX position acceptance does not mean the app has processed the move.
            // Resizing in the same turn can still use the previous grid row's
            // remaining screen height. Defer sizing; newer requests cancel it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self, self.frameGenerations[window.id] == generation else { return }
                let resized = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, dimensions)
                if resized != .success {
                    self.writeFailures.insert(window.id)
                    self.lastError = "\(window.appName) declined its staged resize (\(resized.rawValue))."
                    return
                }
                self.writeFailures.remove(window.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self, self.frameGenerations[window.id] == generation else { return }
                    let corrected = AXUIElementSetAttributeValue(
                        window.element, kAXPositionAttribute as CFString, position)
                    if corrected != .success {
                        self.writeFailures.insert(window.id)
                        self.lastError = "\(window.appName) declined its final staged position (\(corrected.rawValue))."
                    }
                }
            }
            return true
        }
        let s = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, dimensions)
        // Let the app finish its native resize before correcting its origin.
        // A newer animation, resize or restoration request cancels this correction.
        if s == .success {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.frameGenerations[window.id] == generation else { return }
                let status = AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, position)
                if status != .success {
                    self.writeFailures.insert(window.id)
                    self.lastError = "\(window.appName) declined its final window position (\(status.rawValue))."
                }
            }
        }
        let ok = s == .success
        if !ok {
            writeFailures.insert(window.id)
            lastError = "\(window.appName) declined a window resize (\(s.rawValue))."
        } else {
            writeFailures.remove(window.id)
        }
        return ok
    }
    @discardableResult func minimize(_ w: NativeWindow, _ minimized: Bool) -> Bool {
        AXUIElementSetAttributeValue(
            w.element, kAXMinimizedAttribute as CFString, minimized ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }
    func isFullScreen(_ element: AXUIElement) -> Bool { (value(element, "AXFullScreen") as? Bool) == true }
    func isDestroyed(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .invalidUIElement
    }
    func focus(_ w: NativeWindow) {
        _ = minimize(w, false)
        NSRunningApplication(processIdentifier: w.pid)?.activate(options: [.activateIgnoringOtherApps])
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(w.pid), kAXFocusedWindowAttribute as CFString, w.element)
    }
    func focusedWindowID(in windows: [String: NativeWindow]) -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = value(ax, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return nil
        }
        return windows.values.first { CFEqual($0.element, focused) }?.id
    }
    func terminalWindowElements() -> [AXUIElement] {
        guard trusted else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").flatMap {
            app -> [AXUIElement] in
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.3)
            return (value(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
                (value($0, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole
            }
        }
    }
    @discardableResult func requestClose(_ element: AXUIElement) -> Bool {
        guard let button = value(element, kAXCloseButtonAttribute), CFGetTypeID(button) == AXUIElementGetTypeID() else {
            return false
        }
        return AXUIElementPerformAction(unsafeBitCast(button, to: AXUIElement.self), kAXPressAction as CFString)
            == .success
    }
    func close(_ w: NativeWindow) {
        guard let button = value(w.element, kAXCloseButtonAttribute), CFGetTypeID(button) == AXUIElementGetTypeID()
        else { return }
        AXUIElementPerformAction(unsafeBitCast(button, to: AXUIElement.self), kAXPressAction as CFString)
    }
}
