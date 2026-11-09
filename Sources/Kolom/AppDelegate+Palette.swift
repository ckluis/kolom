import AppKit
import ApplicationServices
import Combine
import SwiftUI
import KolomCore

/// The move palette and Ask Kolom.
extension AppDelegate {
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
}
