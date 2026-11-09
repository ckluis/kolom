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
if !CommandLine.arguments.contains("--recovery-watchdog") && !SmokeMode.active { RenameMigration.run() }
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
    // A smoke run uses its own storage and never manages windows, so it may run
    // beside a working copy of Kolom.
    guard SmokeMode.active || instanceLock.acquire(timeout: 15) != .busy else {
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
