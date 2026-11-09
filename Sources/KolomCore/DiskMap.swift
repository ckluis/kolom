import CoreGraphics
import Foundation

/// A kind of data, for colour. Rules adapted from DiskTree (tobi/disktree, MIT),
/// crates/disktree-core/src/classify.rs.
public enum DiskKind: Int, CaseIterable {
    case code, agentScratch, toolchain, synced, git, media, documents, cache, apps, system, other

    public static let legend: [DiskKind] = [
        .code, .agentScratch, .toolchain, .synced, .git, .media, .documents, .cache, .apps, .system,
    ]
    public var label: String {
        switch self {
        case .code: return "Code"
        case .agentScratch: return "Agent scratch"
        case .toolchain: return "Toolchains"
        case .synced: return "Synced"
        case .git: return "Git"
        case .media: return "Media"
        case .documents: return "Documents"
        case .cache: return "Cache"
        case .apps: return "Apps"
        case .system: return "macOS"
        case .other: return "Other"
        }
    }
}

/// Why a folder's space can be had back.
public enum DiskReclaim: Int {
    case regenerable, syncHistory, packageStore, buildOutput, reinstallable, sandboxLayers, snapshots, trash,
        temporary
    public var label: String {
        switch self {
        case .regenerable: return "regenerable"
        case .syncHistory: return "sync history"
        case .packageStore: return "package store"
        case .buildOutput: return "build output"
        case .reinstallable: return "reinstallable"
        case .sandboxLayers: return "sandbox layers"
        case .snapshots: return "snapshots"
        case .trash: return "trash"
        case .temporary: return "temporary"
        }
    }
}

/// A folder, a file of note, or a folder's smaller files gathered as one.
public final class DiskNode {
    public enum Role { case folder, file, smallerFiles }
    public let name: String
    public let role: Role
    /// Unowned: a parent always outlives its children, and a weak reference
    /// costs a side table per node (hundreds of thousands on a whole disk).
    public internal(set) unowned(unsafe) var parent: DiskNode?
    /// Allocated bytes beneath (or of the file).
    public var size: UInt64 = 0
    /// Files beneath (1 for a file; the count for smaller files).
    public var files = 0
    public var children: [DiskNode] = []
    public var kind = DiskKind.other
    public var reclaim: DiskReclaim?
    /// Folders beneath that could not be read.
    public var unreadable = 0
    /// Latest modification beneath, seconds since 1970.
    public var modified: Double = 0
    /// Names noted while listing, for classification.
    public var markers: Markers = []
    /// Sum of the files gathered into "smaller files", before finishing.
    public var smallBytes: UInt64 = 0
    public var smallCount = 0

    public struct Markers: OptionSet {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let cargoManifest = Markers(rawValue: 1)
        public static let packageManifest = Markers(rawValue: 2)
        public static let gitHead = Markers(rawValue: 4)
        public static func of(fileName: String) -> Markers {
            switch fileName {
            case "Cargo.toml": return .cargoManifest
            case "package.json": return .packageManifest
            case "HEAD": return .gitHead
            case "Package.swift": return .swiftManifest
            default: return []
            }
        }
    }

    public init(name: String, role: Role, parent: DiskNode? = nil) {
        self.name = name
        self.role = role
        self.parent = parent
    }

    public var isFolder: Bool { role == .folder }

    /// The path of the scan root is its name; beneath, names are joined.
    public var path: String {
        guard let parent else { return name }
        if role == .smallerFiles { return parent.path }
        let base = parent.path
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }

    public var title: String { role == .smallerFiles ? "Smaller files" : name }

    /// From the scan root down to this node.
    public var lineage: [DiskNode] {
        var nodes: [DiskNode] = []
        var node: DiskNode? = self
        while let current = node {
            nodes.insert(current, at: 0)
            node = current.parent
        }
        return nodes
    }

    public func adopt(_ child: DiskNode) {
        child.parent = self
        children.append(child)
    }

    /// After the scan: smaller files become one entry, sizes and counts are
    /// totalled bottom-up and children sorted largest first. Iterative, so a
    /// deep tree cannot exhaust the stack.
    public func finish() {
        var order: [DiskNode] = []
        var stack: [DiskNode] = [self]
        while let node = stack.popLast() {
            order.append(node)
            stack.append(contentsOf: node.children.filter(\.isFolder))
        }
        for node in order.reversed() {
            if node.smallCount > 0 {
                let small = DiskNode(name: "", role: .smallerFiles, parent: node)
                small.size = node.smallBytes
                small.files = node.smallCount
                small.modified = node.modified
                node.children.append(small)
                node.smallBytes = 0
                node.smallCount = 0
            }
            var size: UInt64 = 0
            var files = 0
            var unreadable = node.unreadable
            var modified = node.modified
            for child in node.children {
                size &+= child.size
                files += child.role == .folder ? child.files : max(1, child.files)
                if child.isFolder { unreadable += child.unreadable }
                modified = max(modified, child.modified)
            }
            node.size = size
            node.files = files
            node.unreadable = unreadable
            node.modified = modified
            node.children.sort { $0.size > $1.size }
        }
    }

