import Foundation

/// The version `scripts/build-app.sh` stamps into Kolom.app from `VERSION` and git,
/// read the same way by the app and by the kolomctl inside its bundle (also when it
/// runs through the ~/.local/bin link). Every build is told apart by its commit.
public enum BuildInfo {
    static let info: [String: Any] = {
        if let main = Bundle.main.infoDictionary, main["CFBundleShortVersionString"] != nil { return main }
        // kolomctl lives in Kolom.app/Contents/MacOS; its own bundle has no Info.plist.
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return [:] }
        let plist = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        return NSDictionary(contentsOf: plist) as? [String: Any] ?? [:]
    }()
    /// The release version, such as "0.2.1"; "development" outside a built bundle.
    public static var version: String { info["CFBundleShortVersionString"] as? String ?? "development" }
    /// The short commit the build came from, with "-dirty" for uncommitted changes.
    public static var commit: String? { info["KolomCommit"] as? String }
    /// "0.2.1 (b1a2c3d)", or the bare version when built without git.
    public static var label: String { commit.map { "\(version) (\($0))" } ?? version }
}
