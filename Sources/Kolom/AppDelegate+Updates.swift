import AppKit
import ApplicationServices
import Combine
import SwiftUI
import KolomCore

/// Update checks, Update now and the menu bar icon's dot.
extension AppDelegate {
    @objc func openReleaseNotes() { model.updates.openReleaseNotes() }
    @objc func copyUpdateCommand() {
        model.updates.copyCommand()
        model.status = "Update command copied · paste it in Terminal"
    }
    @objc func updateNow() {
        do {
            try model.updates.updateInTerminal()
            model.status = "Updating in Terminal · Kolom restarts when it is done"
        } catch {
            model.updates.copyCommand()
            let alert = NSAlert()
            alert.messageText = "Kolom couldn’t open Terminal"
            alert.informativeText =
                "The update command is copied instead. Paste it in Terminal:\n\n\(model.updates.command)"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
    /// The menu has closed by the time GitHub answers, so a check you asked for
    /// answers in a dialog.
    @objc func checkForUpdates() {
        model.status = "Checking for updates…"
        model.updates.check { [weak self] outcome in
            guard let self else { return }
            self.model.status = outcome.message
            let alert = NSAlert()
            alert.messageText = outcome.message
            switch outcome {
            case .available:
                alert.informativeText =
                    "You have Kolom \(BuildInfo.version). "
                    + (self.model.updates.canUpdateInTerminal
                        ? "Update now runs the update in Terminal: Kolom quits (your windows are restored), the new version is built and installed from your checkout, and it opens again."
                        : "Paste the update command in Terminal, in your Kolom checkout: Kolom quits (your windows are restored), and the new version is built, installed and opened.")
                if self.model.updates.canUpdateInTerminal { alert.addButton(withTitle: "Update Now") }
                alert.addButton(withTitle: "Copy Update Command")
                alert.addButton(withTitle: "What’s New")
                alert.addButton(withTitle: "Later")
                NSApp.activate(ignoringOtherApps: true)
                let response = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                let actions: [() -> Void] =
                    (self.model.updates.canUpdateInTerminal ? [self.updateNow] : [])
                    + [self.copyUpdateCommand, { self.model.updates.openReleaseNotes() }]
                if response >= 0, response < actions.count { actions[response]() }
            case .upToDate:
                alert.informativeText = "This is the latest release on GitHub."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            case .failed(let reason):
                alert.messageText = "Couldn’t check for updates"
                alert.informativeText = "\(reason). Kolom tries again later; nothing was changed."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }
    /// The menu bar icon carries a dot while an update is waiting.
    func refreshStatusIcon() {
        guard let button = statusItem?.button,
            let base = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "Kolom")
        else { return }
        guard let update = model.updates.available else {
            button.image = base
            button.toolTip = "Kolom"
            return
        }
        let size = base.size
        let badged = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            let dot = min(rect.width, rect.height) * 0.42
            let circle = NSRect(x: rect.maxX - dot, y: rect.maxY - dot, width: dot, height: dot)
            // Clear a ring around the dot so it reads against the symbol.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: circle.insetBy(dx: -1.2, dy: -1.2)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: circle).fill()
            return true
        }
        badged.isTemplate = true
        badged.accessibilityDescription = "Kolom, update \(update.version) available"
        button.image = badged
        button.toolTip = "Kolom \(update.version) is available"
    }
    @objc func toggleAutomaticUpdates() { model.updates.automatic.toggle() }
}
