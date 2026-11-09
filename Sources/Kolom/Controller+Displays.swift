import AppKit
import ApplicationServices
import SwiftUI
import KolomCore

/// Displays, Spaces, sleep and the display staircase.
extension KolomController {
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
    func suspend(_ reason: SuspensionReason) {
        guard enabled, suspension != reason else { return }
        animation?.invalidate()
        animation = nil
        commandDisplay = nil
        // A drag interrupted by the suspension never delivers its mouse-up.
        interacting = false
        suspension = reason
        flushLayout()
        record("suspend", ["reason": reason.rawValue])
        status = "Waiting while the Mac is asleep, locked or switched to another user"
        layoutChanged?()
        writeLiveState()
    }
    func resume() {
        guard suspension != nil else { return }
        record("resume", ["from": suspension!.rawValue])
        suspension = nil
        expected = [:]
        // Windows can take a while to be listed again after wake or unlock.
        holdSavedWindows()
        scheduleArrangement()
        status = "Managing this Space · pause restores the original window positions"
        // Spaces may have changed while asleep or locked.
        syncSpaces()
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
        // Knowing which Space each display shows: swap that display's strip.
        if syncSpaces() != nil {
            if Set(realDisplays().map(\.id)) != Set(displays.map(\.id)) { screensChanged() }
            if managing { scheduleRefresh() }
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
    /// Brings each display's strip in line with the Space it shows: a display that
    /// switched Space shows that Space's strip, and its previous strip waits. Returns
    /// nil when macOS does not say which Space is shown (Kolom then pauses on a Space
    /// change, as before 0.2.14).
    @discardableResult func syncSpaces() -> Bool? {
        guard enabled, let shown = Spaces.shown() else { return nil }
        let live = Set(realDisplays().map(\.id))
        let swapped = strips.update(shown.filter { live.contains($0.key) }, workspaces: &workspaces)
        guard !swapped.isEmpty else { return true }
        record(
            "space",
            [
                "shown": strips.shown.mapValues { Int($0) }, "swapped": Array(swapped).sorted(),
                "waiting": strips.elsewhere.count,
            ])
        for d in displays where swapped.contains(d.id) {
            workspaces[d.id]?.clampOffset(viewportWidth: viewport(d).width, desktopTail: true)
            if commandDisplay == d.id { commandDisplay = nil }
        }
        // The strip shown is new to the screen: place its windows afresh.
        expected = [:]
        saveLayout()
        layoutChanged?()
        return true
    }

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
    /// Applies the display staircase while managing independent displays, or puts the
    /// desk back. Returns true when it changed the display arrangement (macOS then
    /// reports a display change of its own).
    @discardableResult func reconcileArrangement() -> Bool {
        arrangementTask?.cancel()
        arrangementTask = nil
        guard enabled, !restoring else { return false }
        guard isolateDisplays else {
            if restoreArrangement() {
                noteDisplayReconfiguration()
                return true
            }
            return false
        }
        // Suspended (asleep, locked): keep what is applied; resume reconciles.
        guard suspension == nil else { return false }
        let changed = arrangement.reconcile()
        if changed {
            record("staircase", ["applied": true])
            noteDisplayReconfiguration()
        }
        let maps = arrangement.pointerMaps
        pointerRouter.update(technical: maps.technical, desk: maps.desk)
        writeLiveState()
        return changed
    }
    /// Returns true when display geometry changed.
    @discardableResult func restoreArrangement() -> Bool {
        arrangementTask?.cancel()
        arrangementTask = nil
        pointerRouter.update(technical: [:], desk: [:])
        let changed = arrangement.restore()
        if changed { record("staircase", ["restored": true]) }
        return changed
    }
    /// A window frame in desk coordinates, for recovery records.
    func deskFrame(_ frame: CGRect) -> CGRect {
        arrangement.isolated ? deskRect(frame, technical: arrangement.applied, desk: arrangement.desk) : frame
    }
    func scheduleSpaceRecheck() {
        let settled = max(displayIntentUntil, lastSpaceChange.addingTimeInterval(0.5))
        let delay = max(0.1, settled.timeIntervalSinceNow + 0.1)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.recheckDeferredSpaceChange()
        }
    }
    func pauseForSpaceChange(_ detail: String) {
        pauseReason = "paused after a Space change; choose Enable to manage this Space"
        let stamp = ISO8601DateFormatter()
        pauseDetail =
            detail + " · last display reconfiguration "
            + (lastDisplayReconfiguration == .distantPast ? "never" : stamp.string(from: lastDisplayReconfiguration))
            + " · displays " + realDisplays().map { "\($0.name) \(Int($0.frame.width))x\(Int($0.frame.height))" }
            .joined(separator: ", ")
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
            pauseForSpaceChange(
                "unexplained Space change at \(ISO8601DateFormatter().string(from: at)), no display change near it")
            return
        }
        spaceChangeUnexplainedAt = nil
        let listed = Set(bridge.discover().map(\.id))
        let lost = displays.lazy.compactMap { d -> String? in
            let ids = (self.workspaces[d.id]?.windowIDs ?? []).filter { id in
                self.windows[id].map {
                    !self.bridge.unresponsivePIDs.contains($0.pid) && !self.bridge.isDestroyed($0.element)
                } ?? false
            }
            let shown = ids.filter(listed.contains).count
            return !ids.isEmpty && shown * 2 < ids.count
                ? "\(d.name) still lists \(shown) of its \(ids.count) managed windows" : nil
        }.first
        if let lost { pauseForSpaceChange(lost) } else { scheduleRefresh() }
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
    func handleSessionChanged() {
        if inactiveSession.isEmpty, suspension == .sessionInactive {
            resume()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh(force: true) }
        }
    }
    func screensChanged() {
        guard enabled else { return }
        record("screens", ["displays": realDisplays().map { "\($0.name) \(Int($0.frame.width))x\(Int($0.frame.height))" }])
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
            // A display that connected shows a Space; reconnects renumber them.
            self.syncSpaces()
            self.commandDisplay = nil
            // Side panels stay open unless their display is gone; the staircase
            // itself reports a display change.
            let ids = Set(connected.map(\.id))
            if let id = self.performanceDisplay, !ids.contains(id) {
                self.performanceDisplay = nil
                self.diskMap = nil
            }
            if let id = self.guideDisplay, !ids.contains(id) { self.guideDisplay = nil }
            self.activeDisplay = primary
            self.expected = [:]
            for display in connected {
                self.workspaces[display.id]?.clampOffset(viewportWidth: self.viewport(display).width, desktopTail: true)
            }
            // Arrange the displays before placing windows. Placing first and applying
            // the staircase seconds later moved every window twice on a DisplayLink
            // reconnect (display-trace, 0.2.14). Applying it reports a display change,
            // and windows are placed once, after it.
            if self.reconcileArrangement() {
                self.saveLayout()
                self.status = "Displays updated · arranging them before placing windows"
                // Should macOS not report the staircase's display change, place windows anyway.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh(force: true) }
                return
            }
            self.apply()
            self.saveLayout()
            self.refresh(force: true)
            self.status = "Displays updated · disconnected windows join the primary display and return when reconnected"
        }
        displayChangeTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
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
}
