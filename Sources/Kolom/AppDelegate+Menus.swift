import AppKit
import ApplicationServices
import Combine
import SwiftUI
import KolomCore

/// The menu bar icon's menu, the main menu and their actions.
extension AppDelegate {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleIsolateDisplays) { item.state = model.isolateDisplays ? .on : .off }
        return true
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
        let diskMap = NSMenuItem(title: "Disk Map…", action: #selector(openDiskMap), keyEquivalent: "")
        diskMap.target = self
        submenu.addItem(diskMap)
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
    @objc func openDiskMap() {
        let name = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]))?.volumeName
        DiskMapHost.open(path: "/", name: name ?? "Startup disk", startupDisk: true)
    }
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
            "Kolom · \(BuildInfo.label)",
            nil, enabled: false)
        if let update = model.updates.available {
            item("Kolom \(update.version) is available · What’s new…", #selector(openReleaseNotes))
            if model.updates.canUpdateInTerminal {
                item("Update now…", #selector(updateNow)).toolTip =
                    "Runs the update in Terminal: Kolom quits (your windows are restored), the new version is built and installed from your checkout, and it opens again."
            }
            item("Copy update command", #selector(copyUpdateCommand)).toolTip =
                "Paste in Terminal: \(model.updates.command)\nKolom quits first (your windows are restored), then the new build opens."
        }
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
        item("Disk Map…", #selector(openDiskMap))
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
        item("Check for updates now", #selector(checkForUpdates))
        item("Check for updates automatically", #selector(toggleAutomaticUpdates)).state =
            model.updates.automatic ? .on : .off
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
}
