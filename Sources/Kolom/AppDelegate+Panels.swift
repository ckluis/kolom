import AppKit
import ApplicationServices
import Combine
import SwiftUI
import KolomCore

/// Rails, Performance, the Disk Map, the guide and resize handles on screen.
extension AppDelegate {
    func syncAppearance() {
        if model.enabled {
            appearance.apply(UserDefaults.standard.string(forKey: "kolomTheme") ?? "Light")
        } else {
            appearance.restore()
        }
    }
    func syncPanels() {
        syncAppearance()
        syncPerformancePanel()
        syncDiskMapPanel()
        syncGuidePanel()
        if model.enabled && recoveryHelper?.isRunning != true {
            let helper = Process()
            helper.executableURL = Bundle.main.executableURL
            helper.arguments = ["--recovery-watchdog", String(getpid())]
            do {
                try helper.run()
                recoveryHelper = helper
            } catch {
                model.status = "Recovery helper could not start · quit restoration remains available"
            }
        }
        if !model.enabled && model.originals.isEmpty {
            recoveryHelper?.terminate()
            recoveryHelper = nil
        }
        if model.managing && !registered {
            hotkeys.register()
            stripInput.start()
            registered = true
            if !hotkeys.failures.isEmpty {
                model.status =
                    "Shortcut unavailable: " + hotkeys.failures.joined(separator: ", ") + ". Use the rail or menu bar."
            }
        }
        // Paused or suspended (asleep, locked, switched away): no rails, shortcuts or gestures.
        if !model.managing {
            palette?.orderOut(nil)
            palette = nil
            hotkeys.unregister()
            stripInput.stop()
            resizePanels.values.forEach { $0.close() }
            resizePanels = [:]
            registered = false
            railPanels.values.forEach { $0.close() }
            railPanels = [:]
            commandPanels.values.forEach { $0.close() }
            commandPanels = [:]
            return
        }
        let liveDisplays = Set(model.displays.map(\.id))
        for id in Array(railPanels.keys) where !liveDisplays.contains(id) {
            railPanels.removeValue(forKey: id)?.close()
        }
        for id in Array(commandPanels.keys) where !liveDisplays.contains(id) {
            commandPanels.removeValue(forKey: id)?.close()
        }
        for d in model.displays {
            guard let screen = d.screen else { continue }
            let panel = railPanels[d.id] ?? makeRail()
            if railPanels[d.id] == nil {
                panel.contentView = NSHostingView(rootView: RailView(model: model, displayID: d.id))
            }
            panel.setFrame(
                NSRect(
                    x: screen.visibleFrame.minX, y: screen.visibleFrame.minY, width: 48,
                    height: screen.visibleFrame.height), display: true)
            panel.navigate = { [weak model] delta in
                model?.activeDisplay = d.id
                model?.navigate(delta)
            }
            panel.orderFrontRegardless()
            railPanels[d.id] = panel
            if model.commandDisplay == d.id {
                let commands = commandPanels[d.id] ?? makePanel()
                if commandPanels[d.id] == nil {
                    commands.contentView = NSHostingView(rootView: CommandsView(model: model, displayID: d.id))
                }
                commands.setFrame(
                    NSRect(
                        x: screen.visibleFrame.minX + 48, y: screen.visibleFrame.minY, width: 224,
                        height: screen.visibleFrame.height), display: true)
                commands.orderFrontRegardless()
                commandPanels[d.id] = commands
            } else {
                commandPanels.removeValue(forKey: d.id)?.close()
            }
        }
        syncResizeHandles()
    }
    /// The Disk Map sits beside Performance, on its display, as wide as the
    /// controller reserves; closing either closes it and frees its scan.
    func syncDiskMapPanel() {
        guard model.diskMapShown, let target = model.diskMap, let id = model.performanceDisplay,
            let display = model.displays.first(where: { $0.id == id })
        else {
            diskMapPanel?.close()
            diskMapPanel = nil
            diskMapModel?.close()
            diskMapModel = nil
            if model.performanceDisplay == nil, model.diskMap != nil { model.diskMap = nil }
            return
        }
        if diskMapModel?.target != target {
            diskMapModel?.close()
            diskMapPanel?.close()
            diskMapPanel = nil
            let map = DiskMapModel(target: target, storage: model.storage)
            map.requestClose = { [weak model] in model?.closeDiskMap() }
            diskMapModel = map
            let panel = DiskMapPanel(
                contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            configure(panel)
            panel.title = "Disk Map"
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 3)
            panel.dismiss = { [weak model] in model?.closeDiskMap() }
            panel.contentView = NSHostingView(rootView: DiskMapView(model: map))
            diskMapPanel = panel
            map.start()
        }
        let top = Double(NSScreen.screens.first?.frame.maxY ?? 0)
        let area = display.frame
        let left = area.minX + 48 + min(model.performanceWidth, max(400, area.width - 64))
        diskMapPanel?.setFrame(
            NSRect(x: left, y: top - area.maxY, width: model.diskMapWidth(display), height: area.height),
            display: true)
        if diskMapPanel?.isVisible == false {
            diskMapPanel?.orderFrontRegardless()
            diskMapPanel?.makeKey()
        }
    }
    func syncPerformancePanel() {
        guard let id = model.performanceDisplay, let display = model.displays.first(where: { $0.id == id }) else {
            performancePanel?.close()
            performancePanel = nil
            performancePanelDisplay = nil
            return
        }
        if performancePanelDisplay != id {
            performancePanel?.close()
            performancePanel = nil
        }
        if performancePanel == nil {
            let panel = PerformancePanel(
                contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            configure(panel)
            panel.title = "Performance"
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 3)
            panel.dismiss = { [weak model] in
                model?.performanceDisplay = nil
                model?.apply()
            }
            panel.contentView = NSHostingView(rootView: PerformanceDashboard(close: panel.dismiss!))
            performancePanel = panel
            performancePanelDisplay = id
        }
        let top = Double(NSScreen.screens.first?.frame.maxY ?? 0)
        let area = display.frame
        let width = min(model.performanceWidth, max(400, area.width - 64))
        performancePanel?.setFrame(
            NSRect(x: area.minX + 48, y: top - area.maxY, width: width, height: area.height), display: true)
        performancePanel?.orderFrontRegardless()
    }
    func syncGuidePanel() {
        guard let id = model.guideDisplay, let display = model.displays.first(where: { $0.id == id }) else {
            guidePanel?.close()
            guidePanel = nil
            guidePanelDisplay = nil
            return
        }
        if guidePanelDisplay != id {
            guidePanel?.close()
            guidePanel = nil
        }
        if guidePanel == nil {
            let panel = PerformancePanel(
                contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            configure(panel)
            panel.title = "Kolom Guide"
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 3)
            panel.dismiss = { [weak model] in
                model?.guideDisplay = nil
                model?.apply()
            }
            let actions = GuideActions(
                requestAccess: { [weak self] in self?.model.requestAccess() },
                checkAccess: { [weak self] in _ = self?.model.checkAccess() },
                start: { [weak self] in
                    guard let self else { return }
                    self.startWhenAuthorized = true
                    if self.model.checkAccess() { self.startAutomatically() } else { self.model.requestAccess() }
                },
                ask: { [weak self] text in self?.showAsk(text) },
                toggleAgent: { [weak self] in self?.toggleAgentControl() },
                agentEnabled: { [weak self] in self?.agent?.enabled == true },
                close: panel.dismiss!)
            panel.contentView = NSHostingView(rootView: GuideView(model: model, actions: actions))
            guidePanel = panel
            guidePanelDisplay = id
        }
        let top = Double(NSScreen.screens.first?.frame.maxY ?? 0)
        let area = display.frame
        let width = min(model.performanceWidth, max(400, area.width - 64))
        guidePanel?.setFrame(
            NSRect(x: area.minX + 48, y: top - area.maxY, width: width, height: area.height), display: true)
        guidePanel?.orderFrontRegardless()
    }
    func syncResizeHandles() {
        var needed = Set<String>()
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        for d in model.displays {
            guard let space = model.workspaces[d.id] else { continue }
            let area = model.viewport(d)
            let frames = space.frames(in: area)
            for col in space.columns {
                guard let tile = col.tiles.first, let rect = frames[tile.id] else { continue }
                let key = "width-" + col.id.uuidString
                let tracking = (resizePanels[key]?.contentView as? ResizeHandle)?.isDragging ?? false
                if let edge = columnResizeHandleFrame(rect, viewport: area, tracking: tracking) {
                    needed.insert(key)
                    let panel = resizePanels[key] ?? makeRail()
                    let handle = (panel.contentView as? ResizeHandle) ?? ResizeHandle()
                    handle.vertical = false
                    handle.value = { [weak model] in
                        guard let model, let c = model.workspaces[d.id]?.columnIndex(tile.id) else { return col.width }
                        return model.workspaces[d.id]!.columns[c].width
                    }
                    handle.began = { [weak model] in model?.beginResize() }
                    handle.changed = { [weak model] value in model?.width(tile.id, value, reveal: false) }
                    handle.ended = { [weak model] in model?.endResize() }
                    handle.setAccessibilityElement(true)
                    handle.setAccessibilityRole(.slider)
                    handle.setAccessibilityLabel("Resize shared column width")
                    handle.sample = { [weak model] phase, start, delta in
                        model?.recordResize(tile.id, axis: "width", phase: phase, start: start, delta: delta)
                    }
                    if panel.contentView !== handle { panel.contentView = handle }
                    panel.setFrame(
                        NSRect(x: edge.minX, y: top - edge.maxY, width: edge.width, height: edge.height), display: true)
                    if !model.interacting { panel.orderFrontRegardless() }
                    resizePanels[key] = panel
                }
                for tile in col.tiles.dropLast() {
                    guard let rect = frames[tile.id], rect.minX < area.maxX, rect.maxX > area.minX else { continue }
                    let key = "height-" + col.id.uuidString + tile.id
                    needed.insert(key)
                    let panel = resizePanels[key] ?? makeRail()
                    let handle = (panel.contentView as? ResizeHandle) ?? ResizeHandle()
                    handle.vertical = true
                    handle.value = { [weak model] in
                        Double(model?.workspaces[d.id]?.frames(in: area)[tile.id]?.height ?? rect.height)
                    }
                    handle.began = { [weak model] in model?.beginResize() }
                    handle.changed = { [weak model] value in model?.height(tile.id, value) }
                    handle.ended = { [weak model] in model?.endResize() }
                    handle.setAccessibilityElement(true)
                    handle.setAccessibilityRole(.slider)
                    handle.setAccessibilityLabel("Resize stacked window height")
                    handle.sample = { [weak model] phase, start, delta in
                        model?.recordResize(tile.id, axis: "height", phase: phase, start: start, delta: delta)
                    }
                    if panel.contentView !== handle { panel.contentView = handle }
                    let left = max(area.minX, rect.minX)
                    let right = min(area.maxX, rect.maxX)
                    panel.setFrame(
                        NSRect(x: left, y: top - rect.maxY - 13, width: right - left, height: 10), display: true)
                    if !model.interacting { panel.orderFrontRegardless() }
                    resizePanels[key] = panel
                }
            }
        }
        for key in Array(resizePanels.keys) where !needed.contains(key) {
            resizePanels.removeValue(forKey: key)?.close()
        }
        if !model.interacting { railPanels.values.forEach { $0.orderFrontRegardless() } }
    }
    func makeRail() -> RailPanel {
        let p = RailPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configure(p)
        return p
    }
    func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configure(p)
        return p
    }
    func configure(_ panel: NSPanel) {
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
    }
}
