import Foundation

/// A folder tree with sizes, built while a disk is scanned. Only folders are kept;
/// a folder's own files are totals, listed live when the folder is shown. Small
/// finished folders drop their subfolders so memory stays bounded; opening one
/// scans it again.
public final class StorageFolder {
    public let name: String
    public private(set) weak var parent: StorageFolder?
    /// Allocated bytes of everything beneath, files and folders.
    public private(set) var size: UInt64 = 0
    /// Allocated bytes and count of the files directly inside.
    public private(set) var filesSize: UInt64 = 0
    public private(set) var fileCount = 0
    /// Every file beneath.
    public private(set) var totalFiles = 0
    public private(set) var children: [StorageFolder] = []
    /// Subfolders that could not be read (macOS privacy protection, permissions).
    public private(set) var unreadable = 0
    /// Every unreadable folder beneath.
    public private(set) var totalUnreadable = 0
    /// Its own subfolders were dropped after it finished, because it is small.
    public private(set) var trimmed = false
    public private(set) var finished = false

    public init(name: String, parent: StorageFolder? = nil) {
        self.name = name
        self.parent = parent
    }

    public var path: String {
        guard let parent else { return name }
        let base = parent.path
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }

    public func child(named name: String) -> StorageFolder {
        let folder = StorageFolder(name: name, parent: self)
        children.append(folder)
        return folder
    }

    /// A file directly inside; every enclosing folder grows with it.
    public func addFile(bytes: UInt64) {
        filesSize &+= bytes
        fileCount += 1
        var folder: StorageFolder? = self
        while let current = folder {
            current.size &+= bytes
            current.totalFiles += 1
            folder = current.parent
        }
    }

    public func addUnreadable() {
        unreadable += 1
        var folder: StorageFolder? = self
        while let current = folder {
            current.totalUnreadable += 1
            folder = current.parent
        }
    }

    /// Called when the scan leaves the folder. Drops the subfolders of one smaller
    /// than `keepBelow` bytes; they are rescanned if the folder is opened.
    public func finish(trimBelow keepBelow: UInt64) {
        finished = true
        if size < keepBelow, !children.isEmpty {
            children = []
            trimmed = true
        }
    }

    /// Largest first.
    public var sortedChildren: [StorageFolder] { children.sorted { $0.size > $1.size } }

    public func descendant(_ names: [String]) -> StorageFolder? {
        var folder: StorageFolder? = self
        for name in names { folder = folder?.children.first { $0.name == name } }
        return folder
    }

    /// Takes over a fresh scan of this same folder (opening a trimmed one).
    public func adopt(_ scan: StorageFolder) {
        children = scan.children
        for child in children { child.parent = self }
        trimmed = false
        // Sizes were already counted; only the structure is new.
    }
}

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

    /// Bytes below which a finished folder keeps no subfolders: 0.05% of what the
    /// disk holds, between 8 MB and 256 MB.
    public static func trimThreshold(usedBytes: UInt64) -> UInt64 {
        min(256_000_000, max(8_000_000, usedBytes / 2000))
    }
}

/// Counts a file with several hard links once.
public struct HardLinkLedger {
    private var seen: Set<UInt64> = []
    public init() {}
    /// Whether this inode is counted now (first sighting, or a single-link file).
    public mutating func count(inode: UInt64, links: UInt16) -> Bool {
        links <= 1 || seen.insert(inode).inserted
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
