import Foundation

/// A release version, "0.2.2" or a "v0.2.2" tag. Only x.y.z is accepted.
public struct ReleaseVersion: Comparable, CustomStringConvertible {
    public let parts: [Int]
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let fields = bare.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        let numbers = fields.map { field -> Int? in
            !field.isEmpty && field.count <= 9 && field.allSatisfy({ ("0"..."9").contains($0) }) ? Int(field) : nil
        }
        guard numbers.allSatisfy({ $0 != nil }) else { return nil }
        parts = numbers.map { $0! }
    }
    public var description: String { parts.map(String.init).joined(separator: ".") }
    public static func < (a: ReleaseVersion, b: ReleaseVersion) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
}

/// A published release newer than the running build.
public struct AvailableUpdate: Codable, Equatable {
    public var version: String
    /// The release page on github.com, never an arbitrary address from the response.
    public var url: String
    public init(version: String, url: String) {
        self.version = version
        self.url = url
    }
}

/// Kolom asks GitHub at most once a day for its latest release and compares it with
/// the running version. Nothing about the Mac or its windows is sent.
public enum UpdateCheck {
    public static let repository = "ckluis/kolom"
    public static let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    public static let releasesPage = "https://github.com/\(repository)/releases"
    public static let interval: TimeInterval = 24 * 60 * 60

    public static func isDue(lastChecked: Double?, now: Double, interval: TimeInterval = interval) -> Bool {
        guard let lastChecked, lastChecked <= now else { return true }
        return now - lastChecked >= interval
    }

    /// The update a GitHub "latest release" response offers over `current`, if any.
    /// Drafts, prereleases, malformed tags and pages outside the repository are ignored.
    public static func update(fromLatestRelease data: Data, current: String) -> AvailableUpdate? {
        guard let local = ReleaseVersion(current),
            let release = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            release["draft"] as? Bool != true, release["prerelease"] as? Bool != true,
            let tag = release["tag_name"] as? String, let remote = ReleaseVersion(tag), remote > local
        else { return nil }
        let page = release["html_url"] as? String
        let url = page.flatMap { $0.hasPrefix(releasesPage + "/") ? $0 : nil } ?? releasesPage
        return AvailableUpdate(version: remote.description, url: url)
    }

    /// An update remembered from an earlier check, kept only while it is still newer.
    public static func stillNewer(_ update: AvailableUpdate?, current: String) -> AvailableUpdate? {
        guard let update, let local = ReleaseVersion(current), let remote = ReleaseVersion(update.version),
            remote > local
        else { return nil }
        return update
    }

    /// The Terminal command that updates a source checkout. Kolom refuses to be
    /// replaced while running, so the installer asks it to quit (windows are restored).
    public static func command(checkout: String?) -> String {
        let steps = "git pull --ff-only && ./scripts/install.sh --quit-running"
        guard let checkout, !checkout.isEmpty else { return steps }
        return "cd \(shellQuoted(checkout)) && \(steps)"
    }

    /// The script "Update now" runs in Terminal.
    public static func terminalScript(checkout: String) -> String {
        """
        #!/bin/zsh
        # Written by Kolom for "Update now". Safe to delete.
        echo "Updating Kolom in \(shellQuoted(checkout))…"
        echo
        \(command(checkout: checkout))
        result=$?
        echo
        if [[ $result -eq 0 ]]; then
          echo "Kolom is updated. You can close this window."
        else
          echo "The update stopped (exit $result). The output above says why."
          pgrep -xq Kolom || open -a Kolom
        fi

        """
    }

    public static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
