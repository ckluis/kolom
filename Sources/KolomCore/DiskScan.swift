import Darwin
import Foundation

/// Scans a folder tree in parallel into `DiskNode`s, staying on one disk. Worker
/// threads take folders from a shared depth-first stack; each lists one folder
/// with `fstatat` and writes only that folder's node. Nothing is opened or read
/// but folder entries.
public final class DiskScan {
    public struct Progress {
        public var files = 0
        public var folders = 0
        public var bytes: UInt64 = 0
        public var unreadable = 0
        public var path = ""
        public init() {}
    }
    /// Files at least this large are kept as their own tiles.
    public static let fileTileMinimum: UInt64 = 1_000_000
    /// Folders smaller than this keep their totals but not their contents.
    public static let folderTileMinimum: UInt64 = 1_000_000
    /// macOS marks cloud-only (dataless) items; listing them would download.
    static let datalessFlag: UInt32 = 0x4000_0000

    public let root: DiskNode
    public let startupDisk: Bool
    private let rootPath: String
    private let condition = NSCondition()
    private var stack: [(node: DiskNode, depth: Int, top: Int)] = []
    private var active = 0
    private var cancelled = false
    private let progressLock = NSLock()
    private var progress = Progress()
    private var overviewNames: [String] = []
    private var overviewBytes: [UInt64] = []
    private let linksLock = NSLock()
    private var links: Set<HardLink> = []
    private var rootDevice: dev_t = 0

    private struct HardLink: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    public init(path: String, startupDisk: Bool = false) {
        rootPath = path
        self.startupDisk = startupDisk
        root = DiskNode(name: path, role: .folder)
    }

    public var snapshot: Progress {
        progressLock.lock()
        defer { progressLock.unlock() }
        return progress
    }

    /// Bytes measured so far under each top-level folder, largest first; not final.
    public var overview: [(name: String, bytes: UInt64)] {
        progressLock.lock()
        defer { progressLock.unlock() }
        return zip(overviewNames, overviewBytes).map { (name: $0, bytes: $1) }.filter { $0.bytes > 0 }
            .sorted { $0.bytes > $1.bytes }
    }

