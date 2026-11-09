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
    /// The Disk Map, a wide panel beside Performance on the same display.
    @Published var diskMap: DiskMapModel.Target?
    var diskMapShown: Bool { diskMap != nil && performanceDisplay != nil }
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
    var scrollDelta: Double = 0
    var scrollDisplay: String?
    var scrollScheduled = false
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
                // The window the press lands on, focused or not: dragging a background
                // window by its title bar is the usual way to move one, and the press
                // happens before it becomes focused. Toolbars with tabs (cmux, Safari)
                // reach well below a plain 36-point title bar.
                self.nativeGestureWindow = self.bridge.windowUnder(point).flatMap { hit in
                    guard
                        let id = self.windows.first(where: { entry in
                            windowServerNumber(fromID: entry.key, pid: entry.value.pid) == hit.number
                        })?.key, !self.offStrip.contains(id)
                    else { return nil }
                    let frame = hit.frame
                    let border = point.x < frame.minX + 12 || point.x > frame.maxX - 12 || point.y > frame.maxY - 12
                    let top = point.y < frame.minY + min(120, max(36, frame.height * 0.15))
                    return border || top ? id : nil
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
    var permissionPaneName: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
            ? "Device Control and Data Access" : "Accessibility"
    }
    /// Why the last pause happened, appended to the final restoration status.
    var pauseReason: String?
    /// Which rule paused and what it saw; logged only, never shown in the status.
    var pauseDetail: String?
    var pauseLogURL: URL { storage.appendingPathComponent("pause-log.json") }
    /// Windows that left a strip, with where they were: one that is listed again goes
    /// back to its stack instead of the end of the strip.
    var departed: [String: (display: String, slot: WindowSlot, time: Date)] = [:]
    /// How long a departed window's place is kept: long enough for a KVM switch to
    /// another computer, a lunch break or a night with the screen locked.
    static let departedMemory: TimeInterval = 12 * 60 * 60
    var windowEventsURL: URL { storage.appendingPathComponent("window-events.json") }
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
    /// Daily check for a newer release on GitHub; reported in live state for agents.
    let updates = UpdateChecker()
    var arrangementTask: DispatchWorkItem?
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
    var inactiveSession: Set<SessionFlag> = []
    /// A Space change arrived inside a display-intent window (Kolom's own
    /// transfers and display changes can post one). Refresh waits until it has
    /// been re-checked.
    var spaceChangeDeferred = false
    /// The strips of Spaces not shown (each display × Space has its own strip).
    var strips = SpaceStrips()
    var stripsURL: URL { storage.appendingPathComponent("space-strips.json") }
    /// Display and Space events with millisecond times, for diagnosing flicker.
    var trace: [[String: Any]] = []
    var traceWrite: DispatchWorkItem?
    /// Until then, refresh and apply are traced too (a display or Space event is recent).
    var traceDetailUntil = Date.distantPast
    /// Records the app dropped because their window was on another Space. When
    /// the user arrives on that Space while Kolom is paused, unreachable ones
    /// are rescued.
    var droppedOtherSpace: [String: OriginalWindow] = [:]
    /// A Space change explained by display reconfiguration that macOS reports just
    /// after it (displays bring their own Spaces) is not the user's.
    var spaceChangeUnexplainedAt: Date?
    var spaceChangeDeferredSince = Date.distantPast
    var lastSpaceChange = Date.distantPast
    var lastDisplayReconfiguration = Date.distantPast
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
        // Switch strips before listing windows: a Space notification can arrive after
        // a refresh has already seen the new Space's windows.
        syncSpaces()
        let retained = windows
        let wasUnresponsive = bridge.unresponsivePIDs
        let discovered = bridge.discover(retaining: retained, adoptMinimized: true).filter {
            !excludedBundles.contains($0.bundleID)
        }
        if Date() < traceDetailUntil {
            // Windows not where Kolom last put them: macOS (or the user) moved them.
            let moved = discovered.filter { w in
                expected[w.id].map { abs($0.minX - w.frame.minX) > 2 || abs($0.minY - w.frame.minY) > 2 } ?? false
            }.count
            record("refresh", ["listed": discovered.count, "movedSinceKolom": moved])
        }
        // An app that answers again missed the moves skipped while it was busy.
        let recovered = wasUnresponsive.subtracting(bridge.unresponsivePIDs)
        // A window is closed when the WindowServer no longer has it. Accessibility alone
        // reported every window closed as the screen locked (2026-11-09 15:28), which
        // dropped them all and lost cmux's home display across a KVM switch.
        let serverWindows = bridge.windowServerNumbers()
        func stillListed(_ window: NativeWindow) -> Bool {
            windowServerNumber(fromID: window.id, pid: window.pid).map(serverWindows.contains) ?? false
        }
        func isOpen(_ window: NativeWindow) -> Bool {
            NSRunningApplication(processIdentifier: window.pid) != nil
                && (bridge.unresponsivePIDs.contains(window.pid) || !bridge.isDestroyed(window.element)
                    || stillListed(window))
        }
        let discoveredIDs = Set(discovered.map(\.id))
        // Listed now means on a Space shown: such a window leaves any waiting strip.
        strips.claim(discoveredIDs)
        let waiting = strips.elsewhere
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
            hidden: offStrip.union(away).union(waiting).union(
                retained.values.filter { bridge.unresponsivePIDs.contains($0.pid) }.map(\.id)), isAlive: isOpen)
        // Waiting windows that closed leave their strips.
        strips.drop(waiting.subtracting(fresh.keys))
        absentWindows = Set(fresh.keys).subtracting(discoveredIDs)
        for (id, window) in retained where fresh[id] == nil && NSRunningApplication(processIdentifier: window.pid) != nil {
            let reason =
                bridge.isDestroyed(window.element) && !stillListed(window)
                ? "closed (the WindowServer no longer has it)"
                : previouslyAbsent.contains(id)
                    ? "missing from Accessibility past the 10 s grace" : "not listed and not alive"
            logWindowEvent("dropped", id: id, detail: reason)
        }
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
                        if workspaces[display.id]?.accommodateWindowWidth(
                            w.id, actualWidth: w.frame.width, maxWidth: maxColumnWidth(display)) == true
                        {
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
            if NSRunningApplication(processIdentifier: w.pid) == nil || (bridge.isDestroyed(w.element) && !stillListed(w)) {
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
        departed = departed.filter { Date().timeIntervalSince($0.value.time) < Self.departedMemory }
        let previouslyAssigned = Set(workspaces.values.flatMap(\.windowIDs))
        var newlyRevealed: String?
        for d in displays {
            var ids = workspaces[d.id]?.windowIDs.filter { allIDs.contains($0) } ?? []
            let assigned = Set(workspaces.values.flatMap(\.windowIDs))
            // Windows waiting on a Space not shown keep their own strip.
            for w in found where !assigned.contains(w.id) && !waiting.contains(w.id) {
                let target = launchTargets[w.pid].flatMap { $0.expires > Date() ? $0.display : nil }
                // A window coming back belongs on the display it left, if that is still here.
                let home = departed[w.id].flatMap { entry in displays.contains { $0.id == entry.display } ? entry.display : nil }
                let destination =
                    target ?? home
                    ?? (!force && displays.contains(where: { $0.id == activeDisplay }) ? activeDisplay : nil)
                    ?? bestDisplay(for: w.frame)?.id
                if destination == d.id { ids.append(w.id) }
            }
            var space = workspaces[d.id] ?? Workspace()
            let before = space
            space.reconcile(ids, defaultWidth: min(640, max(300, viewport(d).width * 0.55)))
            for id in before.windowIDs where !space.windowIDs.contains(id) {
                if let slot = before.slot(of: id) { departed[id] = (d.id, slot, Date()) }
            }
            var returnedHere: Set<String> = []
            for id in space.windowIDs where !before.windowIDs.contains(id) {
                guard let entry = departed[id], entry.display == d.id else { continue }
                departed[id] = nil
                if Date().timeIntervalSince(entry.time) < Self.departedMemory, space.restore(id, to: entry.slot) {
                    // Back where it was: not a new window, so the strip does not jump to it.
                    returnedHere.insert(id)
                    logWindowEvent(
                        "returned", id: id,
                        detail: "back in its place after \(Int(Date().timeIntervalSince(entry.time))) s away")
                }
            }
            if !force, let opened = ids.last(where: { !previouslyAssigned.contains($0) && !returnedHere.contains($0) }) {
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
    func apply(reflow: Bool = true) {
        var traceWrites = 0
        let traceStart = Date()
        defer {
            if traceWrites > 0, Date() < traceDetailUntil {
                record("apply", ["writes": traceWrites, "ms": Int(Date().timeIntervalSince(traceStart) * 1000)])
            }
        }
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
            guard var space = workspaces[d.id] else { continue }
            if space.fitColumns(maxWidth: maxColumnWidth(d)) {
                space.clampOffset(viewportWidth: area.width, desktopTail: true)
                workspaces[d.id] = space
                saveLayout()
            }
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
                    traceWrites += 1
                    if bridge.setFrame(w, physical, resize: resize) {
                        expected[id] = physical
                        geometryFeedback.recordWrite(id, frame: physical, time: Date().timeIntervalSinceReferenceDate)
                    }
                }
            }
        }
        if let error = bridge.lastError, !bridge.writeFailures.isEmpty {
            status = error
            showingWriteError = true
        } else if showingWriteError, enabled {
            // The refusal resolved; do not leave it on the status line.
            showingWriteError = false
            status = "Managing this Space · pause restores the original window positions"
        }
    }
    var showingWriteError = false
    deinit {
        if let nativeMouseMonitor { NSEvent.removeMonitor(nativeMouseMonitor) }
        CGDisplayRemoveReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
    }
}
/// Runs on the registering (main) run loop for each display reconfiguration stage, including the
/// begin stage that precedes the Space notifications of a display coming up.
private func displayReconfigured(
    _ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let controller = Unmanaged<KolomController>.fromOpaque(context).takeUnretainedValue()
    let raw = flags.rawValue
    if Thread.isMainThread {
        controller.recordReconfiguration(display, raw)
        controller.noteDisplayReconfiguration()
    } else {
        DispatchQueue.main.async {
            controller.recordReconfiguration(display, raw)
            controller.noteDisplayReconfiguration()
        }
    }
}
