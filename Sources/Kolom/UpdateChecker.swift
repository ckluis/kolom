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

    /// `completion` gets a sentence for the status line.
    func check(completion: ((String) -> Void)? = nil) {
        guard ReleaseVersion(BuildInfo.version) != nil else {
            completion?("Update checks need a built copy of Kolom (this one is \(BuildInfo.version))")
            return
        }
        guard !inFlight else {
            completion?("Already checking for updates")
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
                let message: String
                if let data, status == 200 {
                    self.record(UpdateCheck.update(fromLatestRelease: data, current: BuildInfo.version))
                    message =
                        self.available.map { "Kolom \($0.version) is available" }
                        ?? "Kolom \(BuildInfo.version) is up to date"
                } else if status == 404 {
                    // No release published yet.
                    self.record(nil)
                    message = "Kolom \(BuildInfo.version) is up to date"
                } else {
                    // Offline or rate-limited: try again on the next due check.
                    self.lastError = error?.localizedDescription ?? "GitHub answered \(status.map(String.init) ?? "nothing")"
                    message = "Couldn’t check for updates · \(self.lastError!)"
                    self.changed?()
                }
                completion?(message)
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
