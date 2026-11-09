import Foundation

/// Which folders a scan enters.
public enum StorageScope {
    /// The startup disk is scanned from "/". Its data reaches the tree through the
    /// firmlinks (/Users, /Applications, …), so /System/Volumes, which holds the same
    /// data volume and macOS's own, is skipped, as are other disks under /Volumes and
    /// the virtual /dev, /net and /home.
    public static let skippedOnStartupDisk: Set<String> = [
        "/System/Volumes", "/Volumes", "/dev", "/net", "/home", "/cores",
    ]

    public static func enters(_ path: String, startupDisk: Bool) -> Bool {
        guard startupDisk else { return true }
        return !skippedOnStartupDisk.contains(path)
    }
}

public enum StorageFormat {
    /// Decimal units, as Finder shows them.
    public static func bytes(_ value: UInt64) -> String {
        let v = Double(value)
        if v >= 1e12 { return String(format: "%.2f TB", v / 1e12) }
        if v >= 1e9 { return String(format: v >= 1e11 ? "%.0f GB" : "%.1f GB", v / 1e9) }
        if v >= 1e6 { return String(format: "%.0f MB", v / 1e6) }
        if v >= 1e3 { return String(format: "%.0f KB", v / 1e3) }
        return "\(value) bytes"
    }
}
