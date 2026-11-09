import Foundation

/// What is marked for removal in a Disk Map. Marking a folder absorbs any marks
/// inside it, and nothing inside a marked folder can be marked on its own, so the
/// space to be had back is never counted twice.
public struct DiskMarks {
    public enum Refusal: Equatable {
        /// A folder holding it is already marked.
        case insideMarked(String)
        /// The removal policy refuses this path.
        case protected(String)
    }

    private var marked: [ObjectIdentifier: DiskNode] = [:]
    public init() {}

    public var nodes: [DiskNode] { marked.values.sorted { $0.size > $1.size } }
    public var count: Int { marked.count }
    public var isEmpty: Bool { marked.isEmpty }
    /// Bytes the marks hold; no mark lies inside another.
    public var bytes: UInt64 { marked.values.reduce(0) { $0 &+ $1.size } }
    public var files: Int { marked.values.reduce(0) { $0 + max(1, $1.files) } }

    public func isMarked(_ node: DiskNode) -> Bool { marked[ObjectIdentifier(node)] != nil }

    /// The marked folder holding `node`, if any (its tile takes the danger colour too).
    public func markedAncestor(of node: DiskNode) -> DiskNode? {
        var current = node.parent
        while let folder = current {
            if isMarked(folder) { return folder }
            current = folder.parent
        }
        return nil
    }

    /// Marked, or inside something marked.
    public func covers(_ node: DiskNode) -> Bool { isMarked(node) || markedAncestor(of: node) != nil }

    /// Marks `node`, absorbing marks inside it. Returns why not, when it may not be.
    @discardableResult
    public mutating func mark(_ node: DiskNode, policy: DiskRemovalPolicy) -> Refusal? {
        if let ancestor = markedAncestor(of: node) { return .insideMarked(ancestor.path) }
        if let reason = policy.refusal(for: node) { return .protected(reason) }
        for (key, other) in marked where other.lineage.contains(where: { $0 === node }) {
            marked[key] = nil
        }
        marked[ObjectIdentifier(node)] = node
        return nil
    }

    public mutating func unmark(_ node: DiskNode) { marked[ObjectIdentifier(node)] = nil }

    /// Marks or unmarks, as Space does.
    @discardableResult
    public mutating func toggle(_ node: DiskNode, policy: DiskRemovalPolicy) -> Refusal? {
        if isMarked(node) {
            unmark(node)
            return nil
        }
        return mark(node, policy: policy)
    }

    public mutating func removeAll() { marked = [:] }
}

/// What may never be removed from the Disk Map: macOS, the folders macOS expects in
/// a home, the home itself and everything above it, the scan root, and anything
/// that is not where the scan saw it (a symlink, a moved or replaced path).
public struct DiskRemovalPolicy {
    public let home: String
    public let scanRoot: String
    public init(home: String, scanRoot: String) {
        self.home = home
        self.scanRoot = scanRoot
    }

    static let systemPrefixes = [
        "/System", "/usr", "/bin", "/sbin", "/private/var/db", "/private/etc", "/Library/Apple", "/cores", "/dev",
    ]
    /// Folders macOS and apps expect to exist; their contents may go, they may not.
    static let homeFolders = [
        "Library", "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Public", "Applications",
        "Library/Application Support", "Library/Containers", "Library/Group Containers", "Library/Preferences",
        "Library/Mobile Documents", "Library/CloudStorage",
    ]
    static let topFolders = ["/Applications", "/Library", "/Users", "/private", "/private/var", "/opt", "/Volumes"]

    public func refusal(for node: DiskNode) -> String? {
        if node.role == .smallerFiles { return "Smaller files are many separate files; mark their folder instead" }
        return refusal(forPath: node.path)
    }

    public func refusal(forPath path: String) -> String? {
        let clean = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        if clean == "/" || clean.isEmpty { return "The whole disk" }
        if clean == scanRoot { return "The folder being mapped; mark what is inside it" }
        if home == clean || home.hasPrefix(clean + "/") { return "Your home folder holds everything of yours" }
        if Self.topFolders.contains(clean) { return "A folder macOS expects" }
        for prefix in Self.systemPrefixes where clean == prefix || clean.hasPrefix(prefix + "/") {
            return "Part of macOS"
        }
        for folder in Self.homeFolders where clean == home + "/" + folder {
            return "A folder macOS expects in your home; mark what is inside it"
        }
        return nil
    }

    /// Allowed, but worth saying in the review before it goes.
    public func warning(for node: DiskNode) -> String? {
        switch node.kind {
        case .synced: return "Synced: removing it here removes it from your other devices too"
        case .code, .git: return "Code: check for work that exists nowhere else (uncommitted or unpushed)"
        case .documents where node.reclaim == nil: return "Your documents"
        case .apps where node.name.hasSuffix(".app"): return "An app: Move to Trash is how macOS uninstalls it"
        default: return nil
        }
    }

    /// Checked again just before removal: the path must still be what the scan saw,
    /// not a symlink or a path that now resolves somewhere else.
    public static func stillTheSame(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { return false }
        guard let resolved = realpath(path, nil) else { return false }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        // /tmp, /var and /etc resolve through /private; that is the same place.
        return canonical == path || canonical == "/private" + path
    }
}

extension DiskNode {
    /// Takes a removed child out of the tree, subtracting its size and files from
    /// every folder above, so the map is right at once (a rescan confirms it).
    public func remove(_ child: DiskNode) {
        guard let index = children.firstIndex(where: { $0 === child }) else { return }
        children.remove(at: index)
        var folder: DiskNode? = self
        while let current = folder {
            current.size = current.size >= child.size ? current.size - child.size : 0
            current.files = max(0, current.files - max(1, child.files))
            current.unreadable = max(0, current.unreadable - (child.isFolder ? child.unreadable : 0))
            folder = current.parent
        }
    }
}
