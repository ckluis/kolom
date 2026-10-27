import AppKit
import ApplicationServices
import SwiftUI
import KolomCore

struct DisplayModel: Identifiable {
    let id: String
    let name: String
    let frame: CGRect  // AX coordinates, including menu bar and native Dock exclusions.
    let screen: NSScreen?
    var fullFrame: CGRect {
        screen.map {
            accessibilityRect($0.frame, primaryTop: Double(NSScreen.screens.first?.frame.maxY ?? 0))
        } ?? frame
    }
}
final class KolomController: ObservableObject {
    @Published var workspaces: [String: Workspace] = [:]
    @Published var windows: [String: NativeWindow] = [:]
    @Published var displays: [DisplayModel] = []
    @Published var activeDisplay = ""
    @Published var enabled = false
    @Published var demo = true
    @Published var commandDisplay: String?
    @Published var performanceDisplay: String?
    @Published var guideDisplay: String?
    let performanceWidth: Double = 640
    @Published var status = "Demo mode · your desktop is unchanged"
    @Published var permissionGranted = false
    @Published var permissionDetails = ""
    @Published var recoveryAvailable = false
    @Published var dropDisplay: String?
    var chooseApp: ((String) -> Void)?
    var launchTargets: [pid_t: (display: String, expires: Date)] = [:]
    var lastFocusedWindow: String?
    var commandWindow: String? {
        bridge.focusedWindowID(in: windows) ?? lastFocusedWindow.flatMap { windows[$0] == nil ? nil : $0 }
            ?? workspaces[activeDisplay]?.focus
    }
    var displayIntentUntil = Date.distantPast
    @Published var draggedID: String?
    @Published var dropTarget: String?
    @Published var dropPlacement: Placement = .below
    @Published var excludedBundles: Set<String> = []
    var showPalette: (() -> Void)?
    var layoutChanged: (() -> Void)?
    let bridge = AccessibilityBridge()
    var originals: [String: OriginalWindow] = [:]
    var parked: Set<String> = []
    var offStrip: Set<String> = []
    var expected: [String: CGRect] = [:]
    var suspended: [String: NativeWindow] = [:]
    var animation: Timer?
    var displayChangeTask: DispatchWorkItem?
    var displayMemory = DisplayMemory()
    var displayMemoryURL: URL { storage.appendingPathComponent("display-history.json") }
    var timer: Timer?
    var pendingSave: DispatchWorkItem?
    var pendingRefresh: DispatchWorkItem?
    var restoring = false
    var applying = false
    var interacting = false
    var scrollingUntil = Date.distantPast
    private var scrollDelta: Double = 0
    private var scrollDisplay: String?
    private var scrollScheduled = false
    var nativeMouseMonitor: Any?
    var nativeGestureWindow: String?
    var nativeGestureUntil = Date.distantPast
    var geometryFeedback = GeometryFeedback()
    var geometryDiagnostics: [[String: Any]] = []
    var resizeDiagnostics: [[String: Any]] = []
    var agentBusy = false
    var lastGeometryObservation: [String: String] = [:]
    var lastApply = Date.distantPast
    var tokens: [NSObjectProtocol] = []
    let storage: URL
    var stateURL: URL { storage.appendingPathComponent("layout.json") }
    var recoveryURL: URL { storage.appendingPathComponent("restore.json") }
    /// Set in the recovery watchdog: keep records of windows that are on another
    /// Space (it retries on Space changes); the app drops them instead.
    var keepsOtherSpaceRecords = false
    /// "pid:windowNumber" for every window WindowServer knows, on any Space.
    func allSpaceWindowIDs() -> Set<String> {
        Set(
            ((CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []).compactMap {
                row -> String? in
                guard let pid = row[kCGWindowOwnerPID as String] as? Int32,
                    let number = row[kCGWindowNumber as String] as? UInt32
                else { return nil }
                return "\(pid):\(number)"
            })
    }
    var maxStackMessage = "A column holds at most three windows. Drop between columns to separate them."
    init(storage: URL? = nil) {
        self.storage =
            storage
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kolom")
        try? FileManager.default.createDirectory(at: self.storage, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.storage.path)
        recoveryAvailable = FileManager.default.fileExists(atPath: recoveryURL.path)
        excludedBundles = Set(UserDefaults.standard.stringArray(forKey: "excludedBundles") ?? [])
        permissionGranted = bridge.trusted
        permissionDetails = bridge.permissionReport
        initializePausedWorkspace()
        bridge.onChange = { [weak self] in self?.scheduleRefresh() }
        nativeMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) {
            [weak self] event in
            guard let self, self.enabled else { return }
            if event.type == .leftMouseDown {
                let mouse = NSEvent.mouseLocation
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                let point = CGPoint(x: mouse.x, y: top - mouse.y)
                let focused = self.bridge.focusedWindowID(in: self.windows)
                self.nativeGestureWindow = focused.flatMap { id in
                    guard let frame = self.expected[id], !self.offStrip.contains(id),
                        frame.insetBy(dx: -12, dy: -12).contains(point)
                    else { return nil }
                    let border = point.x < frame.minX + 12 || point.x > frame.maxX - 12 || point.y > frame.maxY - 12
                    return border || point.y < frame.minY + 36 ? id : nil
                }
                self.nativeGestureUntil = .distantPast
            } else {
                self.nativeGestureUntil = Date().addingTimeInterval(1)
                self.scheduleRefresh()
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
        ] {
            tokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    if note.name == NSWorkspace.activeSpaceDidChangeNotification {
                        self?.handleSpaceChange()
                    } else {
                        self?.scheduleRefresh()
                    }
                })
        }
        // System sleep and display sleep are tracked separately: didWake arrives
        // while the displays may still be asleep.
        for (name, flag, value) in [
            (NSWorkspace.willSleepNotification, SessionFlag.systemAsleep, true),
            (NSWorkspace.didWakeNotification, .systemAsleep, false),
            (NSWorkspace.screensDidSleepNotification, .displaysAsleep, true),
            (NSWorkspace.screensDidWakeNotification, .displaysAsleep, false),
            (NSWorkspace.sessionDidResignActiveNotification, .resigned, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, .resigned, false),
        ] {
            tokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.handleSession(flag, value)
                })
        }
        // Locking without sleeping posts no workspace notification. These read-only
        // distributed notifications are informational; nothing depends on them existing.
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            tokens.append(
                DistributedNotificationCenter.default().addObserver(
                    forName: Notification.Name(name), object: nil, queue: .main
                ) { [weak self] _ in self?.handleSession(.locked, locked) })
        }
        tokens.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.permissionGranted = self.bridge.checkPermission(force: true)
                self.permissionDetails = self.bridge.permissionReport
            })
        tokens.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.screensChanged() })
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.permissionGranted = self.bridge.trusted
            self.permissionDetails = self.bridge.permissionReport
            if self.healSessionIfActive() { return }
            if self.enabled { self.refresh() } else { self.writeLiveState() }
        }
    }
    func realDisplays() -> [DisplayModel] {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.map { s in
            let number = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            // Returns NULL for an invalid display ID; never trap on it.
            let identity =
                CGDisplayCreateUUIDFromDisplayID(number).map {
                    CFUUIDCreateString(nil, $0.takeRetainedValue()) as String
                }
                ?? "display-\(number)"
            return DisplayModel(
                id: identity, name: s.localizedName, frame: accessibilityRect(s.visibleFrame, primaryTop: top),
                screen: s)
        }
    }
    func initializePausedWorkspace() {
        demo = true
        enabled = false
        displays = realDisplays()
        workspaces = [:]
        windows = [:]
        activeDisplay = displays.first?.id ?? ""
        status = "Kolom is paused · enable window management from the menu bar"
    }
    func enable() {
        guard !restoring else {
            status = "Finishing window recovery before starting"
            return
        }
        guard checkAccess() else {
            status =
                "Window management needs access for this copy of Kolom. Open permission settings or reveal the app below."
            return
        }
        if recoveryAvailable {
            status = "Restore the previous session before starting a new one."
            return
        }
        displays = realDisplays()
        activeDisplay = displays.first?.id ?? ""
        windows = [:]
        parked = []
        expected = [:]
        suspended = [:]
        originals = [:]
        geometryFeedback = GeometryFeedback()
        workspaces =
            (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode([String: Workspace].self, from: $0) }
            ?? [:]
        // Migrate numeric display IDs from earlier local builds.
        for display in displays {
            if let number = (display.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .stringValue, let old = workspaces.removeValue(forKey: number), workspaces[display.id] == nil
            {
                workspaces[display.id] = old
            }
        }
        displayMemory =
            (try? Data(contentsOf: displayMemoryURL)).flatMap {
                try? JSONDecoder().decode(DisplayMemory.self, from: $0)
            } ?? DisplayMemory()
        let saved = holdSavedWindows()
        let live = Set(bridge.discover(adoptMinimized: true).map(\.id)).union(
            saved.filter { isRunning(windowID: $0) })
        if let primary = displays.first?.id {
            displayMemory.reconnect(
                workspaces: &workspaces, connected: displays.map(\.id), primary: primary, live: live)
        }
        demo = false
        suspension = nil
        absence = AbsenceTracker()
        absentWindows = []
        spaceChangeDeferred = false
        pauseReason = nil
        interacting = false
        enabled = true
        // Enabled while asleep or locked (or with a missed wake): stay suspended.
        if !inactiveSession.isEmpty { suspend(.sessionInactive) }
        refresh(force: true)
        if enabled { status = "Managing this Space · pause restores the original window positions" }
        reconcileArrangement()
        layoutChanged?()
    }
    var permissionPaneName: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
            ? "Device Control and Data Access" : "Accessibility"
    }
    @discardableResult func checkAccess() -> Bool {
        permissionGranted = bridge.checkPermission(force: true)
        permissionDetails = bridge.permissionReport
        status =
            permissionGranted
            ? "Window access verified. Click Enable window management."
            : "Window access is not available for this running copy of Kolom."
        return permissionGranted
    }
    func requestAccess() {
        bridge.requestPermission()
        status = "In Privacy & Security → \(permissionPaneName), enable Kolom. Then click Check access again."
    }
    func revealRunningApp() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }

    func pause(logged: Bool = true, completion: (() -> Void)? = nil) {
        if enabled && logged { logPause(pauseReason ?? "paused from the menu or a command") }
        suspension = nil
        absence = AbsenceTracker()
        absentWindows = []
        spaceChangeDeferred = false
        animation?.invalidate()
        animation = nil
        displayChangeTask?.cancel()
        // A drag interrupted by the pause never delivers its mouse-up.
        interacting = false
        flushLayout()
        enabled = false
        pendingRefresh?.cancel()
        bridge.stopObserving()
        commandDisplay = nil
        layoutChanged?()
        guard !restoring else {
            restoreArrangement()
            completion?()
            return
        }
        if originals.isEmpty, recoveryAvailable {
            originals =
                (try? Data(contentsOf: recoveryURL)).flatMap {
                    try? JSONDecoder().decode([String: OriginalWindow].self, from: $0)
                } ?? [:]
        }
        // Records are in desk coordinates: put the desk back first and let macOS
        // report the new screens before restoring windows.
        if restoreArrangement() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.restoreSession(completion: completion)
            }
        } else {
            restoreSession(completion: completion)
        }
    }
    func restoreSession(completion: (() -> Void)? = nil) {
        guard !restoring else {
            completion?()
            return
        }
        guard bridge.trusted else {
            status = "Window recovery needs Kolom’s window-control permission" + takePauseReason()
            completion?()
            return
        }
        restoring = true
        let screens = realDisplays().map(\.frame)
        let scanned = bridge.discover(includeMinimized: true)
        var candidates = uniqueByID(scanned, id: \.id)
        candidates.merge(windows) { old, _ in old }
        candidates.merge(suspended) { old, _ in old }
        if originals.isEmpty {
            for window in scanned
            where !excludedBundles.contains(window.bundleID) && !windowIsReachable(window.frame, screens: screens) {
                originals[window.id] = OriginalWindow(
                    id: window.id, pid: window.pid, frame: window.frame, minimized: false, bundleID: window.bundleID,
                    title: window.title)
            }
        }
        var targets: [String: (NativeWindow, CGRect, Bool)] = [:]
        var claimed = Set<String>()
        // Accessibility lists only this Space's windows; the WindowServer list
        // covers all Spaces (and ordered-out windows). A recorded window that
        // exists but is not listed here is never swapped for another window of
        // the same app. The watchdog keeps its record and retries on Space
        // changes; the app drops it rather than block startup on it.
        let liveNumbers = allSpaceWindowIDs()
        func onAnotherSpace(_ id: String) -> Bool { candidates[id] == nil && liveNumbers.contains(id) }
        for (index, pair) in originals.sorted(by: { $0.key < $1.key }).enumerated() {
            let (id, original) = pair
            guard let app = NSRunningApplication(processIdentifier: original.pid),
                original.bundleID == nil || original.bundleID == app.bundleIdentifier
            else {
                originals.removeValue(forKey: id)
                continue
            }
            if onAnotherSpace(id) {
                if !keepsOtherSpaceRecords {
                    droppedOtherSpace[id] = original
                    originals.removeValue(forKey: id)
                }
                continue
            }
            let matches = candidates.values.filter {
                $0.pid == original.pid && !claimed.contains($0.id)
                    && (original.title == nil || $0.title == original.title)
            }
            guard let window = candidates[id] ?? (matches.count == 1 ? matches.first : nil) else { continue }
            if bridge.isDestroyed(window.element) {
                originals.removeValue(forKey: id)
                continue
            }
            claimed.insert(window.id)
            targets[id] = (
                window, usableRestorationFrame(original.frame, screens: screens, index: index), original.minimized
            )
        }
        // A stale WindowServer identity must not strand a window or block recovery
        // forever. Rescue unreachable windows of the recorded app without guessing
        // which document corresponds to an old record; leave usable windows alone.
        for (id, original) in Array(originals) where targets[id] == nil && !onAnotherSpace(id) {
            let appWindows = candidates.values.filter { $0.pid == original.pid && !claimed.contains($0.id) }
            guard !appWindows.isEmpty else { continue }
            var unreadable = false
            for window in appWindows {
                if bridge.isDestroyed(window.element) { continue }
                guard let actual = bridge.frame(window.element) else {
                    unreadable = true
                    continue
                }
                guard !windowIsReachable(actual, screens: screens) else { continue }
                let recoveryID = window.id
                originals[recoveryID] = OriginalWindow(
                    id: recoveryID, pid: window.pid, frame: actual, minimized: false, bundleID: window.bundleID,
                    title: window.title)
                targets[recoveryID] = (
                    window, usableRestorationFrame(actual, screens: screens, index: targets.count), false
                )
                claimed.insert(window.id)
            }
            if targets[id] == nil && !unreadable { originals.removeValue(forKey: id) }
        }
        // Older buggy sessions may have left a managed window without a record.
        for (id, window) in windows where originals[id] == nil && !claimed.contains(window.id) && window.pid != getpid()
        {
            guard !bridge.isDestroyed(window.element), NSRunningApplication(processIdentifier: window.pid) != nil else {
                continue
            }
            originals[id] = OriginalWindow(
                id: id, pid: window.pid, frame: window.frame, minimized: false, bundleID: window.bundleID,
                title: window.title)
            targets[id] = (window, usableRestorationFrame(window.frame, screens: screens, index: targets.count), false)
        }
        _ = saveRecovery()
        let checkedCount = targets.count
        var verifiedIDs = Set<String>()
        func report() {
            let data: [String: Any] = [
                "timestamp": Date().timeIntervalSince1970, "scanned": scanned.count, "checked": checkedCount,
                "verified": verifiedIDs.count, "remaining": self.originals.count,
            ]
            if let json = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) {
                try? json.write(to: self.storage.appendingPathComponent("last-recovery.json"), options: .atomic)
            }
        }
        func attempt(_ pass: Int) {
            for (_, target) in targets {
                // Restoration may wait longer than the 0.5 s default for slow apps.
                AXUIElementSetMessagingTimeout(target.0.element, 3)
                _ = self.bridge.minimize(target.0, false)
                _ = self.bridge.setFrame(target.0, target.1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (pass == 0 ? 0.25 : 0.5)) {
                var failures: [String: (NativeWindow, CGRect, Bool)] = [:]
                for (id, target) in targets {
                    if self.bridge.isDestroyed(target.0.element)
                        || NSRunningApplication(processIdentifier: target.0.pid) == nil
                    {
                        self.originals.removeValue(forKey: id)
                        continue
                    }
                    guard let actual = self.bridge.frame(target.0.element), windowIsReachable(actual, screens: screens)
                    else {
                        failures[id] = target
                        continue
                    }
                    if target.2 && !self.bridge.minimize(target.0, true) {
                        failures[id] = target
                        continue
                    }
                    verifiedIDs.insert(id)
                    self.originals.removeValue(forKey: id)
                }
                targets = failures
                if !failures.isEmpty && pass < 2 {
                    attempt(pass + 1)
                    return
                }
                self.restoring = false
                self.bridge.stopObserving()
                self.parked = []
                self.offStrip = []
                self.expected = [:]
                self.suspended = [:]
                _ = self.saveRecovery()
                self.status =
                    (self.originals.isEmpty
                        ? "Paused · all managed windows are reachable"
                        : "Some windows still need recovery · use Recover windows from the menu")
                    + self.takePauseReason()
                report()
                self.writeLiveState()
                self.layoutChanged?()
                completion?()
            }
        }
        if targets.isEmpty {
            restoring = false
            bridge.stopObserving()
            _ = saveRecovery()
            report()
            status =
                (originals.isEmpty
                    ? "Paused · windows restored" : "Recovery records retained · some windows could not be matched")
                + takePauseReason()
            completion?()
            return
        }
        attempt(0)
    }
    /// Why the last pause happened, appended to the final restoration status.
    var pauseReason: String?
    var pauseLogURL: URL { storage.appendingPathComponent("pause-log.json") }
    /// Keep the last pauses on disk: a pause restores every window and removes the
    /// rails, which looks like a crash unless its reason can be read afterwards.
    func logPause(_ reason: String) {
        var log =
            (try? Data(contentsOf: pauseLogURL)).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]]
            } ?? []
        log.append([
            "time": Date().timeIntervalSince1970, "reason": reason,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "development",
        ])
        if let data = try? JSONSerialization.data(withJSONObject: Array(log.suffix(30)), options: [.sortedKeys]) {
            try? data.write(to: pauseLogURL, options: .atomic)
        }
    }
    func takePauseReason() -> String {
        defer { pauseReason = nil }
        return pauseReason.map { " · " + $0 } ?? ""
    }
    func hasUnreachableWindows() -> Bool {
        let screens = realDisplays().map(\.frame)
        return bridge.discover(includeMinimized: true).contains {
            !excludedBundles.contains($0.bundleID) && !windowIsReachable($0.frame, screens: screens)
        }
    }
    func restorePrevious(completion: (() -> Void)? = nil) {
        guard !enabled else {
            pause(completion: completion)
            return
        }
        pause(completion: completion)
    }
    @discardableResult func saveRecovery() -> Bool {
        do {
            if originals.isEmpty {
                if FileManager.default.fileExists(atPath: recoveryURL.path) {
                    try FileManager.default.removeItem(at: recoveryURL)
                }
                recoveryAvailable = false
            } else {
                try JSONEncoder().encode(originals).write(to: recoveryURL, options: .atomic)
                recoveryAvailable = true
            }
            return true
        } catch {
            status = "Could not save restoration data: \(error.localizedDescription)"
            return false
        }
    }
    func saveLayout() {
        guard !demo else { return }
        pendingSave?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.flushLayout() }
        pendingSave = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
    }
    func flushLayout() {
        pendingSave?.cancel()
        pendingSave = nil
        guard !demo, let data = try? JSONEncoder().encode(workspaces) else { return }
        try? data.write(to: stateURL, options: .atomic)
        if let history = try? JSONEncoder().encode(displayMemory) {
            try? history.write(to: displayMemoryURL, options: .atomic)
        }
    }
    func scheduleRefresh() {
        guard enabled, !applying else { return }
        pendingRefresh?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: task)
    }
    /// Set while the session is asleep, locked or switched away: Kolom keeps
    /// its layout and records but moves nothing, and resumes by itself.
    /// Unlike a pause, nothing is restored.
    @Published var suspension: SuspensionReason?
    var managing: Bool { enabled && suspension == nil }
    /// Managing and not waiting to judge a Space change: input may move or focus windows.
    var acting: Bool { managing && !spaceChangeDeferred }
    var absence = AbsenceTracker()
    /// Managed windows kept in the layout although this pass did not list them.
    var absentWindows: Set<String> = []
    /// The temporary display staircase and the pointer routing that keeps crossings on the desk.
    lazy var arrangement = DisplayArrangement(
        read: { Self.displayFrames() }, write: { Self.configureDisplays($0, $1) }, primary: { CGMainDisplayID() },
        mirrored: { CGDisplayIsInMirrorSet($0) != 0 },
        stateURL: storage.appendingPathComponent("display-arrangement.json"),
        sessionID: Self.loginSessionID())
    let pointerRouter = PointerRouter()
    private var arrangementTask: DispatchWorkItem?
    /// Keep displays corner to corner while managing, so columns never reach a neighbor.
    var isolateDisplays: Bool {
        get { UserDefaults.standard.object(forKey: "isolateDisplays") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "isolateDisplays")
            if newValue { reconcileArrangement() } else if restoreArrangement() { noteDisplayReconfiguration() }
        }
    }
    /// Saved windows kept in place until the first passes after enabling find them.
    var startupHold = StartupHold()
    /// Saved windows the first pass missed, reported once when the hold ends.
    var startupMissed: Set<String>?
    var startupReported = false
    enum SessionFlag { case systemAsleep, displaysAsleep, resigned, locked }
    private var inactiveSession: Set<SessionFlag> = []
    /// A Space change arrived inside a display-intent window (Kolom's own
    /// transfers and display changes can post one). Refresh waits until it has
    /// been re-checked.
    var spaceChangeDeferred = false
    /// Records the app dropped because their window was on another Space. When
    /// the user arrives on that Space while Kolom is paused, unreachable ones
    /// are rescued.
    var droppedOtherSpace: [String: OriginalWindow] = [:]
    func suspend(_ reason: SuspensionReason) {
        guard enabled, suspension != reason else { return }
        animation?.invalidate()
        animation = nil
        commandDisplay = nil
        // A drag interrupted by the suspension never delivers its mouse-up.
        interacting = false
        suspension = reason
        flushLayout()
        status = "Waiting while the Mac is asleep, locked or switched to another user"
        layoutChanged?()
        writeLiveState()
    }
    func resume() {
        guard suspension != nil else { return }
        suspension = nil
        expected = [:]
        // Windows can take a while to be listed again after wake or unlock.
        holdSavedWindows()
        scheduleArrangement()
        status = "Managing this Space · pause restores the original window positions"
        layoutChanged?()
        // A Space change made just before sleep or lock is judged now; time spent
        // asleep does not count towards the settling limit.
        if spaceChangeDeferred {
            spaceChangeDeferredSince = Date()
            scheduleSpaceRecheck()
        }
    }
    /// A Space switch pauses and restores; the user re-enables on the Space
    /// they want managed. Accessibility lists only the current Space's windows,
    /// so Kolom does not try to infer when it may resume.
    func handleSpaceChange() {
        if !enabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.rescueDroppedOnThisSpace() }
            return
        }
        // Do not push the current Space's windows into a different Space.
        if Set(realDisplays().map(\.id)) != Set(displays.map(\.id)) { screensChanged() }
        guard managing || spaceChangeDeferred else { return }
        // Decide once things settle. A Space change inside an intent window may be
        // Kolom's own or a display coming up; any other one is the user's.
        let explained = Date() <= displayIntentUntil
        if !spaceChangeDeferred {
            spaceChangeDeferred = true
            spaceChangeDeferredSince = Date()
            spaceChangeUnexplainedAt = nil
        }
        lastSpaceChange = Date()
        if !explained, spaceChangeUnexplainedAt == nil { spaceChangeUnexplainedAt = Date() }
        scheduleSpaceRecheck()
    }
    /// A Space change explained by display reconfiguration that macOS reports just
    /// after it (displays bring their own Spaces) is not the user's.
    var spaceChangeUnexplainedAt: Date?
    var spaceChangeDeferredSince = Date.distantPast
    var lastSpaceChange = Date.distantPast
    var lastDisplayReconfiguration = Date.distantPast
    /// Displays come up in stages (DisplayLink adapters take seconds); every stage
    /// extends the window in which Space changes are not taken as the user's.
    func noteDisplayReconfiguration() {
        lastDisplayReconfiguration = Date()
        displayIntentUntil = max(displayIntentUntil, Date().addingTimeInterval(3))
        // Never route the pointer against stale geometry; re-derive once displays
        // settle. Kolom's own staircase arriving as reported keeps routing.
        if !arrangement.isolated || Self.displayFrames() != arrangement.applied {
            pointerRouter.update(technical: [:], desk: [:])
        }
        scheduleArrangement()
    }
    func scheduleArrangement() {
        arrangementTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.reconcileArrangement() }
        arrangementTask = task
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0.2, displayIntentUntil.timeIntervalSinceNow + 0.2), execute: task)
    }
    /// Applies the display staircase while managing independent displays, or puts the desk back.
    func reconcileArrangement() {
        arrangementTask?.cancel()
        arrangementTask = nil
        guard enabled, !restoring else { return }
        guard isolateDisplays else {
            if restoreArrangement() { noteDisplayReconfiguration() }
            return
        }
        // Suspended (asleep, locked): keep what is applied; resume reconciles.
        guard suspension == nil else { return }
        if arrangement.reconcile() { noteDisplayReconfiguration() }
        let maps = arrangement.pointerMaps
        pointerRouter.update(technical: maps.technical, desk: maps.desk)
        writeLiveState()
    }
    /// Returns true when display geometry changed.
    @discardableResult func restoreArrangement() -> Bool {
        arrangementTask?.cancel()
        arrangementTask = nil
        pointerRouter.update(technical: [:], desk: [:])
        return arrangement.restore()
    }
    /// A window frame in desk coordinates, for recovery records.
    func deskFrame(_ frame: CGRect) -> CGRect {
        arrangement.isolated ? deskRect(frame, technical: arrangement.applied, desk: arrangement.desk) : frame
    }
    static func displayFrames() -> [UInt32: CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [:] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [:] }
        return Dictionary(uniqueKeysWithValues: ids.prefix(Int(count)).map { ($0, CGDisplayBounds($0)) })
    }
    static func configureDisplays(_ frames: [UInt32: CGRect], _ scope: CGConfigureOption) -> CGError {
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else { return begin }
        for (id, frame) in frames.sorted(by: { $0.key < $1.key }) {
            guard frame.minX.isFinite, frame.minY.isFinite, abs(frame.minX) < 1e6, abs(frame.minY) < 1e6 else {
                CGCancelDisplayConfiguration(config)
                return .rangeCheck
            }
            let result = CGConfigureDisplayOrigin(config, id, Int32(frame.minX), Int32(frame.minY))
            guard result == .success else {
                CGCancelDisplayConfiguration(config)
                return result
            }
        }
        return CGCompleteDisplayConfiguration(config, scope)
    }
    /// Boot session plus audit session: a stored desk is trusted only within one login.
    static func loginSessionID() -> String? {
        var audit = auditinfo_addr_t()
        guard getaudit_addr(&audit, Int32(MemoryLayout.size(ofValue: audit))) == 0 else { return nil }
        var boot = [UInt8](repeating: 0, count: 128)
        var size = boot.count
        guard sysctlbyname("kern.bootsessionuuid", &boot, &size, nil, 0) == 0, size > 1, size <= boot.count,
            boot[size - 1] == 0
        else { return nil }
        return "\(String(decoding: boot.prefix(size - 1), as: UTF8.self)):\(audit.ai_asid)"
    }
    func scheduleSpaceRecheck() {
        let settled = max(displayIntentUntil, lastSpaceChange.addingTimeInterval(0.5))
        let delay = max(0.1, settled.timeIntervalSinceNow + 0.1)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.recheckDeferredSpaceChange()
        }
    }
    func pauseForSpaceChange() {
        pauseReason = "paused after a Space change; choose Enable to manage this Space"
        pause()
    }
    /// Pause on a Space change that nothing explains, or if any display lost most
    /// of its managed windows (a real Space switch); otherwise the notification
    /// was Kolom's own or a display's and management goes on.
    /// Pausing is the safe outcome when in doubt.
    func recheckDeferredSpaceChange() {
        guard spaceChangeDeferred else { return }
        guard enabled else {
            spaceChangeDeferred = false
            return
        }
        // Asleep or locked: judge it on resume, while refresh stays off.
        guard managing else { return }
        // Displays that never settle are not worth waiting for indefinitely.
        if Date().timeIntervalSince(spaceChangeDeferredSince) > 15 {
            pauseReason = "displays kept changing; choose Enable once they settle"
            pause()
            return
        }
        // Still settling: an earlier recheck must not judge a newer change midway.
        if Date() < displayIntentUntil || Date() < lastSpaceChange.addingTimeInterval(0.5) {
            scheduleSpaceRecheck()
            return
        }
        if Set(realDisplays().map(\.id)) != Set(displays.map(\.id)) {
            screensChanged()
            scheduleSpaceRecheck()
            return
        }
        spaceChangeDeferred = false
        if let at = spaceChangeUnexplainedAt, lastDisplayReconfiguration < at.addingTimeInterval(-0.25) {
            spaceChangeUnexplainedAt = nil
            pauseForSpaceChange()
            return
        }
        spaceChangeUnexplainedAt = nil
        let listed = Set(bridge.discover().map(\.id))
        let lostDisplay = displays.contains { d in
            let ids = (workspaces[d.id]?.windowIDs ?? []).filter { id in
                windows[id].map { !bridge.unresponsivePIDs.contains($0.pid) && !bridge.isDestroyed($0.element) }
                    ?? false
            }
            return !ids.isEmpty && ids.filter(listed.contains).count * 2 < ids.count
        }
        if lostDisplay { pauseForSpaceChange() } else { scheduleRefresh() }
    }
    /// While paused, rescue windows whose records were dropped because they were
    /// on another Space, once that Space is shown and they are still unreachable.
    func rescueDroppedOnThisSpace() {
        guard !enabled, !restoring, !droppedOtherSpace.isEmpty, bridge.trusted else { return }
        let screens = realDisplays().map(\.frame)
        let listed = bridge.discover(includeMinimized: true)
        var found = false
        for window in listed {
            guard let record = droppedOtherSpace[window.id] else { continue }
            droppedOtherSpace.removeValue(forKey: window.id)
            if !windowIsReachable(window.frame, screens: screens) && originals[window.id] == nil {
                originals[window.id] = record
                found = true
            }
        }
        guard found else { return }
        // Restore only the rescued records: the previous session's windows (kept in
        // `windows`/`suspended` after a pause) must not be moved again.
        windows = [:]
        suspended = [:]
        restoreSession()
    }
    func handleSession(_ flag: SessionFlag, _ active: Bool) {
        if active { inactiveSession.insert(flag) } else { inactiveSession.remove(flag) }
        if !inactiveSession.isEmpty {
            suspend(.sessionInactive)
        } else if suspension == .sessionInactive {
            resume()
            // Accessibility and the trust check can lag a wake or unlock briefly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh(force: true) }
        }
    }
    /// Notifications can be missed (the lock ones are informational). While
    /// suspended, re-derive the session state so a suspension cannot stick.
    /// Returns true when it resumed, so the caller does not refresh in the same
    /// tick (the delayed refresh gives Accessibility time to settle).
    @discardableResult func healSessionIfActive() -> Bool {
        guard suspension == .sessionInactive,
            let session = CGSessionCopyCurrentDictionary() as? [String: Any],
            let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool
        else { return false }
        let locked = (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
        guard onConsole, !locked, CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { return false }
        // Only flags this check can observe; system sleep is cleared by didWake.
        inactiveSession.subtract([.locked, .displaysAsleep, .resigned])
        handleSessionChanged()
        return suspension == nil
    }
    private func handleSessionChanged() {
        if inactiveSession.isEmpty, suspension == .sessionInactive {
            resume()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh(force: true) }
        }
    }
    func screensChanged() {
        guard enabled else { return }
        animation?.invalidate()
        animation = nil
        noteDisplayReconfiguration()
        scrollingUntil = displayIntentUntil
        displayChangeTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.enabled else { return }
            let connected = self.realDisplays()
            guard let primary = connected.first?.id else { return }
            // The same open windows refresh keeps: a window briefly missing from a pass
            // must not lose its home display here.
            self.displayMemory.reconnect(
                workspaces: &self.workspaces, connected: connected.map(\.id), primary: primary,
                live: Set(self.windows.keys).union(self.suspended.keys).union(self.startupHold.waiting))
            self.displays = connected
            self.commandDisplay = nil
            // Side panels stay open unless their display is gone; the staircase
            // itself reports a display change.
            let ids = Set(connected.map(\.id))
            if let id = self.performanceDisplay, !ids.contains(id) { self.performanceDisplay = nil }
            if let id = self.guideDisplay, !ids.contains(id) { self.guideDisplay = nil }
            self.activeDisplay = primary
            self.expected = [:]
            for display in connected {
                self.workspaces[display.id]?.clampOffset(viewportWidth: self.viewport(display).width, desktopTail: true)
            }
            self.apply()
            self.saveLayout()
            self.refresh(force: true)
            self.status = "Displays updated · disconnected windows join the primary display and return when reconnected"
        }
        displayChangeTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
    }
    func viewport(_ display: DisplayModel) -> CGRect {
        let shelf: Double =
            performanceDisplay == display.id || guideDisplay == display.id
            ? performanceWidth : (commandDisplay == display.id ? 224 : 0)
        return CGRect(
            x: display.frame.minX + 48 + shelf + 16, y: display.frame.minY + 16,
            width: max(260, display.frame.width - 48 - shelf - 32), height: max(160, display.frame.height - 32))
    }
    func refresh(force: Bool = false) {
        // While asleep, locked or switched away, Accessibility and even the
        // permission check can fail transiently; do not treat that as revocation.
        if enabled && suspension == .sessionInactive { return }
        guard enabled, bridge.trusted else {
            if enabled {
                pauseReason = "Accessibility access was removed"
                pause()
            }
            return
        }
        if NSEvent.pressedMouseButtons != 0 || interacting || agentBusy || spaceChangeDeferred { return }
        let retained = windows
        let wasUnresponsive = bridge.unresponsivePIDs
        let discovered = bridge.discover(retaining: retained, adoptMinimized: true).filter {
            !excludedBundles.contains($0.bundleID)
        }
        // An app that answers again missed the moves skipped while it was busy.
        let recovered = wasUnresponsive.subtracting(bridge.unresponsivePIDs)
        func isOpen(_ window: NativeWindow) -> Bool {
            NSRunningApplication(processIdentifier: window.pid) != nil
                && (bridge.unresponsivePIDs.contains(window.pid) || !bridge.isDestroyed(window.element))
        }
        let discoveredIDs = Set(discovered.map(\.id))
        // Windows missing from this pass keep their column for a grace period,
        // or while in native full screen; closed windows are dropped.
        let previouslyAbsent = absentWindows
        let away = absence.retained(
            previous: Set(retained.keys), discovered: discoveredIDs,
            now: Date().timeIntervalSinceReferenceDate,
            isAlive: { id in retained[id].map(isOpen) ?? false },
            isFullScreen: { [bridge] id in retained[id].map { bridge.isFullScreen($0.element) } ?? false })
        let fresh = reconcileRetainedWindows(
            discovered: uniqueByID(discovered, id: \.id), previous: retained,
            hidden: offStrip.union(away).union(
                retained.values.filter { bridge.unresponsivePIDs.contains($0.pid) }.map(\.id)), isAlive: isOpen)
        absentWindows = Set(fresh.keys).subtracting(discoveredIDs)
        // A window that is listed again missed the moves skipped while it was absent.
        let returned = previouslyAbsent.intersection(discoveredIDs)
        let found = discovered + fresh.values.filter { window in !discovered.contains(where: { $0.id == window.id }) }
        let changedMembership = Set(fresh.keys) != Set(windows.keys)
        var changed = force || changedMembership || !returned.isEmpty
        for id in returned { expected.removeValue(forKey: id) }
        for w in retained.values where recovered.contains(w.pid) {
            expected.removeValue(forKey: w.id)
            changed = true
        }
        // While displays reconfigure, macOS moves windows itself (off a display that
        // went away, back onto one that returned) and the display frames here are
        // stale. Taking those moves as drags would forget a window's home display
        // and pull it out of its stack.
        let real = realDisplays()
        let displaysSettled =
            Date() > displayIntentUntil && real.map(\.id) == displays.map(\.id)
            && real.map(\.screen?.frame) == displays.map(\.screen?.frame)
        if !force && Date().timeIntervalSince(lastApply) > 0.4 && Date() > scrollingUntil && displaysSettled {
            // Retained windows of busy apps carry stale frames; they are not readings.
            for w in found
            where w.pid != getpid() && !offStrip.contains(w.id) && !bridge.unresponsivePIDs.contains(w.pid)
                && !absentWindows.contains(w.id)
            {
                guard let previous = expected[w.id], let display = displayForWindow(w.id) else { continue }
                let resized = abs(w.frame.width - previous.width) > 4 || abs(w.frame.height - previous.height) > 4
                let userGesture = nativeGestureWindow == w.id && Date() < nativeGestureUntil
                if !userGesture {
                    // AX success does not mean the app has finished adopting its size.
                    // Retry once after settling; never turn app constraints into a drag.
                    let decision = geometryFeedback.decision(
                        w.id, actual: w.frame, time: Date().timeIntervalSinceReferenceDate, userGesture: false)
                    recordGeometryObservation(w, requested: previous, decision: decision)
                    switch decision {
                    case .retry:
                        expected.removeValue(forKey: w.id)
                        changed = true
                    case .constrained:
                        if workspaces[display.id]?.accommodateWindowWidth(w.id, actualWidth: w.frame.width) == true {
                            expected.removeValue(forKey: w.id)
                            changed = true
                            if workspaces[display.id]?.focus == w.id {
                                workspaces[display.id]?.reveal(w.id, viewportWidth: viewport(display).width)
                            }
                            status = "Expanded the shared column to fit \(w.appName)’s accepted width"
                        } else {
                            status =
                                "\(w.appName) constrained its window geometry · leaving it stable instead of repeating moves"
                        }
                    default: break
                    }
                    continue
                }
                if abs(w.frame.width - previous.width) > 4 {
                    workspaces[display.id]?.setWidth(w.id, w.frame.width)
                    changed = true
                }
                if abs(w.frame.height - previous.height) > 4 {
                    workspaces[display.id]?.setHeight(
                        w.id, height: w.frame.height, availableHeight: viewport(display).height)
                    changed = true
                }
                let moved = abs(w.frame.minX - previous.minX) > 30 || abs(w.frame.minY - previous.minY) > 30
                if resized || moved { expected.removeValue(forKey: w.id) }
                if moved {
                    let point = CGPoint(x: w.frame.midX, y: w.frame.midY)
                    if let destination = displays.first(where: { $0.frame.contains(point) }),
                        destination.id != display.id
                    {
                        transfer(w.id, to: destination.id, applyNow: false)
                        changed = true
                    } else if resized {
                        continue
                    } else if let target = found.first(where: {
                        $0.id != w.id && !absentWindows.contains($0.id) && displayForWindow($0.id)?.id == display.id
                            && $0.frame.contains(CGPoint(x: w.frame.midX, y: w.frame.minY + 16))
                    }) {
                        let relativeX = (w.frame.midX - target.frame.minX) / max(1, target.frame.width)
                        let edge: Placement =
                            relativeX < 0.2
                            ? .before : relativeX > 0.8 ? .after : w.frame.minY < target.frame.midY ? .above : .below
                        if workspaces[display.id]?.move(w.id, to: target.id, placement: edge) == true { changed = true }
                    } else {
                        let others = found.filter {
                            $0.id != w.id && !absentWindows.contains($0.id) && displayForWindow($0.id)?.id == display.id
                                && !parked.contains($0.id)
                        }
                        if let nearest = others.min(by: {
                            abs($0.frame.midX - w.frame.midX) < abs($1.frame.midX - w.frame.midX)
                        }) {
                            _ = workspaces[display.id]?.move(
                                w.id, to: nearest.id, placement: w.frame.midX < nearest.frame.midX ? .before : .after)
                        }
                        changed = true
                    }
                }
            }
        }
        if Date() < nativeGestureUntil {
            nativeGestureWindow = nil
            nativeGestureUntil = .distantPast
        }
        for (id, w) in windows where w.pid != getpid() && fresh[id] == nil && originals[id] != nil {
            if NSRunningApplication(processIdentifier: w.pid) == nil || bridge.isDestroyed(w.element) {
                originals.removeValue(forKey: id)
                suspended.removeValue(forKey: id)
            } else {
                suspended[id] = w
            }
        }
        windows = fresh
        let held = startupHold.held(
            discovered: Set(fresh.keys), now: Date().timeIntervalSinceReferenceDate,
            isRunning: { self.isRunning(windowID: $0) },
            isBusy: { [bridge] id in Int32(id.prefix { $0 != ":" }).map(bridge.unresponsivePIDs.contains) ?? false })
        noteStartupHold(held)
        geometryFeedback.retain(Set(fresh.keys).union(suspended.keys))
        displayMemory.prune(live: Set(fresh.keys).union(suspended.keys).union(held))
        for w in found where w.pid != getpid() && originals[w.id] == nil {
            originals[w.id] = OriginalWindow(
                id: w.id, pid: w.pid, frame: deskFrame(w.frame), minimized: w.minimized, bundleID: w.bundleID,
                title: w.title)
        }
        // Persist before moving anything. If the record cannot be written, stop
        // moving windows and restore the already-parked ones from memory.
        guard saveRecovery() else {
            pauseReason = status
            pause()
            return
        }
        let allIDs = Set(found.map(\.id)).union(held)
        let previouslyAssigned = Set(workspaces.values.flatMap(\.windowIDs))
        var newlyRevealed: String?
        for d in displays {
            var ids = workspaces[d.id]?.windowIDs.filter { allIDs.contains($0) } ?? []
            let assigned = Set(workspaces.values.flatMap(\.windowIDs))
            for w in found where !assigned.contains(w.id) {
                let target = launchTargets[w.pid].flatMap { $0.expires > Date() ? $0.display : nil }
                let destination =
                    target
                    ?? (!force && displays.contains(where: { $0.id == activeDisplay }) ? activeDisplay : nil)
                    ?? bestDisplay(for: w.frame)?.id
                if destination == d.id { ids.append(w.id) }
            }
            var space = workspaces[d.id] ?? Workspace()
            space.reconcile(ids, defaultWidth: min(640, max(300, viewport(d).width * 0.55)))
            if !force, let opened = ids.last(where: { !previouslyAssigned.contains($0) }) {
                space.reveal(opened, viewportWidth: viewport(d).width)
                newlyRevealed = opened
                changed = true
                activeDisplay = d.id
            }
            space.clampOffset(viewportWidth: viewport(d).width, desktopTail: true)
            workspaces[d.id] = space
        }
        if newlyRevealed == nil, Date() > displayIntentUntil, let focused = bridge.focusedWindowID(in: windows),
            let d = displayForWindow(focused)
        {
            if Date() > scrollingUntil && workspaces[d.id]?.focus != focused {
                workspaces[d.id]?.reveal(focused, viewportWidth: viewport(d).width)
                changed = true
            }
            lastFocusedWindow = focused
            activeDisplay = d.id
        }
        if changed {
            apply()
            saveLayout()
            if let opened = newlyRevealed, let window = windows[opened] {
                lastFocusedWindow = opened
                bridge.focus(window)
            }
        }
        writeLiveState()
    }
    /// Starts holding the layout's windows in place until a pass finds them.
    @discardableResult func holdSavedWindows() -> Set<String> {
        let saved = Set(workspaces.values.flatMap(\.windowIDs)).union(
            displayMemory.detached.values.flatMap(\.windowIDs))
        startupHold = StartupHold(saved, until: Date().timeIntervalSinceReferenceDate + 15)
        startupMissed = nil
        startupReported = false
        return saved
    }
    /// Window IDs start with the owning process ID.
    func isRunning(windowID id: String) -> Bool {
        Int32(id.prefix { $0 != ":" }).flatMap { NSRunningApplication(processIdentifier: $0) } != nil
    }
    /// Records how many saved windows the first pass missed and how many came back.
    func noteStartupHold(_ held: Set<String>) {
        if startupMissed == nil { startupMissed = held }
        guard let missed = startupMissed, held.isEmpty, !startupReported else { return }
        startupReported = true
        let report: [String: Any] = [
            "time": Date().timeIntervalSince1970, "missed": missed.count,
            "found": missed.subtracting(startupHold.dropped).count, "dropped": startupHold.dropped.count,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            try? data.write(to: storage.appendingPathComponent("startup-hold.json"), options: .atomic)
        }
    }
    func recordResize(_ id: String, axis: String, phase: String, start: Double, delta: Double) {
        resizeDiagnostics.append([
            "time": Date().timeIntervalSince1970, "window": id, "axis": axis, "phase": phase, "start": start,
            "delta": delta,
        ])
        if resizeDiagnostics.count > 64 { resizeDiagnostics.removeFirst(resizeDiagnostics.count - 64) }
        if let data = try? JSONSerialization.data(withJSONObject: resizeDiagnostics, options: [.sortedKeys]) {
            try? data.write(to: storage.appendingPathComponent("resize-feedback.json"), options: .atomic)
        }
    }
    func writeLiveState() {
        func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }
        let rendered =
            (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]) ?? []
        let full = displays.map(\.fullFrame)
        let rows = displays.enumerated().map { index, d -> [String: Any] in
            let space = workspaces[d.id] ?? Workspace()
            return [
                "id": d.id, "index": index + 1, "name": d.name, "bounds": rect(full[index]),
                "viewport": rect(viewport(d)), "offset": space.offset,
                "columns": space.columns.map { c -> [String: Any] in
                    [
                        "width": c.width,
                        "windows": c.tiles.compactMap { tile -> [String: Any]? in
                            guard let w = windows[tile.id] else { return nil }
                            let actual =
                                bridge.unresponsivePIDs.contains(w.pid) ? w.frame : bridge.frame(w.element) ?? w.frame
                            let number = UInt32(w.id.split(separator: ":").last ?? "")
                            let cg = rendered.first {
                                ($0[kCGWindowNumber as String] as? UInt32) == number
                                    && ($0[kCGWindowOwnerPID as String] as? Int32) == w.pid
                            }
                            let drawn = (cg?[kCGWindowBounds as String] as? [String: Any]).flatMap {
                                CGRect(dictionaryRepresentation: $0 as CFDictionary)
                            }
                            let overlaps = displays.indices.filter { $0 != index }.compactMap {
                                other -> [String: Any]? in
                                let intersection = actual.intersection(full[other])
                                guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
                                    return nil
                                }
                                return [
                                    "display": displays[other].id, "width": intersection.width,
                                    "height": intersection.height,
                                ]
                            }
                            let drawnOverlaps = displays.indices.filter { $0 != index }.compactMap {
                                other -> [String: Any]? in
                                guard let drawn else { return nil }
                                let intersection = drawn.intersection(full[other])
                                guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
                                    return nil
                                }
                                return [
                                    "display": displays[other].id, "width": intersection.width,
                                    "height": intersection.height,
                                ]
                            }
                            return [
                                "id": w.id, "app": w.bundleID, "actual": rect(actual),
                                "requested": expected[w.id].map(rect) ?? [], "offStrip": offStrip.contains(w.id),
                                "foreignOverlaps": overlaps, "onScreen": cg != nil,
                                "renderedBounds": drawn.map(rect) ?? [], "renderedForeignOverlaps": drawnOverlaps,
                            ]
                        },
                    ]
                },
            ]
        }
        let state: [String: Any] = [
            "pid": getpid(), "permissionGranted": permissionGranted, "restoring": restoring,
            "recoveryAvailable": recoveryAvailable, "timestamp": Date().timeIntervalSince1970,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "development", "enabled": enabled, "suspended": suspension?.rawValue ?? NSNull(),

            "agentBusy": agentBusy, "desktopColumnRatio": 1.1,
            "displayArrangement": arrangement.status, "pointerWarps": pointerRouter.warpCount,
            "isolateDisplays": isolateDisplays, "status": status, "parking": "per-display-safe-edge",
            "presentation": "native windows; displays kept apart while managing", "displays": rows,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            try? data.write(to: storage.appendingPathComponent("live-state.json"), options: .atomic)
        }
    }
    func recordGeometryObservation(_ window: NativeWindow, requested: CGRect, decision: GeometryFeedback.Decision) {
        guard decision != .unchanged else { return }
        let actual = window.frame
        let signature = "\(decision):\(actual)"
        guard lastGeometryObservation[window.id] != signature else { return }
        lastGeometryObservation[window.id] = signature
        func values(_ frame: CGRect) -> [Double] { [frame.minX, frame.minY, frame.width, frame.height] }
        geometryDiagnostics.append([
            "time": Date().timeIntervalSince1970, "window": window.id, "app": window.bundleID,
            "decision": String(describing: decision), "requested": values(requested), "actual": values(actual),
        ])
        if geometryDiagnostics.count > 64 { geometryDiagnostics.removeFirst(geometryDiagnostics.count - 64) }
        if let data = try? JSONSerialization.data(withJSONObject: geometryDiagnostics, options: [.sortedKeys]) {
            try? data.write(to: storage.appendingPathComponent("geometry-feedback.json"), options: .atomic)
        }
    }
    func pointerDisplay() -> DisplayModel? {
        let mouse = NSEvent.mouseLocation
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let point = CGPoint(x: mouse.x, y: top - mouse.y)
        return displays.first { $0.fullFrame.contains(point) }
    }
    func bestDisplay(for frame: CGRect) -> DisplayModel? {
        displays.max { a, b in
            let x = a.frame.intersection(frame)
            let y = b.frame.intersection(frame)
            return (x.isNull ? 0 : x.width * x.height) < (y.isNull ? 0 : y.width * y.height)
        }
    }
    func displayForWindow(_ id: String) -> DisplayModel? {
        displays.first { workspaces[$0.id]?.windowIDs.contains(id) == true }
    }
    func apply(reflow: Bool = true) {
        // Suspended: no moves. Panels still refresh (Performance opens and closes);
        // syncPanels never calls back into apply or focus.
        if suspension != nil {
            layoutChanged?()
            return
        }
        guard enabled, !demo else {
            layoutChanged?()
            return
        }
        applying = true
        offStrip = []
        defer {
            applying = false
            lastApply = Date()
            layoutChanged?()
        }
        for d in displays {
            let area = viewport(d)
            guard let space = workspaces[d.id] else { continue }
            let screenRect = d.fullFrame
            let frames = space.frames(in: area)
            for id in space.windowIDs {
                guard let w = windows[id], let virtual = frames[id] else { continue }
                // A busy app cannot take writes; place it once it responds again.
                if bridge.unresponsivePIDs.contains(w.pid) || absentWindows.contains(id) { continue }
                let screenFrames = displays.map(\.fullFrame)
                let crossesForeign = screenFrames.filter { $0 != screenRect }.contains {
                    let i = virtual.intersection($0)
                    return !i.isNull && i.width > 0 && i.height > 0
                }
                let outside = virtual.maxX <= area.minX || virtual.minX >= area.maxX || crossesForeign
                guard
                    let physical = outside
                        ? isolatedParkingFrame(
                            virtual, owner: screenRect, screens: screenFrames, before: virtual.minX < area.minX)
                        : virtual
                else {
                    pauseReason = "a display has no isolated native parking edge"
                    pause()
                    return
                }
                if outside { offStrip.insert(id) }
                if w.minimized || parked.contains(id) {
                    guard bridge.minimize(w, false) else {
                        status = "\(w.appName) refused to restore a minimized window."
                        continue
                    }
                    parked.remove(id)
                    windows[id]?.minimized = false
                }
                // Only send changes. Do not interpret an immediate readback as a
                // minimum size: AX geometry updates in many apps are asynchronous.
                if expected[id] != physical || w.minimized {
                    let resize = expected[id]?.size != physical.size
                    if bridge.setFrame(w, physical, resize: resize) {
                        expected[id] = physical
                        geometryFeedback.recordWrite(id, frame: physical, time: Date().timeIntervalSinceReferenceDate)
                    }
                }
            }
        }
        if let error = bridge.lastError, !bridge.writeFailures.isEmpty { status = error }
    }
    func scroll(displayID: String, delta: Double) {
        guard acting, let d = displays.first(where: { $0.id == displayID }) else { return }
        animation?.invalidate()
        animation = nil
        activeDisplay = displayID
        scrollingUntil = Date().addingTimeInterval(0.8)
        if scrollDisplay != displayID { scrollDelta = 0 }
        scrollDisplay = displayID
        scrollDelta += delta
        guard !scrollScheduled else { return }
        scrollScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            guard let self else { return }
            self.scrollScheduled = false
            let amount = self.scrollDelta
            self.scrollDelta = 0
            guard self.enabled, let id = self.scrollDisplay, let current = self.displays.first(where: { $0.id == id })
            else { return }
            self.workspaces[id]?.scroll(by: amount, viewportWidth: self.viewport(current).width, desktopTail: true)
            self.apply()
            self.saveLayout()
        }
        _ = d
    }
    func beginResize() {
        animation?.invalidate()
        animation = nil
        interacting = true
    }
    func endResize() {
        interacting = false
        scrollingUntil = Date().addingTimeInterval(0.5)
        layoutChanged?()
        saveLayout()
        scheduleRefresh()
    }
    func animateStrip(displayID: String, to target: Double, completion: (() -> Void)? = nil) {
        animation?.invalidate()
        animation = nil
        guard let from = workspaces[displayID]?.offset else { return }
        activeDisplay = displayID
        let duration = min(0.48, max(0.20, abs(target - from) / 7000))
        scrollingUntil = Date().addingTimeInterval(duration + 0.5)
        if abs(target - from) < 1 || !enabled {
            workspaces[displayID]?.offset = target
            apply()
            completion?()
            saveLayout()
            return
        }
        let start = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self, self.enabled else {
                timer.invalidate()
                return
            }
            let progress = Date().timeIntervalSince(start) / duration
            self.workspaces[displayID]?.offset = animatedStripOffset(from: from, to: target, progress: progress)
            self.apply()
            if progress >= 1 {
                timer.invalidate()
                self.animation = nil
                completion?()
                self.saveLayout()
            }
        }
        animation = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func showDesktop() {
        guard let display = displays.first(where: { $0.id == activeDisplay }), var space = workspaces[activeDisplay]
        else { return }
        space.scroll(by: Double.greatestFiniteMagnitude, viewportWidth: viewport(display).width, desktopTail: true)
        animateStrip(displayID: display.id, to: space.offset)
    }
    func focus(_ id: String) {
        // Focusing while suspended, or while a Space change is undecided, would
        // activate an app and pull the user back.
        guard !agentBusy, demo || acting else { return }
        guard let d = displayForWindow(id), var destination = workspaces[d.id] else { return }
        lastFocusedWindow = id
        destination.reveal(id, viewportWidth: viewport(d).width)
        workspaces[d.id]?.focus = id
        animateStrip(displayID: d.id, to: destination.offset) { [weak self] in
            guard let self, self.managing, let window = self.windows[id] else { return }
            self.bridge.focus(window)
        }
    }
    func navigate(_ delta: Int) {
        guard let w = workspaces[activeDisplay], let d = displays.first(where: { $0.id == activeDisplay }) else {
            return
        }
        if delta > 0, w.focus.flatMap({ w.columnIndex($0) }) == w.columns.count - 1 {
            showDesktop()
            return
        }
        if delta < 0, let last = w.columns.last?.tiles.first?.id, let rect = w.frames(in: viewport(d))[last],
            rect.maxX <= viewport(d).minX
        {
            focus(last)
            return
        }
        guard let id = w.focus, let next = w.neighbor(of: id, direction: delta) else { return }
        focus(next)
    }
    func focusOrdinal(_ index: Int) {
        guard let ids = workspaces[activeDisplay]?.windowIDs, ids.indices.contains(index) else { return }
        focus(ids[index])
    }
    func move(_ source: String, to target: String, placement: Placement) {
        guard !agentBusy else { return }
        guard let origin = displayForWindow(source), let destination = displayForWindow(target) else { return }
        if source.hasPrefix("desktop:") && origin.id != destination.id {
            status = "Each display has its own Desktop slot."
            return
        }
        if origin.id != destination.id {
            if (placement == .above || placement == .below), let c = workspaces[destination.id]?.columnIndex(target),
                workspaces[destination.id]!.columns[c].tiles.count
                    >= (workspaces[destination.id]!.columns[c].gridRows ?? 3)
            {
                status = maxStackMessage
                return
            }
            transfer(source, to: destination.id, applyNow: false)
        }
        guard workspaces[destination.id]?.move(source, to: target, placement: placement) == true else {
            status = maxStackMessage
            return
        }
        dropTarget = nil
        draggedID = nil
        focus(source)
    }
    func transfer(_ id: String, to displayID: String, applyNow: Bool = true) {
        guard !id.hasPrefix("desktop:"), let origin = displayForWindow(id), origin.id != displayID,
            displays.contains(where: { $0.id == displayID }), let before = workspaces[origin.id],
            let tile = workspaces[origin.id]?.remove(id)
        else { return }
        let width = windows[id]?.frame.width ?? 560
        displayMemory.noteTransfer(id, from: origin.id, in: before, to: displayID)
        expected.removeValue(forKey: id)
        offStrip.remove(id)
        displayIntentUntil = max(displayIntentUntil, Date().addingTimeInterval(1.2))
        workspaces[displayID, default: Workspace()].columns.append(Column(width: width, tiles: [tile]))
        if applyNow {
            focus(id)
            status =
                "Moved \(windows[id]?.appName ?? "window") to \(displays.first{$0.id==displayID}?.name ?? "display")"
        }
    }
    func unstack(_ id: String) {
        guard let d = displayForWindow(id) else { return }
        workspaces[d.id]?.extract(id)
        focus(id)
    }
    func width(_ id: String, _ value: Double, reveal: Bool = true) {
        guard let d = displayForWindow(id) else { return }
        workspaces[d.id]?.setWidth(id, value)
        if reveal { workspaces[d.id]?.reveal(id, viewportWidth: viewport(d).width) }
        apply()
        saveLayout()
    }
    func height(_ id: String, _ value: Double) {
        guard let d = displayForWindow(id) else { return }
        workspaces[d.id]?.setHeight(id, height: value, availableHeight: viewport(d).height)
        apply()
        saveLayout()
    }
    func togglePerformance(_ displayID: String? = nil) {
        let target = displayID ?? pointerDisplay()?.id ?? displays.first?.id
        guard let target else { return }
        performanceDisplay = performanceDisplay == target ? nil : target
        guideDisplay = nil
        commandDisplay = nil
        if enabled, let d = displays.first(where: { $0.id == target }), let id = workspaces[target]?.focus {
            workspaces[target]?.reveal(id, viewportWidth: viewport(d).width)
        }
        apply()
    }
    /// The guide shares Performance's place beside the rail; one of them shows at a time.
    func toggleGuide(_ displayID: String? = nil) {
        let target = displayID ?? pointerDisplay()?.id ?? displays.first?.id
        guard let target else { return }
        guideDisplay = guideDisplay == target ? nil : target
        performanceDisplay = nil
        commandDisplay = nil
        if enabled, let d = displays.first(where: { $0.id == target }), let id = workspaces[target]?.focus {
            workspaces[target]?.reveal(id, viewportWidth: viewport(d).width)
        }
        apply()
    }
    func toggleCommands(_ displayID: String? = nil) {
        performanceDisplay = nil
        guideDisplay = nil
        let d = displayID ?? activeDisplay
        commandDisplay = commandDisplay == d ? nil : d
        if let display = displays.first(where: { $0.id == d }), let id = workspaces[d]?.focus {
            workspaces[d]?.reveal(id, viewportWidth: viewport(display).width)
        }
        apply()
    }
    func close(_ id: String) {
        if demo {
            if let d = displayForWindow(id) { _ = workspaces[d.id]?.remove(id) }
            windows.removeValue(forKey: id)
            layoutChanged?()
        } else if let w = windows[id] {
            bridge.close(w)
            scheduleRefresh()
        }
    }
    func exclude(_ id: String) {
        guard let w = windows[id] else { return }
        excludedBundles.insert(w.bundleID)
        UserDefaults.standard.set(Array(excludedBundles), forKey: "excludedBundles")
        for other in windows.values where other.bundleID == w.bundleID {
            if let original = originals[other.id] {
                _ = bridge.minimize(other, false)
                _ = bridge.setFrame(other, original.frame)
                originals.removeValue(forKey: other.id)
            }
            parked.remove(other.id)
        }
        saveRecovery()
        refresh(force: true)
    }
    deinit {
        if let nativeMouseMonitor { NSEvent.removeMonitor(nativeMouseMonitor) }
        CGDisplayRemoveReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
    }
    func revealFinder() { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser) }
    func revealTrash() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
    }
}
/// Runs on the registering (main) run loop for each display reconfiguration stage, including the
/// begin stage that precedes the Space notifications of a display coming up.
private func displayReconfigured(
    _ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let controller = Unmanaged<KolomController>.fromOpaque(context).takeUnretainedValue()
    if Thread.isMainThread {
        controller.noteDisplayReconfiguration()
    } else {
        DispatchQueue.main.async { controller.noteDisplayReconfiguration() }
    }
}
