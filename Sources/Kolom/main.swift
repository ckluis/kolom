import AppKit
import SwiftUI
import KolomCore
import Combine

final class RailPanel: NSPanel {
    var navigate: ((Int) -> Void)?
    var lastScroll = Date.distantPast
    override var canBecomeKey: Bool { false }
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), abs(event.scrollingDeltaX) > 3 {
            if Date().timeIntervalSince(lastScroll) > 0.2 {
                navigate?(event.scrollingDeltaX < 0 ? 1 : -1)
                lastScroll = Date()
            }
        } else {
            super.scrollWheel(with: event)
        }
    }
}
final class PerformancePanel: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss?() } else { super.keyDown(with: event) }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleIsolateDisplays) { item.state = model.isolateDisplays ? .on : .off }
        return true
    }
    let model = KolomController()
    let appearance = DesktopAppearance()
    var themeObserver: AnyCancellable?
    var permissionObserver: AnyCancellable?
    let startup = StartupSequence()
    var startupInProgress: Bool { startup.inProgress }
    var startWhenAuthorized: Bool {
        get { startup.requested }
        set { startup.requested = newValue }
    }
    let hotkeys = Hotkeys()
    let stripInput = StripInput()
    var resizePanels: [String: NSPanel] = [:]
    var palette: NSPanel?
    var askPanel: NSPanel?
    var askModel: AskModel?
    var statusItem: NSStatusItem!
    var railPanels: [String: RailPanel] = [:]
    var commandPanels: [String: NSPanel] = [:]
    var performancePanel: PerformancePanel?
    var performancePanelDisplay: String?
    var guidePanel: PerformancePanel?
    var guidePanelDisplay: String?
    var registered = false
    var recoveryHelper: Process?
    var agent: AgentControl?
    var agentWasEnabled = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMenu()
        agent = AgentControl(model: model)
        model.showPalette = { [weak self] in self?.openPalette() }
        model.chooseApp = { [weak self] id in self?.chooseApp(on: id) }
        themeObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).sink {
            [weak self] _ in self?.syncAppearance()
        }
        model.layoutChanged = { [weak self] in self?.syncPanels() }
        hotkeys.action = { [weak self] id in
            guard let self, self.model.acting, !self.model.agentBusy, self.palette == nil else { return }
            // The display under the pointer is the target for ordinal shortcuts.
            let mouse = NSEvent.mouseLocation
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let point = CGPoint(x: mouse.x, y: top - mouse.y)
            if let d = self.model.displays.first(where: { $0.frame.contains(point) }) {
                self.model.activeDisplay = d.id
            }
            switch id {
            case 1: self.model.navigate(-1)
            case 2: self.model.navigate(1)
            case 3: self.model.toggleCommands()
            case 4: self.openPalette()
            case 5: self.model.showDesktop()
            case 6: self.openAsk()
            case 10...18: self.model.focusOrdinal(Int(id - 10))
            default: break
            }
        }
        stripInput.consume = { [weak self] point, dx, dy, flags in
            guard let self, self.model.acting, !self.model.interacting, !self.model.agentBusy,
                let display = self.model.displays.first(where: { $0.frame.contains(point) })
            else { return false }
            let modifier = flags.contains(.maskAlternate) || flags.contains(.maskShift)
            guard modifier ? abs(dx) + abs(dy) > 0 : abs(dx) > abs(dy) * 1.15 && abs(dx) > 0.1 else { return false }
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let cocoa = NSPoint(x: point.x, y: top - point.y)
            if self.palette?.frame.contains(cocoa) == true { return false }
            // Do not steal gestures from unrelated floating applications.
            if point.x >= display.frame.minX + 48, let app = NSWorkspace.shared.frontmostApplication,
                app.processIdentifier != getpid(),
                !self.model.windows.values.contains(where: { $0.pid == app.processIdentifier })
            {
                return false
            }
            self.model.scroll(displayID: display.id, delta: -(abs(dx) > abs(dy) ? dx : dy))
            return true
        }
        stripInput.onUnavailable = { [weak model] in
            model?.status =
                "Gesture capture is unavailable. Use rail arrows or Option Left/Right; check Kolom’s window-control permission."
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "Kolom")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        permissionObserver = model.$permissionGranted.removeDuplicates().receive(on: RunLoop.main).sink {
            [weak self] granted in
            guard let self, granted, self.startWhenAuthorized else { return }
            self.startAutomatically()
        }
        _ = model.checkAccess()
        // First launch opens the guide, which walks through access itself.
        let firstLaunch = !UserDefaults.standard.bool(forKey: "guideShown")
        if firstLaunch {
            UserDefaults.standard.set(true, forKey: "guideShown")
            model.toggleGuide()
        }
        if model.recoveryAvailable || (!model.permissionGranted && !firstLaunch) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.model.enabled, !self.startupInProgress,
                    self.model.recoveryAvailable || !self.model.permissionGranted
                else { return }
                let alert = NSAlert()
                alert.messageText =
                    self.model.recoveryAvailable
                    ? "Restore the previous Kolom session" : "Enable Kolom window management"
                alert.informativeText =
                    "Window management stays paused until window access is working and any saved session is recovered. \(self.model.permissionDetails)"
                alert.addButton(
                    withTitle: self.model.recoveryAvailable ? "Check Access and Recover" : "Check Access and Start")
                alert.addButton(withTitle: "Open Performance")
                alert.addButton(withTitle: "Later")
                NSApp.activate(ignoringOtherApps: true)
                let response = alert.runModal()
                if response == .alertSecondButtonReturn { self.model.togglePerformance() }
                if response == .alertFirstButtonReturn {
                    if self.model.checkAccess() {
                        self.startWhenAuthorized = true
                        self.startAutomatically()
                    } else {
                        self.model.bridge.requestPermission()
                    }
                }
            }
        }
    }
    func startAutomatically() {
        startup.attempt(
            authorized: model.permissionGranted, enabled: model.enabled,
            needsRecovery: model.recoveryAvailable || model.hasUnreachableWindows(),
            recover: { [weak self] complete in
                guard let self else {
                    complete(false)
                    return
                }
                self.model.restorePrevious {
                    complete(!self.model.recoveryAvailable && !self.model.restoring && self.model.originals.isEmpty)
                }
            }, enable: { [weak self] in self?.model.enable() },
            blocked: { [weak self] in
                self?.model.status = "Startup paused · some windows still need recovery"
            })
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        startWhenAuthorized = true
        if model.checkAccess() { startAutomatically() } else { model.requestAccess() }
        return false
    }
    func installMenu() {
        let main = NSMenu()
        let app = NSMenuItem()
        main.addItem(app)
        let submenu = NSMenu()
        app.submenu = submenu
        let settings = NSMenuItem(title: "Kolom Controls…", action: #selector(statusClicked), keyEquivalent: ",")
        settings.target = self
        submenu.addItem(settings)
        let performance = NSMenuItem(title: "Performance…", action: #selector(togglePerformance), keyEquivalent: "")
        performance.target = self
        submenu.addItem(performance)
        let palette = NSMenuItem(title: "Move Window…", action: #selector(moveWindow), keyEquivalent: "k")
        palette.target = self
        submenu.addItem(palette)
        submenu.addItem(.separator())
        let pause = NSMenuItem(title: "Pause and Restore", action: #selector(pauseSession), keyEquivalent: "")
        pause.target = self
        submenu.addItem(pause)
        let apart = NSMenuItem(
            title: "Keep Displays Apart While Managing", action: #selector(toggleIsolateDisplays), keyEquivalent: "")
        apart.target = self
        apart.toolTip =
            "Moves displays corner to corner while Kolom manages windows, so columns slide off any edge instead of disappearing early. The pointer still crosses as in your arrangement, which returns on pause or quit."
        submenu.addItem(apart)
        let agents = NSMenuItem(
            title: "Local Agent Commands…", action: #selector(toggleAgentControl), keyEquivalent: "")
        agents.target = self
        submenu.addItem(agents)
        submenu.addItem(.separator())
        submenu.addItem(withTitle: "Quit Kolom", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        edit.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(edit)
        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        for (title, key, selector) in [
            ("Previous Column", "\u{F702}", #selector(previousColumn)),
            ("Next Column", "\u{F703}", #selector(nextColumn)), ("Show Desktop", "d", #selector(showDesktop)),
            ("Toggle Kolom Commands", "m", #selector(toggleCommands)),
            ("Ask Kolom…", "k", #selector(openAsk)),
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self
            item.keyEquivalentModifierMask = .option
            windowMenu.addItem(item)
        }
        for i in 1...9 {
            let item = NSMenuItem(
                title: "Focus Window \(i)", action: #selector(focusOrdinal(_:)), keyEquivalent: String(i))
            item.target = self
            item.tag = i - 1
            item.keyEquivalentModifierMask = .option
            windowMenu.addItem(item)
        }
        main.addItem(windowMenuItem)
        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: "Help")
        helpItem.submenu = helpMenu
        let guide = NSMenuItem(title: "Kolom Guide", action: #selector(toggleGuide), keyEquivalent: "?")
        guide.target = self
        helpMenu.addItem(guide)
        main.addItem(helpItem)
        NSApp.helpMenu = helpMenu
        NSApp.mainMenu = main
    }
    @objc func showDesktop() {
        if let display = model.pointerDisplay() { model.activeDisplay = display.id }
        model.showDesktop()
    }
    @objc func previousColumn() { model.navigate(-1) }
    @objc func nextColumn() { model.navigate(1) }
    @objc func toggleCommands() { model.toggleCommands() }
    @objc func focusOrdinal(_ sender: NSMenuItem) { model.focusOrdinal(sender.tag) }
    @objc func moveWindow() { openPalette() }
    @objc func toggleAgentControl() {
        guard let agent else { return }
        if agent.enabled {
            agent.setEnabled(false)
            model.status = "Local agent commands disabled"
            return
        }
        let alert = NSAlert()
        alert.messageText = "Allow local agent commands?"
        alert.informativeText =
            "Programs running as your Mac user may create Terminal windows, arrange grids, and explicitly request closing Terminal windows through Kolom. Native close warnings remain in effect. No shell commands are accepted. Undo restores the arrangement and keeps new Terminal sessions open. This access lasts until disabled or Kolom quits."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            agent.setEnabled(true)
            model.status = "Local agent commands enabled for this session"
        }
    }
    @objc func togglePerformance() { model.togglePerformance() }
    @objc func toggleGuide() { model.toggleGuide() }
    @objc func toggleIsolateDisplays() { model.isolateDisplays.toggle() }
    @objc func recordScrollingTest() { agent?.startTrace() }
    @objc func pauseSession() {
        startWhenAuthorized = false
        model.pause()
    }
    @objc func enableSession() {
        startWhenAuthorized = false
        model.enable()
    }
    @objc func restoreSession() { model.restorePrevious() }
    @objc func permissionSettings() { model.requestAccess() }
    @objc func checkPermission() { _ = model.checkAccess() }
    @objc func revealApp() { model.revealRunningApp() }
    @objc func selectTheme(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.title, forKey: "kolomTheme")
        syncAppearance()
    }
    @objc func statusClicked() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        @discardableResult func item(_ title: String, _ action: Selector?, enabled: Bool = true) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.isEnabled = enabled
            menu.addItem(entry)
            return entry
        }
        item(
            "Kolom · \(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "development")",
            nil, enabled: false)
        item(model.status, nil, enabled: false)
        menu.addItem(.separator())
        if model.enabled {
            item("Pause and restore windows", #selector(pauseSession))
        } else {
            item(
                "Enable window management", #selector(enableSession),
                enabled: model.permissionGranted && !model.recoveryAvailable)
        }
        if !model.enabled {
            item("Recover windows", #selector(restoreSession), enabled: model.permissionGranted && !model.restoring)
        }
        item(model.performanceDisplay == nil ? "Performance…" : "Close performance", #selector(togglePerformance))
        item(model.guideDisplay == nil ? "Kolom Guide…" : "Close guide", #selector(toggleGuide))
        let theme = item("Appearance", nil)
        let themes = NSMenu()
        themes.autoenablesItems = false
        theme.submenu = themes
        theme.isEnabled = true
        for name in ["Light", "Dark", "Wallpaper"] {
            let option = NSMenuItem(title: name, action: #selector(selectTheme(_:)), keyEquivalent: "")
            option.target = self
            option.state = (UserDefaults.standard.string(forKey: "kolomTheme") ?? "Light") == name ? .on : .off
            themes.addItem(option)
        }
        if model.managing {
            item("Keep displays apart while managing", #selector(toggleIsolateDisplays)).state =
                model.isolateDisplays ? .on : .off
            item(
                agent?.enabled == true ? "Disable local agent commands" : "Allow local agent commands…",
                #selector(toggleAgentControl))
            item("Record scrolling isolation test (5 seconds)", #selector(recordScrollingTest))
            menu.addItem(.separator())
            item("Ask Kolom… · ⌥K", #selector(openAsk))
            item("Scroll to Desktop · ⌥D", #selector(showDesktop))
            item("Arrange focused window…", #selector(moveWindow), enabled: model.commandWindow != nil)
            item("Toggle Kolom commands · ⌥M", #selector(toggleCommands))
            let source = model.commandWindow
            let move = item("Move focused window to display", nil, enabled: source != nil)
            let destinations = NSMenu()
            destinations.autoenablesItems = false
            move.submenu = destinations
            let launch = item("Open app on display", nil)
            let launchMenu = NSMenu()
            launch.submenu = launchMenu
            launch.isEnabled = true
            for (index, display) in model.displays.enumerated() {
                let entry = NSMenuItem(title: display.name, action: #selector(moveToDisplay(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = source
                entry.tag = index
                entry.isEnabled = source != nil && model.displayForWindow(source!)?.id != display.id
                destinations.addItem(entry)
                let open = NSMenuItem(title: display.name, action: #selector(openOnDisplay(_:)), keyEquivalent: "")
                open.target = self
                open.tag = index
                launchMenu.addItem(open)
            }
        }
        menu.addItem(.separator())
        if !model.permissionGranted { item("Open window-control permission settings…", #selector(permissionSettings)) }
        item("Check window-control access", #selector(checkPermission))
        item("Reveal this Kolom app", #selector(revealApp))
        menu.addItem(.separator())
        item("Quit Kolom", #selector(NSApplication.terminate(_:))).target = NSApp
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
    @objc func moveToDisplay(_ sender: NSMenuItem) {
        guard model.displays.indices.contains(sender.tag), let id = sender.representedObject as? String else { return }
        model.transfer(id, to: model.displays[sender.tag].id)
    }
    @objc func openOnDisplay(_ sender: NSMenuItem) {
        guard model.displays.indices.contains(sender.tag) else { return }
        chooseApp(on: model.displays[sender.tag].id)
    }
    func syncAppearance() {
        if model.enabled {
            appearance.apply(UserDefaults.standard.string(forKey: "kolomTheme") ?? "Light")
        } else {
            appearance.restore()
        }
    }
    func chooseApp(on displayID: String) {
        guard model.managing else { return }
        let panel = NSOpenPanel()
        panel.title = "Open an app on this display"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.model.activeDisplay = displayID
            self.model.displayIntentUntil = max(self.model.displayIntentUntil, Date().addingTimeInterval(3))
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                DispatchQueue.main.async {
                    // Kolom may have paused or suspended while the app was opening.
                    guard self.model.managing else { return }
                    guard let app else {
                        self.model.status = "Could not open app: \(error?.localizedDescription ?? "unknown error")"
                        return
                    }
                    self.model.launchTargets[app.processIdentifier] = (displayID, Date().addingTimeInterval(20))
                    // Existing apps may reuse a window rather than create a new one.
                    if let existing = self.model.windows.values.first(where: { $0.pid == app.processIdentifier }) {
                        self.model.transfer(existing.id, to: displayID)
                        self.model.focus(existing.id)
                    }
                    self.model.scheduleRefresh()
                }
            }
        }
    }
    func syncPanels() {
        syncAppearance()
        syncPerformancePanel()
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
    func openPalette() {
        guard model.managing, palette == nil, let source = model.commandWindow else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 570, height: 480), styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: PlacementPalette(model: model, dismiss: { [weak self] in self?.dismissPalette() }, source: source)
        )
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 285, y: screen.visibleFrame.midY - 240))
        } else {
            panel.center()
        }
        palette = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    /// A Spotlight-like bar: type a request, Apple's on-device model turns it into
    /// one checked Kolom action.
    @objc func openAsk() { showAsk() }
    /// `text` pre-fills the bar (from the guide's examples); the user still presses Return.
    func showAsk(_ text: String = "") {
        if let askPanel {
            if !text.isEmpty { askModel?.text = text }
            askPanel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let screens = askDisplayOrder(model.displays.map { (id: $0.id, frame: model.deskFrame($0.frame)) })
        let names = screens.map { id in
            let name = model.displays.first { $0.id == id }?.name ?? id
            return id == model.displays.first?.id ? "\(name) (main)" : name
        }
        let pointer = (model.pointerDisplay().flatMap { screens.firstIndex(of: $0.id) } ?? 0) + 1
        let ask = AskModel(screens: screens, screenNames: names, pointer: pointer)
        ask.text = text
        // The window to move is the one focused before this panel took focus.
        let source = model.commandWindow
        ask.perform = { [weak self] action, done in
            guard let self else { return done(false, "Kolom is not running") }
            self.performAsk(action, screens: screens, source: source, done: done)
        }
        // Only this bar's own panel closes, even if a newer one replaced it.
        ask.onClose = { [weak self, weak ask] ran in
            guard let self, let ask, self.askModel === ask else { return }
            self.askPanel?.orderOut(nil)
            self.askPanel = nil
            self.askModel = nil
            if !ran, self.model.managing, let id = self.model.workspaces[self.model.activeDisplay]?.focus {
                self.model.focus(id)
            }
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 330), styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        // Above the guide and Performance panels beside the rail.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 4)
        panel.contentView = NSHostingView(rootView: AskView(ask: ask))
        AskInterpreter.prewarm()
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 300, y: screen.visibleFrame.midY))
        } else {
            panel.center()
        }
        askPanel = panel
        askModel = ask
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func performAsk(
        _ action: AskAction, screens: [String], source: String?, done: @escaping (Bool, String) -> Void
    ) {
        func display(_ number: Int) -> DisplayModel? {
            screens.indices.contains(number - 1) ? model.displays.first { $0.id == screens[number - 1] } : nil
        }
        switch action {
        case .theme(let theme):
            UserDefaults.standard.set(theme, forKey: "kolomTheme")
            syncAppearance()
            return done(true, "\(theme) theme")
        case .guide:
            if model.guideDisplay == nil { model.toggleGuide() }
            return done(true, "Opened the guide")
        case .performance:
            if model.performanceDisplay == nil { model.togglePerformance() }
            return done(true, "Opened Performance")
        case .pause:
            guard model.enabled else { return done(false, "Kolom is already paused.") }
            pauseSession()
            return done(true, "Paused · every window is going back where it was")
        default: break
        }
        guard model.acting, !model.agentBusy else {
            return done(false, model.agentBusy ? "Kolom is busy with another grid." : "Kolom is paused. Enable it from the menu bar icon first.")
        }
        switch action {
        case .grid(let columns, let rows, let number):
            guard let agent, let d = display(number) else { return done(false, "That screen is not connected.") }
            let reply = agent.createForUser(columns: columns, rows: rows, displayID: d.id) { ok, detail in
                done(ok, ok ? "\(columns)×\(rows) Terminal grid on \(d.name)" : detail)
            }
            guard reply["ok"] as? Bool == true else { return done(false, reply["error"] as? String ?? "The grid could not start.") }
        case .desktop(let number):
            guard let d = display(number) else { return done(false, "That screen is not connected.") }
            model.activeDisplay = d.id
            model.showDesktop()
            return done(true, "Showing the desktop on \(d.name)")
        case .column(let next, let number):
            guard let d = display(number) else { return done(false, "That screen is not connected.") }
            model.activeDisplay = d.id
            model.navigate(next ? 1 : -1)
            return done(true, next ? "Next column on \(d.name)" : "Previous column on \(d.name)")
        case .focus(let app):
            let needle = app.lowercased()
            let ordered = model.displays.flatMap { model.workspaces[$0.id]?.windowIDs ?? [] }
            guard let id = ordered.first(where: { model.windows[$0]?.appName.lowercased().contains(needle) == true })
            else { return done(false, "No \(app) window is in Kolom's columns right now.") }
            model.focus(id)
            return done(true, "Focused \(model.windows[id]?.appName ?? app)")
        case .move(let number):
            guard let d = display(number) else { return done(false, "That screen is not connected.") }
            guard let source, let window = model.windows[source] else { return done(false, "There is no focused window to move.") }
            guard model.displayForWindow(source)?.id != d.id else { return done(false, "\(window.appName) is already on \(d.name).") }
            model.transfer(source, to: d.id)
            return done(true, "Moved \(window.appName) to \(d.name)")
        case .undoGrid:
            let reply = agent?.undoLatestForUser() ?? [:]
            guard reply["ok"] as? Bool == true else { return done(false, reply["error"] as? String ?? "Nothing to undo.") }
            return done(true, "Removed the last grid from the layout; its Terminal windows stay open")
        default: done(false, "")
        }
    }
    func dismissPalette() {
        palette?.orderOut(nil)
        palette = nil
        if model.managing, let id = model.workspaces[model.activeDisplay]?.focus { model.focus(id) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === palette {
            dismissPalette()
            return false
        }
        if sender === askPanel {
            askModel?.dismiss()
            return false
        }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        agentWasEnabled = agent?.enabled == true
        agent?.stop()
        startWhenAuthorized = false
        finishTermination(sessionEnding: Self.sessionEnding())
        return .terminateLater
    }
    /// Logout, restart and shutdown must never be blocked by Kolom.
    static func sessionEnding() -> Bool {
        guard
            let reason = NSAppleEventManager.shared().currentAppleEvent?
                .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.typeCodeValue
        else { return false }
        return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog, kAERestart, kAEShutDown]
            .map { OSType($0) }.contains(reason)
    }
    /// Restore windows, then quit. Never refuse silently: if some windows could
    /// not be restored, keep their records on disk (the watchdog and the next
    /// launch retry them) and let the user decide.
    func finishTermination(sessionEnding: Bool, waits: Int = 0) {
        if model.restoring {
            // A recovery pass is already running; let it finish first.
            if waits < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.finishTermination(sessionEnding: sessionEnding, waits: waits + 1)
                }
            } else {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return
        }
        // Quitting is not a pause worth reporting.
        model.pause(logged: false) { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.model.originals.isEmpty, !sessionEnding, self.model.bridge.trusted else {
                    NSApp.reply(toApplicationShouldTerminate: true)
                    return
                }
                let alert = NSAlert()
                let count = self.model.originals.count
                alert.messageText = "\(count) window\(count == 1 ? "" : "s") could not be restored"
                alert.informativeText =
                    "Kolom keeps their recovery records and tries again after quitting and the next time it opens."
                alert.addButton(withTitle: "Quit Anyway")
                alert.addButton(withTitle: "Keep Kolom Open")
                NSApp.activate(ignoringOtherApps: true)
                let quit = alert.runModal() == .alertFirstButtonReturn
                if !quit && self.agentWasEnabled { self.agent?.setEnabled(true) }
                NSApp.reply(toApplicationShouldTerminate: quit)
            }
        }
    }
}
final class WatchdogDelegate: NSObject, NSApplicationDelegate {
    let parent: pid_t
    init(parent: pid_t) { self.parent = parent }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !AppDelegate.sessionEnding(), let app = NSRunningApplication(processIdentifier: parent),
            !app.isTerminated, app.bundleIdentifier == Bundle.main.bundleIdentifier
        else { return .terminateNow }
        app.terminate()
        return .terminateCancel
    }
}
let app = NSApplication.shared
if !CommandLine.arguments.contains("--recovery-watchdog") { RenameMigration.run() }
let kolomStorage = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Kolom")
let instanceLock = InstanceLock(storage: kolomStorage)
if let flag = CommandLine.arguments.firstIndex(of: "--recovery-watchdog"),
    CommandLine.arguments.indices.contains(flag + 1), let parent = Int32(CommandLine.arguments[flag + 1])
{
    app.setActivationPolicy(.prohibited)
    var recovery: KolomController?
    var recovering = false
    var deadline: Date?
    var lifetimeEnd: Date?
    /// The one pending retry; a Space change or a finished pass replaces it.
    var pendingRetry: DispatchWorkItem?
    func scheduleRecovery(after delay: TimeInterval) {
        pendingRetry?.cancel()
        let task = DispatchWorkItem { recoverAfterExit() }
        pendingRetry = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }
    func recoverAfterExit() {
        guard !recovering else { return }
        // A relaunched Kolom owns the session now and recovers the records itself.
        guard instanceLock.acquire() != .busy else { exit(0) }
        if deadline == nil {
            deadline = Date().addingTimeInterval(600)
            lifetimeEnd = Date().addingTimeInterval(3600)
            _ = DesktopAppearance()  // Restores a themed wallpaper left by the crash.
        }
        let pending = FileManager.default.fileExists(atPath: kolomStorage.appendingPathComponent("restore.json").path)
        // Retry for ten minutes after the last Space change and at most an hour in
        // all, then leave the records for the next launch instead of running on.
        guard pending, let deadline, let lifetimeEnd,
            Date() < min(deadline, lifetimeEnd)
        else { exit(0) }
        if recovery == nil {
            recovery = KolomController()
            recovery?.keepsOtherSpaceRecords = true
        }
        guard let recovery else { return }
        func retry() {
            // Release between passes so a relaunched Kolom can take over.
            instanceLock.release()
            scheduleRecovery(after: 3)
        }
        guard recovery.bridge.trusted else {
            retry()
            return
        }
        recovering = true
        recovery.restorePrevious {
            if recovery.originals.isEmpty { exit(0) }
            recovering = false
            retry()
        }
    }
    // Records for windows on another Space only match once that Space is shown
    // again: retry on every Space change and keep the deadline open meanwhile.
    let spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
    ) { _ in
        guard deadline != nil else { return }
        deadline = Date().addingTimeInterval(600)
        scheduleRecovery(after: 0.6)
    }
    let watcher = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
    watcher.setEventHandler { recoverAfterExit() }
    watcher.resume()
    if kill(parent, 0) != 0, errno == ESRCH { DispatchQueue.main.async(execute: recoverAfterExit) }
    // The watchdog shares Kolom's bundle identifier, so a quit request for the app
    // can reach it instead. Pass it on to the app; logout and shutdown still quit.
    let watchdogDelegate = WatchdogDelegate(parent: parent)
    app.delegate = watchdogDelegate
    withExtendedLifetime((spaceObserver, watchdogDelegate)) { app.run() }
} else {
    // A second copy, or a watchdog still recovering the previous session, owns
    // the windows. Wait briefly for a recovery pass to finish.
    // An unusable lock file must not stop Kolom from starting or recovering.
    guard instanceLock.acquire(timeout: 15) != .busy else {
        app.setActivationPolicy(.accessory)
        let alert = NSAlert()
        alert.messageText = "Kolom is already running"
        alert.informativeText =
            "Another copy of Kolom, or its recovery helper, is managing your windows. Quit it before opening this copy."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        exit(0)
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