    /// Folders smaller than `bytes` keep their totals but not their contents: they
    /// draw as a few pixels at most, and a whole disk has hundreds of thousands.
    /// Their contents become one "smaller files" entry. Returns how many were collapsed.
    @discardableResult
    public func collapse(below bytes: UInt64) -> Int {
        var collapsed = 0
        var stack: [DiskNode] = [self]
        while let node = stack.popLast() {
            for child in node.children where child.isFolder {
                if child.size < bytes, child.children.contains(where: { $0.role != .smallerFiles }) {
                    let small = DiskNode(name: "", role: .smallerFiles, parent: child)
                    small.size = child.size
                    small.files = child.files
                    small.modified = child.modified
                    child.children = child.size > 0 ? [small] : []
                    collapsed += 1
                } else {
                    stack.append(child)
                }
            }
        }
        return collapsed
    }

    public func child(named name: String) -> DiskNode? { children.first { $0.name == name && $0.role != .smallerFiles } }

    /// The largest reclaimable folders beneath, outermost only (a hatched folder's
    /// contents are not listed again).
    public func reclaimable(limit: Int = 12, minimum: UInt64 = 50_000_000) -> [DiskNode] {
        var found: [DiskNode] = []
        var stack: [DiskNode] = [self]
        while let node = stack.popLast() {
            for child in node.children where child.isFolder && child.size >= minimum {
                if child.reclaim != nil { found.append(child) } else { stack.append(child) }
            }
        }
        return Array(found.sorted { $0.size > $1.size }.prefix(limit))
    }
}

public enum DiskClassifier {
    /// The kind a folder's name announces on its own.
    public static func kind(ofName name: String) -> DiskKind? {
        let lower = name.lowercased()
        if lower.hasPrefix("onedrive - ") || lower.hasPrefix("dropbox (") { return .synced }
        switch lower {
        case "src", "code", "projects", "repos", "dev", "work", "workspace", "workspaces", "github.com", "gitlab.com",
            "sites", "development":
            return .code
        case ".codex", ".claude", ".herdr", ".pi", ".cursor", ".aider", ".gemini", ".continue", ".windsurf",
            ".microsandbox", ".omp", ".agents", ".openai", "tries", "worktrees", "experiments", "scratch",
            "playground":
            return .agentScratch
        case ".cargo", ".rustup", ".local", ".npm", ".pnpm-store", "pnpm", ".bun", ".deno", "go", ".gradle", ".m2",
            ".platformio", "mise", ".mise", ".pyenv", ".nvm", ".gem", "gem", ".rbenv", ".espressif", ".arduino15",
            ".config", ".vscode", ".zig", ".rye", ".conda", "anaconda3", "miniconda3", ".opam", ".ghcup", ".stack",
            ".julia", ".dotnet", ".android", ".sdkman", ".volta", ".yarn", ".java", ".nuget", "xcode",
            "coresimulator", ".colima", ".docker", ".orbstack", "homebrew", "cellar":
            return .toolchain
        case "sync", "dropbox", "nextcloud", "google drive", "onedrive", "pclouddrive", "mega", ".stversions",
            "mobile documents", "cloudstorage":
            return .synced
        case ".git":
            return .git
        case "pictures", "photos", "music", "videos", "movies", "steam", "steamlibrary", "steamapps", "emulation",
            "models", ".ollama", ".lmstudio", "games", "wineprefix":
            return .media
        case "documents", "desktop", "downloads", "books", "notes", "obsidian", "public", "templates":
            return .documents
        case ".cache", "cache", "caches", ".ccache", ".sccache", "_cacache", "__pycache__", "node_modules", "trash",
            ".trash", "tmp", ".tmp", "deriveddata", "ios devicesupport", "watchos devicesupport":
            return .cache
        case "applications":
            return .apps
        case "system", "usr", "bin", "sbin", "private", "cores":
            return .system
        default:
            return name.hasSuffix(".app") ? .apps : nil
        }
    }

    /// Whether a folder's space can be had back, from its name, its parent's kind
    /// and its siblings.
    public static func reclaim(ofName name: String, parent: DiskKind, hasSibling: (String) -> Bool) -> DiskReclaim? {
        switch name.lowercased() {
        case ".cache", "cache", "caches", ".ccache", ".sccache", "_cacache", "npm-cache", "ios devicesupport",
            "watchos devicesupport":
            return .regenerable
        case ".stversions":
            return .syncHistory
        case ".pnpm-store", "pnpm":
            return .packageStore
        case "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".next", ".turbo", ".parcel-cache",
            "deriveddata":
            return .buildOutput
        case "logs" where hasSibling("Application Support"):
            return .temporary
        case "target" where hasSibling("Cargo.toml"):
            return .buildOutput
        case ".build" where hasSibling("Package.swift"):
            return .buildOutput
        case "node_modules" where hasSibling("package.json"):
            return .reinstallable
        case "layers" where parent == .agentScratch:
            return .sandboxLayers
        case "snapshots" where parent == .agentScratch:
            return .snapshots
        case "trash", ".trash":
            return .trash
        case "tmp", ".tmp", "temp":
            return .temporary
        default:
            return nil
        }
    }