    public var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    public func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    /// Scans, blocking until done or cancelled; then totals and classifies.
    /// Returns false when cancelled.
    @discardableResult
    public func run(threads: Int = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)) -> Bool {
        var info = stat()
        guard lstat(rootPath, &info) == 0 else {
            root.unreadable = 1
            return true
        }
        rootDevice = info.st_dev
        root.modified = Self.date(info.st_mtimespec.tv_sec)
        stack = [(root, 0, -1)]
        let group = DispatchGroup()
        for _ in 0..<max(1, threads) {
            group.enter()
            let thread = Thread { [self] in
                work()
                group.leave()
            }
            thread.qualityOfService = .utility
            thread.stackSize = 1 << 20
            thread.start()
        }
        group.wait()
        linksLock.lock()
        links = []
        linksLock.unlock()
        if isCancelled { return false }
        root.finish()
        DiskClassifier.classify(root)
        // After classifying, which reads names inside small folders too.
        root.collapse(below: Self.folderTileMinimum)
        // Hand the collapsed folders' memory back to macOS now, not eventually.
        malloc_zone_pressure_relief(nil, 0)
        return true
    }

    private func work() {
        while true {
            condition.lock()
            while stack.isEmpty, active > 0, !cancelled { condition.wait() }
            if cancelled || stack.isEmpty {
                condition.broadcast()
                condition.unlock()
                return
            }
            let item = stack.removeLast()
            active += 1
            condition.unlock()
            let found = list(item.node, depth: item.depth, top: item.top)
            condition.lock()
            stack.append(contentsOf: found)
            active -= 1
            condition.broadcast()
            condition.unlock()
        }
    }

    /// Lists one folder; returns its subfolders to scan.
    private func list(_ node: DiskNode, depth: Int, top: Int) -> [(node: DiskNode, depth: Int, top: Int)] {
        let path = node.path
        guard let directory = opendir(path) else {
            node.unreadable += 1
            progressLock.lock()
            progress.unreadable += 1
            progressLock.unlock()
            return []
        }
        defer { closedir(directory) }
        let fd = dirfd(directory)
        var found: [(node: DiskNode, depth: Int, top: Int)] = []
        var files = 0
        var bytes: UInt64 = 0
        var newTops: [(String, Int)] = []
        var info = stat()
        while let entry = readdir(directory) {
            let length = Int(entry.pointee.d_namlen)
            let skip = withUnsafePointer(to: &entry.pointee.d_name) { pointer -> Bool in
                pointer.withMemoryRebound(to: CChar.self, capacity: length + 1) { name in
                    (length == 1 && name[0] == 0x2E) || (length == 2 && name[0] == 0x2E && name[1] == 0x2E)
                        || fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0
                }
            }
            if skip { continue }
            node.modified = max(node.modified, Self.date(info.st_mtimespec.tv_sec))
            let kind = info.st_mode & S_IFMT
            if kind == S_IFDIR {
                // Another disk mounted inside (or a snapshot) is not this disk's space.
                guard info.st_dev == rootDevice else { continue }
                let name = Self.name(entry, length)
                if startupDisk, depth < 2, !StorageScope.enters(path == "/" ? "/" + name : path + "/" + name, startupDisk: true) {
                    continue
                }
                let child = DiskNode(name: name, role: .folder)
                child.modified = Self.date(info.st_mtimespec.tv_sec)
                node.adopt(child)
                var childTop = top
                if depth == 0 {
                    childTop = -2 - newTops.count  // registered below
                    newTops.append((name, newTops.count))
                }
                // A cloud-only folder is shown, never opened.
                if info.st_flags & Self.datalessFlag == 0 { found.append((child, depth + 1, childTop)) }
                continue
            }
            var size = UInt64(max(0, info.st_blocks)) * 512
            if kind != S_IFDIR, info.st_nlink > 1 {
                linksLock.lock()
                let first = links.insert(HardLink(device: info.st_dev, inode: info.st_ino)).inserted
                linksLock.unlock()
                if !first { size = 0 }
            }
            files += 1
            bytes &+= size
            if size >= Self.fileTileMinimum {
                let file = DiskNode(name: Self.name(entry, length), role: .file)
                file.size = size
                file.files = 1
                file.modified = Self.date(info.st_mtimespec.tv_sec)
                node.adopt(file)
            } else {
                node.smallBytes &+= size
                node.smallCount += 1
                // Only a few names matter for classification; most are never made into strings.
                if length == 4 || length == 10 || length == 12 || length == 13 {
                    node.markers.insert(DiskNode.Markers.of(fileName: Self.name(entry, length)))
                }
            }
        }
        progressLock.lock()
        if depth == 0 {
            // Top-level folders get overview slots; files at the top share one.
            let base = overviewNames.count
            for (name, _) in newTops {
                overviewNames.append(name)
                overviewBytes.append(0)
            }
            for index in found.indices where found[index].top <= -2 {
                found[index].top = base + (-2 - found[index].top)
            }
        }
        let slot = top >= 0 ? top : nil
        if let slot { overviewBytes[slot] &+= bytes }
        progress.files += files
        progress.folders += 1
        progress.bytes &+= bytes
        if progress.folders % 64 == 0 || depth < 2 { progress.path = path }
        progressLock.unlock()
        return found
    }

    /// A modification date, ignoring dates in the future (a wrong clock or a
    /// stamped archive would otherwise say "in 5 years").
    static let now = Date().timeIntervalSince1970
    static func date(_ seconds: Int) -> Double { min(Double(seconds), now) }

    private static func name(_ entry: UnsafeMutablePointer<dirent>, _ length: Int) -> String {
        withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: length) {
                String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self)
            }
        }
    }
}
