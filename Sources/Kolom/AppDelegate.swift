import AppKit
import ApplicationServices
import Combine
import SwiftUI
import KolomCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let model = KolomController(storage: SmokeMode.storage)
    var smokeTest: SmokeTest?
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
    var diskMapPanel: DiskMapPanel?
    var diskMapModel: DiskMapModel?
    var guidePanel: PerformancePanel?
    var guidePanelDisplay: String?
    var registered = false
    var recoveryHelper: Process?
    var agent: AgentControl?
    var agentWasEnabled = false
    /// SIGTERM (scripts/install.sh --quit-running) quits like the menu item: windows are restored first.
    var terminationSignal: DispatchSourceSignal?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        signal(SIGTERM, SIG_IGN)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        // Not NSApp.terminate here: quitting restores windows through work queued on
        // the main queue, which cannot run while this handler (a main-queue block) is
        // still on the stack, so 0.2.2–0.2.4 waited forever. A run-loop perform starts
        // the quit after the handler has returned.
        terminate.setEventHandler {
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        }
        terminate.resume()
        terminationSignal = terminate
        installMenu()
        agent = AgentControl(model: model)
        model.showPalette = { [weak self] in self?.openPalette() }
        model.chooseApp = { [weak self] id in self?.chooseApp(on: id) }
        themeObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).sink {
            [weak self] _ in self?.syncAppearance()
        }
        model.layoutChanged = { [weak self] in self?.syncPanels() }
        DiskMapHost.open = { [weak self] target in self?.model.openDiskMap(target) }
        model.updates.changed = { [weak self] in
            self?.model.writeLiveState()
            self?.refreshStatusIcon()
        }
        if !SmokeMode.active { model.updates.start() }
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
        refreshStatusIcon()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        permissionObserver = model.$permissionGranted.removeDuplicates().receive(on: RunLoop.main).sink {
            [weak self] granted in
            guard let self, granted, self.startWhenAuthorized, !SmokeMode.active else { return }
            self.startAutomatically()
        }
        _ = model.checkAccess()
        // A smoke run drives the panels itself and never manages windows or asks anything.
        if let output = SmokeMode.output {
            startWhenAuthorized = false
            smokeTest = SmokeTest(delegate: self, output: output)
            smokeTest?.start()
            return
        }
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
        guard !SmokeMode.active else { return }
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
