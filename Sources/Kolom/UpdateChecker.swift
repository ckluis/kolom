import AppKit
import KolomCore

/// Asks GitHub once a day whether a newer Kolom release exists. One HTTPS GET with
/// a generic user agent and no cookies; nothing about the Mac or its windows is sent.
/// Turned off from the menu ("Check for updates automatically").
final class UpdateChecker {
    private enum Key {
        static let enabled = "checkForUpdates"
        static let lastChecked = "updateLastChecked"
        static let available = "updateAvailable"
    }
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var inFlight = false
    /// Called on the main thread whenever `available` or the last result changes.
    var changed: (() -> Void)?
    private(set) var available: AvailableUpdate?
    private(set) var lastError: String?

    var automatic: Bool {
        get { defaults.object(forKey: Key.enabled) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.enabled)
            if newValue { checkIfDue() }
        }
    }
    var lastChecked: Date? {
        (defaults.object(forKey: Key.lastChecked) as? Double).map(Date.init(timeIntervalSince1970:))
    }

    init() {
        // A remembered update survives relaunch until this build catches up with it.
        available = UpdateCheck.stillNewer(
            defaults.data(forKey: Key.available).flatMap { try? JSONDecoder().decode(AvailableUpdate.self, from: $0) },
            current: BuildInfo.version)
        if available == nil { defaults.removeObject(forKey: Key.available) }
    }

    /// The first check waits a minute so launch and window recovery come first.
    func start() {
        timer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            self?.checkIfDue()
        }
    }

    func checkIfDue() {
        guard automatic,
            UpdateCheck.isDue(
                lastChecked: defaults.object(forKey: Key.lastChecked) as? Double,
                now: Date().timeIntervalSince1970)
        else { return }
        check()
    }

    enum Outcome {
        case available(AvailableUpdate)
        case upToDate
        case failed(String)
        var message: String {
            switch self {
            case .available(let update): return "Kolom \(update.version) is available"
            case .upToDate: return "Kolom \(BuildInfo.version) is up to date"
            case .failed(let reason): return "Couldn’t check for updates · \(reason)"
            }
        }
    }

    func check(completion: ((Outcome) -> Void)? = nil) {
        guard ReleaseVersion(BuildInfo.version) != nil else {
            completion?(.failed("this copy of Kolom (\(BuildInfo.version)) was not built by build-app.sh"))
            return
        }
        guard !inFlight else {
            completion?(.failed("a check is already running"))
            return
        }
        inFlight = true
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: UpdateCheck.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Kolom/\(BuildInfo.version)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, error in
            session.finishTasksAndInvalidate()
            let status = (response as? HTTPURLResponse)?.statusCode
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                let outcome: Outcome
                if let data, status == 200 {
                    self.record(UpdateCheck.update(fromLatestRelease: data, current: BuildInfo.version))
                    outcome = self.available.map(Outcome.available) ?? .upToDate
                } else if status == 404 {
                    // No release published yet.
                    self.record(nil)
                    outcome = .upToDate
                } else {
                    // Offline or rate-limited: try again on the next due check.
                    let reason = error?.localizedDescription ?? "GitHub answered \(status.map(String.init) ?? "nothing")"
                    self.lastError = reason
                    outcome = .failed(reason)
                    self.changed?()
                }
                completion?(outcome)
            }
        }.resume()
    }

    private func record(_ update: AvailableUpdate?) {
        defaults.set(Date().timeIntervalSince1970, forKey: Key.lastChecked)
        lastError = nil
        available = update
        if let update, let data = try? JSONEncoder().encode(update) {
            defaults.set(data, forKey: Key.available)
        } else {
            defaults.removeObject(forKey: Key.available)
        }
        changed?()
    }

    /// The checkout this build came from, when it still exists.
    var checkout: String? {
        BuildInfo.source.flatMap {
            FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent("scripts/install.sh"))
                ? $0 : nil
        }
    }
    var command: String { UpdateCheck.command(checkout: checkout) }

    func openReleaseNotes() {
        guard let update = available, let url = URL(string: update.url) else { return }
        NSWorkspace.shared.open(url)
    }
    func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// Kolom can run the update itself only when it knows its checkout.
    var canUpdateInTerminal: Bool { checkout != nil }

    /// Opens the update command in Terminal (or whatever opens .command files), from
    /// a script Kolom writes for the purpose. The installer quits Kolom (windows are
    /// restored) and opens the new build; if it stops partway, the script reopens
    /// whichever Kolom is installed so windows are not left unmanaged.
    func updateInTerminal() throws {
        guard let checkout else { throw CocoaError(.fileNoSuchFile) }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kolom", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("update.command")
        try UpdateCheck.terminalScript(checkout: checkout).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        guard NSWorkspace.shared.open(script) else { throw CocoaError(.fileReadNoPermission) }
    }

    /// For live-state.json, so kolom_state tells agents an update exists.
    var liveState: [String: Any] {
        var state: [String: Any] = ["automatic": automatic, "current": BuildInfo.version]
        if let lastChecked { state["lastChecked"] = lastChecked.timeIntervalSince1970 }
        if let available {
            state["available"] = available.version
            state["releaseNotes"] = available.url
            state["command"] = command
        }
        return state
    }
}
