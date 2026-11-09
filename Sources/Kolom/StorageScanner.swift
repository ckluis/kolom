import AppKit
import DiskArbitration
import Darwin
import KolomCore

/// A mounted disk as the storage view lists it.
struct StorageVolume: Identifiable, Equatable {
    let url: URL
    let name: String
    let total: UInt64
    /// Available for important use, as Finder counts it (purgeable space included).
    let available: UInt64
    let kind: String
    let startup: Bool
    var id: String { url.path }
    var used: UInt64 { total > available ? total - available : 0 }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func mounted() -> [StorageVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey, .volumeIsLocalKey,
            .volumeIsRootFileSystemKey, .volumeIsRemovableKey,
        ]
        let session = DASessionCreate(kCFAllocatorDefault)
        let volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [
            .skipHiddenVolumes
        ]) ?? []).compactMap { url -> StorageVolume? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                let total = values.volumeTotalCapacity, total > 0
            else { return nil }
            let available =
                values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
                ?? UInt64(max(0, values.volumeAvailableCapacity ?? 0))
            let startup = values.volumeIsRootFileSystem ?? (url.path == "/")
            return StorageVolume(
                url: url, name: values.volumeName ?? url.lastPathComponent, total: UInt64(total),
                available: min(available, UInt64(total)),
                kind: kind(of: url, session: session, isInternal: values.volumeIsInternal, local: values.volumeIsLocal,
                    removable: values.volumeIsRemovable, startup: startup),
                startup: startup)
        }
        // The startup disk first, then the rest by name.
        return volumes.sorted { ($0.startup ? 0 : 1, $0.name) < ($1.startup ? 0 : 1, $1.name) }
    }

    private static func kind(
        of url: URL, session: DASession?, isInternal: Bool?, local: Bool?, removable: Bool?, startup: Bool
    ) -> String {
        if startup { return "Startup disk" }
        if local == false { return "Network" }
        if let session, let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
            let description = DADiskCopyDescription(disk) as? [String: Any]
        {
            let model = description[kDADiskDescriptionDeviceModelKey as String] as? String ?? ""
            let transport = description[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? ""
            if model.localizedCaseInsensitiveContains("disk image") || transport == "Virtual Interface" {
                return "Disk image"
            }
            if !transport.isEmpty, isInternal != true { return "External · \(transport)" }
        }
        if isInternal == true { return "Internal" }
        return removable == true ? "Removable" : "External"
    }
}

/// Scans one disk's folders on a background thread, only while the storage view
/// shows that disk. Sizes are allocated bytes from stat; nothing is opened or read.
final class StorageScanner: ObservableObject {
    enum State: Equatable {
        case idle
        case scanning
        case finished(seconds: Double)
        case cancelled
    }
    @Published private(set) var state = State.idle
    /// Bumped while scanning so the view refreshes.
    @Published private(set) var revision = 0
    private(set) var volume: StorageVolume?
    private(set) var root: StorageFolder?
    /// Guards the tree: the scan thread writes, the view reads.
    let lock = NSLock()
    private var cancelled = false
    private var current = ""
    private var scannedFiles = 0
    private var timer: Timer?

    var progress: (files: Int, path: String) {
        lock.lock()
        defer { lock.unlock() }
        return (scannedFiles, current)
    }

    func scan(_ volume: StorageVolume) {
        cancel()
        self.volume = volume
        let root = StorageFolder(name: volume.url.path)
        lock.lock()
        self.root = root
        cancelled = false
        scannedFiles = 0
        lock.unlock()
        state = .scanning
        startRefreshing()
        let threshold = StorageScope.trimThreshold(usedBytes: volume.used)
        let started = Date()
        Thread.detachNewThread { [self] in
            Thread.current.qualityOfService = .utility
            self.walk(volume.url.path, into: root, startupDisk: volume.startup, trimBelow: threshold)
            DispatchQueue.main.async {
                self.timer?.invalidate()
                self.timer = nil
                self.revision += 1
                if self.state == .scanning {
                    self.state = self.isCancelled ? .cancelled : .finished(seconds: Date().timeIntervalSince(started))
                }
            }
        }
    }

    /// Fills in a folder whose subfolders were dropped because it is small.
    func expand(_ folder: StorageFolder) {
        guard folder.trimmed, let volume else { return }
        let path = folder.path
        Thread.detachNewThread { [self] in
            Thread.current.qualityOfService = .userInitiated
            let scan = StorageFolder(name: path)
            self.walk(path, into: scan, startupDisk: volume.startup, trimBelow: 0, reportProgress: false)
            self.lock.lock()
            folder.adopt(scan)
            self.lock.unlock()
            DispatchQueue.main.async { self.revision += 1 }
        }
    }

    /// Back to the disk list: the tree is released.
    func forget() {
        cancel()
        lock.lock()
        root = nil
        lock.unlock()
        volume = nil
        state = .idle
        revision += 1
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        if state == .scanning { state = .cancelled }
        timer?.invalidate()
        timer = nil
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func startRefreshing() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.revision += 1 }
    }

    /// fts, physical, staying on the disk it starts on. Holds the lock in batches.
    private func walk(
        _ start: String, into root: StorageFolder, startupDisk: Bool, trimBelow threshold: UInt64,
        reportProgress: Bool = true
    ) {
        guard let cPath = strdup(start) else { return }
        defer { free(cPath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
        defer { fts_close(fts) }
        var stack: [StorageFolder] = []
        var ledger = HardLinkLedger()
        var batch = 0
        lock.lock()
        defer { lock.unlock() }
        while let entry = fts_read(fts) {
            batch += 1
            if batch >= 2048 {
                batch = 0
                if cancelled { return }
                lock.unlock()
                lock.lock()
            }
            let item = entry.pointee
            let level = Int(item.fts_level)
            switch Int32(item.fts_info) {
            case FTS_D:
                let path = String(cString: item.fts_path)
                if level > 0, !StorageScope.enters(path, startupDisk: startupDisk) {
                    fts_set(fts, entry, FTS_SKIP)
                    continue
                }
                if stack.count > level { stack.removeSubrange(level...) }
                guard level == 0 || stack.count == level else { continue }
                let folder = level == 0 ? root : stack[level - 1].child(named: (path as NSString).lastPathComponent)
                stack.append(folder)
                if reportProgress { current = path }
            case FTS_DP:
                // The scan left this folder; level 0 is the disk itself and keeps everything.
                if level > 0, level < stack.count { stack[level].finish(trimBelow: threshold) }
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard level > 0, level - 1 < stack.count, let stat = item.fts_statp?.pointee else { continue }
                if ledger.count(inode: UInt64(stat.st_ino), links: stat.st_nlink) {
                    stack[level - 1].addFile(bytes: UInt64(max(0, stat.st_blocks)) * 512)
                }
                if reportProgress { scannedFiles += 1 }
            case FTS_DNR, FTS_ERR:
                if level > 0, level - 1 < stack.count { stack[level - 1].addUnreadable() }
            default:
                break
            }
        }
    }
}

extension StorageScanner {
    /// The largest files directly inside a folder, read when it is shown.
    static func largestFiles(in path: String, limit: Int = 12) -> [(name: String, size: UInt64)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys, options: [])
        else { return [] }
        return urls.compactMap { url -> (String, UInt64)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                return nil
            }
            let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
            return (url.lastPathComponent, UInt64(max(0, size)))
        }.sorted { $0.1 > $1.1 }.prefix(limit).map { (name: $0.0, size: $0.1) }
    }
}
