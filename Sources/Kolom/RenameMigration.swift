import AppKit

/// Kolom was called Ribbon before 0.2.0. Carry an earlier install's layout,
/// recovery records and settings over once, and never manage windows while the
/// old app still does.
enum RenameMigration {
    static let oldBundleID = "com.ribbon.desktop.alpha"
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    static let oldStorage = support.appendingPathComponent("Ribbon")

    static func run() {
        if ribbonIsManaging() {
            NSApplication.shared.setActivationPolicy(.accessory)
            let alert = NSAlert()
            alert.messageText = "Quit Ribbon first"
            alert.informativeText =
                "Ribbon, the earlier name of Kolom, is managing your windows. Quit it so it restores them, then open Kolom."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            exit(0)
        }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromRibbon") else { return }
        let storage = support.appendingPathComponent("Kolom")
        if !FileManager.default.fileExists(atPath: storage.path), FileManager.default.fileExists(atPath: oldStorage.path)
        {
            // Copy beside the target and rename, so an interrupted copy is never mistaken for Kolom's storage.
            let staging = support.appendingPathComponent("Kolom-migrating-\(getpid())")
            try? FileManager.default.removeItem(at: staging)
            guard (try? FileManager.default.copyItem(at: oldStorage, to: staging)) != nil,
                (try? FileManager.default.moveItem(at: staging, to: storage)) != nil
            else {
                try? FileManager.default.removeItem(at: staging)
                return
            }
        }
        for (key, value) in defaults.persistentDomain(forName: oldBundleID) ?? [:] {
            let key = key == "ribbonTheme" ? "kolomTheme" : key
            if defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "migratedFromRibbon")
    }

    /// Ribbon's recovery watchdog shares its bundle identifier; only the app itself counts.
    static func ribbonIsManaging() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: oldBundleID).contains { app in
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-o", "args=", "-p", String(app.processIdentifier)]
            let out = Pipe()
            ps.standardOutput = out
            guard (try? ps.run()) != nil else { return true }
            ps.waitUntilExit()
            let args = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return !args.contains("--recovery-watchdog")
        }
    }
}
