import AppKit
import ApplicationServices
import SwiftUI
import KolomCore

/// What the rail, shortcuts and agents ask of the strip.
extension KolomController {
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
    func move(_ source: String, to target: String, placement requested: Placement) {
        guard !agentBusy else { return }
        guard let origin = displayForWindow(source), let destination = displayForWindow(target) else { return }
        // Dropped onto a full column: place it beside that column instead of refusing,
        // so a drag always lands somewhere.
        var placement = requested
        if placement == .above || placement == .below, let space = workspaces[destination.id],
            let c = space.columnIndex(target), space.columnIndex(source) != c,
            space.columns[c].tiles.count >= (space.columns[c].gridRows ?? 3)
        {
            placement = .after
            status = "That column holds three windows · placed beside it"
        }
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
    func revealFinder() { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser) }
    func revealTrash() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
    }
}
