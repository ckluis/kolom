import AppKit
import ApplicationServices
import SwiftUI
import KolomCore

/// Starting, pausing and recovering a session; window access.
extension KolomController {
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
        guard !SmokeMode.active else {
            status = "Smoke test · window management is off"
            return
        }
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
        // Manage the Space each display shows now; another Space waits instead of pausing.
        if let shown = Spaces.current() {
            spaces.start(shown.mapValues { .init(current: $0.current, all: $0.all) }, displays: displays.map(\.id))
            record("space", ["started": spaces.managed.mapValues { Int($0) }])
        } else {
            spaces.reset()
        }
        // Enabled while asleep or locked (or with a missed wake): stay suspended.
        if !inactiveSession.isEmpty { suspend(.sessionInactive) }
        refresh(force: true)
        if enabled { status = "Managing this Space · pause restores the original window positions" }
        reconcileArrangement()
        layoutChanged?()
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
        if enabled && logged { logPause(pauseReason ?? "paused from the menu or a command", detail: pauseDetail) }
        pauseDetail = nil
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
        spaces.reset()
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
            "version": BuildInfo.version, "build": BuildInfo.label,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            try? data.write(to: storage.appendingPathComponent("startup-hold.json"), options: .atomic)
        }
    }
}