    /// A bare git repository: HEAD beside objects and refs.
    static func isGitStore(_ node: DiskNode) -> Bool {
        node.markers.contains(.gitHead) && node.child(named: "objects") != nil && node.child(named: "refs") != nil
    }

    /// An unknown folder's kind from what fills it: the first recognisable name
    /// down its largest folders, three levels deep.
    static func dominantKind(_ node: DiskNode) -> DiskKind? {
        var current = node
        for _ in 0..<3 {
            let folders = current.children.filter(\.isFolder)
            if let found = folders.lazy.compactMap({ kind(ofName: $0.name) ?? (isGitStore($0) ? .git : nil) }).first {
                return found
            }
            guard let largest = folders.first else { return nil }
            current = largest
        }
        return nil
    }

    static func hasSibling(_ parent: DiskNode, _ name: String) -> Bool {
        switch name {
        case "Cargo.toml": return parent.markers.contains(.cargoManifest)
        case "package.json": return parent.markers.contains(.packageManifest)
        case "Package.swift": return parent.markers.contains(.swiftManifest)
        default: return parent.children.contains { $0.name == name }
        }
    }

    /// Kinds top-down: a folder's own name wins, otherwise it inherits; files take
    /// their folder's. Reclaimable space is inherited, so all of a cache is hatched.
    /// Top-level folders with unknown names take their dominant child's kind.
    public static func classify(_ root: DiskNode) {
        root.kind = kind(ofName: (root.name as NSString).lastPathComponent) ?? .other
        root.reclaim = nil
        var stack: [(DiskNode, Int)] = [(root, 0)]
        while let (node, depth) = stack.popLast() {
            for child in node.children {
                guard child.isFolder else {
                    child.kind = node.kind
                    child.reclaim = node.reclaim
                    continue
                }
                var childKind = kind(ofName: child.name) ?? (isGitStore(child) ? .git : nil)
                // Folders macOS defines hold everything; their contents decide their kinds.
                let neutral = ["users", "library", "volumes", "opt"].contains(child.name.lowercased())
                if childKind == nil, depth == 0, !neutral { childKind = dominantKind(child) }
                child.kind = childKind ?? node.kind
                child.reclaim =
                    node.reclaim ?? reclaim(ofName: child.name, parent: node.kind) { hasSibling(node, $0) }
                stack.append((child, depth + 1))
            }
        }
    }
}

extension DiskNode.Markers {
    public static let swiftManifest = DiskNode.Markers(rawValue: 8)
}

/// Squarified treemap layout (Bruls, Huizing and van Wijk): rectangles as close
/// to square as the sizes allow, largest first, filling `rect` exactly.
public enum Treemap {
    public static func layout(_ sizes: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: sizes.count)
        let total = sizes.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        let area = sizes.map { max(0, $0) * scale }
        var free = rect
        var index = 0
        while index < area.count {
            if area[index] <= 0 {
                index += 1
                continue
            }
            let short = Double(min(free.width, free.height))
            var row = [index]
            var rowArea = area[index]
            var next = index + 1
            while next < area.count, area[next] > 0 {
                let candidate = rowArea + area[next]
                if worst(row.map { area[$0] }, rowArea, short) >= worst(row.map { area[$0] } + [area[next]], candidate, short) {
                    row.append(next)
                    rowArea = candidate
                    next += 1
                } else {
                    break
                }
            }
            // Lay the row along the short side.
            if free.width >= free.height {
                let width = CGFloat(rowArea / Double(free.height))
                var y = free.minY
                for i in row {
                    let height = CGFloat(area[i]) / width
                    result[i] = CGRect(x: free.minX, y: y, width: width, height: height)
                    y += height
                }
                free = CGRect(x: free.minX + width, y: free.minY, width: max(0, free.width - width), height: free.height)
            } else {
                let height = CGFloat(rowArea / Double(free.width))
                var x = free.minX
                for i in row {
                    let width = CGFloat(area[i]) / height
                    result[i] = CGRect(x: x, y: free.minY, width: width, height: height)
                    x += width
                }
                free = CGRect(x: free.minX, y: free.minY + height, width: free.width, height: max(0, free.height - height))
            }
            index = next
        }
        return result
    }

    /// The worst aspect ratio in a row laid along a side of length `side`.
    static func worst(_ row: [Double], _ sum: Double, _ side: Double) -> Double {
        guard let largest = row.max(), let smallest = row.min(), sum > 0, side > 0, smallest > 0 else {
            return .infinity
        }
        let side2 = side * side
        let sum2 = sum * sum
        return max(side2 * largest / sum2, sum2 / (side2 * smallest))
    }
}
