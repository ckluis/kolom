import AppKit
import KolomCore

/// What a Disk Map window shows: one scan, where you are in it, what is selected.
final class DiskMapModel: ObservableObject {
    struct Target: Equatable {
        let path: String
        let name: String
        let startupDisk: Bool
    }
    enum Direction { case left, right, up, down }

    let target: Target
    @Published private(set) var root: DiskNode?
    @Published private(set) var focus: DiskNode?
    @Published private(set) var selection: DiskNode?
    @Published var hover: DiskNode?
    @Published private(set) var isScanning = false
    @Published private(set) var stopped = false
    @Published private(set) var progress = DiskScan.Progress()
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var available: UInt64?
    @Published private(set) var capacity: UInt64?
    private(set) var overview: [(name: String, bytes: UInt64)] = []
    @Published private(set) var marks = DiskMarks()
    @Published var reviewing = false {
        didSet { if reviewing { checkGit() } }
    }
    /// A sentence about the last mark refused or removal finished; cleared on the next action.
    @Published var notice: String?
    @Published private(set) var removing: (done: Int, total: Int)?
    var policy: DiskRemovalPolicy {
        DiskRemovalPolicy(home: FileManager.default.homeDirectoryForCurrentUser.path, scanRoot: target.path)
    }
    /// Levels drawn at once.
    @Published var depth = 3 { didSet { view?.invalidateLayout() } }
    /// What tile areas measure; Age colours by last write.
    @Published var measure = DiskMeasure.size { didSet { view?.invalidateLayout() } }
    /// Dot-folders and dot-files.
    @Published var showHidden = true { didSet { view?.invalidateLayout() } }
    /// Names to light up; the rest dims.
    @Published var filter = "" {
        didSet {
            matches = root.map { DiskFilter.matches(in: $0, query: filter) } ?? []
            view?.needsDisplay = true
        }
    }
    private(set) var matches: Set<ObjectIdentifier> = []
    /// Bumped by `/` to put the cursor in the filter field.
    @Published var filterFocus = 0
    @Published var showingHelp = false
    /// What git says about each marked checkout, for the review.
    @Published private(set) var gitNotes: [String: String] = [:]
    /// Where marks are kept between openings; nil keeps them only while open.
    let storage: URL?
    weak var view: TreemapView?
    /// Closes the Disk Map panel (× or Escape at the top).
    var requestClose: (() -> Void)?
    private var scan: DiskScan?
    private var timer: Timer?
    private var backStack: [DiskNode] = []
    private var forwardStack: [DiskNode] = []

    init(target: Target, storage: URL? = nil) {
        self.target = target
        self.storage = storage
        refreshFreeSpace()
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    // MARK: Scanning

    func start() {
        stop()
        let scan = DiskScan(path: target.path, startupDisk: target.startupDisk)
        self.scan = scan
        root = nil
        focus = nil
        selection = nil
        hover = nil
        backStack = []
        forwardStack = []
        overview = []
        marks.removeAll()
        notice = nil
        stopped = false
        isScanning = true
        let started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self, weak scan] _ in
            guard let self, let scan else { return }
            self.progress = scan.snapshot
            self.overview = Array(scan.overview.prefix(128))
            self.elapsed = Date().timeIntervalSince(started)
            self.view?.needsDisplay = true
        }
        Thread.detachNewThread { [weak self] in
            let finished = scan.run()
            DispatchQueue.main.async {
                guard let self, self.scan === scan else { return }
                self.timer?.invalidate()
                self.timer = nil
                self.isScanning = false
                self.progress = scan.snapshot
                self.elapsed = Date().timeIntervalSince(started)
                self.refreshFreeSpace()
                if finished {
                    self.root = scan.root
                    self.focus = scan.root
                    if !self.filter.isEmpty { self.matches = DiskFilter.matches(in: scan.root, query: self.filter) }
                    self.restoreMarks()
                    self.view?.invalidateLayout()
                } else {
                    self.stopped = true
                }
            }
        }
    }

    func stop() {
        scan?.cancel()
        timer?.invalidate()
        timer = nil
        if isScanning {
            isScanning = false
            stopped = true
        }
    }

    func rescan() { start() }

    /// Releases the tree; the window is closing.
    func close() {
        stop()
        scan = nil
        root = nil
        focus = nil
        selection = nil
        hover = nil
        backStack = []
        forwardStack = []
    }

    func refreshFreeSpace() {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: target.path).resourceValues(forKeys: keys) else { return }
        available = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
        capacity = values.volumeTotalCapacity.map { UInt64(max(0, $0)) }
    }

    // MARK: Moving around

    func select(_ node: DiskNode?) {
        selection = node
        view?.needsDisplay = true
    }

    /// Goes into a folder (a file or smaller files: into the folder holding it),
    /// growing its tile to fill the view.
    func enter(_ node: DiskNode?) {
        guard let node else { return }
        let folder = node.isFolder ? node : node.parent
        guard let folder, folder !== focus, folder.children.contains(where: { $0.size > 0 }) else { return }
        let from = view?.rect(of: folder)
        go(to: folder, select: nil)
        if let from { view?.animateZoom(from: from, inward: true) } else { view?.invalidateLayout() }
    }

    /// Up one folder: the view shrinks back to where this folder sits.
    func goUp() {
        guard let focus, let parent = focus.parent else { return }
        go(to: parent, select: focus)
        if let rect = view?.rect(of: focus) { view?.animateZoom(from: rect, inward: false) }
    }

    /// Shows `folder`, remembering where we were.
    func go(to folder: DiskNode, select: DiskNode?, remember: Bool = true) {
        guard let current = focus, folder !== current else {
            if let select { self.select(select) }
            return
        }
        if remember {
            backStack.append(current)
            forwardStack = []
        }
        focus = folder
        selection = select
        hover = nil
        view?.invalidateLayout()
    }

    /// Opens the folder holding `node` and selects it (from Worth a look, breadcrumbs).
    func reveal(inMap node: DiskNode) {
        let folder = node.parent ?? node
        if let from = view?.rect(of: folder), folder !== focus {
            go(to: folder, select: node)
            view?.animateZoom(from: from, inward: true)
        } else {
            go(to: folder, select: node)
        }
        view?.window?.makeFirstResponder(view)
    }

    func back() {
        guard let previous = backStack.popLast(), let current = focus else { return }
        forwardStack.append(current)
        go(to: previous, select: current.lineage.contains { $0 === previous } ? child(of: previous, toward: current) : nil, remember: false)
    }

    func forward() {
        guard let next = forwardStack.popLast(), let current = focus else { return }
        backStack.append(current)
        go(to: next, select: nil, remember: false)
    }

    /// The child of `ancestor` on the way to `node`.
    private func child(of ancestor: DiskNode, toward node: DiskNode) -> DiskNode? {
        let line = node.lineage
        guard let index = line.firstIndex(where: { $0 === ancestor }), index + 1 < line.count else { return nil }
        return line[index + 1]
    }

    /// Arrow keys: the nearest tile in that direction at the selection's level.
    func move(_ direction: Direction) {
        guard let view, let focus else { return }
        guard let current = selection ?? hover else {
            select(focus.children.first)
            return
        }
        let siblings = view.siblingRects(of: current)
        guard let here = siblings.first(where: { $0.0 === current })?.1 else {
            select(focus.children.first)
            return
        }
        let candidates = siblings.filter { $0.0 !== current }.compactMap { node, rect -> (DiskNode, CGFloat)? in
            let dx = rect.midX - here.midX
            let dy = rect.midY - here.midY
            let ahead: Bool
            switch direction {
            case .left: ahead = rect.maxX <= here.minX + 1
            case .right: ahead = rect.minX >= here.maxX - 1
            case .up: ahead = rect.maxY <= here.minY + 1
            case .down: ahead = rect.minY >= here.maxY - 1
            }
            guard ahead else { return nil }
            let along = direction == .left || direction == .right ? abs(dx) : abs(dy)
            let across = direction == .left || direction == .right ? abs(dy) : abs(dx)
            return (node, along + across * 2)
        }
        if let best = candidates.min(by: { $0.1 < $1.1 }) { select(best.0) }
    }

    /// Tab: the next largest tile beside the selection.
    func nextSibling(reverse: Bool) {
        guard let focus else { return }
        let current = selection ?? focus.children.first
        guard let parent = current?.parent ?? focus as DiskNode? else { return }
        let siblings = parent.children.filter { $0.size > 0 }
        guard !siblings.isEmpty else { return }
        let index = siblings.firstIndex { $0 === current } ?? (reverse ? 0 : -1)
        let next = (index + (reverse ? -1 : 1) + siblings.count) % siblings.count
        select(siblings[next])
    }

    // MARK: Marking and removing

    /// Space: marks or unmarks; explains a refusal instead.
    func toggleMark(_ node: DiskNode?) {
        guard let node, root != nil, removing == nil else { return }
        notice = nil
        switch marks.toggle(node, policy: policy) {
        case .insideMarked(let path)?:
            notice = "Inside \((path as NSString).lastPathComponent), which is marked: unmark it to choose within it"
        case .protected(let reason)?:
            notice = "\(node.title) can’t be removed here · \(reason)"
        case nil:
            break
        }
        saveMarks()
        view?.needsDisplay = true
    }

    func unmark(_ node: DiskNode) {
        marks.unmark(node)
        saveMarks()
        view?.needsDisplay = true
    }

    func clearMarks() {
        marks.removeAll()
        saveMarks()
        view?.needsDisplay = true
    }

    // MARK: Marks kept between openings

    private var marksURL: URL? { storage?.appendingPathComponent("disk-map-marks.json") }

    /// Marks are kept per mapped folder, as paths, so closing the map or Kolom does
    /// not lose a half-made selection.
    func saveMarks() {
        guard let url = marksURL else { return }
        var all = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
        let paths = marks.nodes.map(\.path)
        all[target.path] = paths.isEmpty ? nil : paths
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: url, options: .atomic) }
    }

    /// After a scan, the marks kept for this folder come back where the paths still
    /// exist, checked against the removal rules again.
    func restoreMarks() {
        guard let url = marksURL, let root,
            let all = try? JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: url)),
            let paths = all[target.path], !paths.isEmpty
        else { return }
        var restored = 0
        for path in paths {
            if let node = root.find(path: path), marks.mark(node, policy: policy) == nil { restored += 1 }
        }
        saveMarks()
        if restored > 0 {
            notice = "\(restored) mark\(restored == 1 ? "" : "s") kept from last time · \(StorageFormat.bytes(marks.bytes))"
        }
        view?.needsDisplay = true
    }

    // MARK: Git, before removing a checkout

    /// For each marked folder that is a git checkout: uncommitted changes, commits
    /// on no remote, stashes. Run when the review opens, off the main thread.
    func checkGit() {
        let folders = marks.nodes.filter(\.isFolder).map(\.path)
        gitNotes = [:]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var notes: [String: String] = [:]
            for path in folders where FileManager.default.fileExists(atPath: path + "/.git") {
                notes[path] = Self.gitSummary(path)
            }
            DispatchQueue.main.async { self?.gitNotes = notes }
        }
    }

    static func gitSummary(_ path: String) -> String {
        func git(_ arguments: [String]) -> String? {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            task.arguments = ["-C", path] + arguments
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            guard (try? task.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return task.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
        }
        func lines(_ text: String?) -> Int { text.map { $0.split(separator: "\n").count } ?? 0 }
        guard let status = git(["status", "--porcelain"]) else { return "git could not read this checkout" }
        let changes = lines(status)
        let unpushed = lines(git(["log", "--branches", "--not", "--remotes", "--oneline"]))
        let stashes = lines(git(["stash", "list"]))
        let parts = [
            changes > 0 ? "\(changes) uncommitted change\(changes == 1 ? "" : "s")" : nil,
            unpushed > 0 ? "\(unpushed) commit\(unpushed == 1 ? "" : "s") on no remote" : nil,
            stashes > 0 ? "\(stashes) stash\(stashes == 1 ? "" : "es")" : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? "git: clean, everything pushed" : "git: " + parts.joined(separator: ", ")
    }

    /// Free space once the marks are gone (all on the scanned disk; the scan stays on one).
    var freeAfterMarks: UInt64? { available.map { $0 &+ marks.bytes } }

    /// Removes everything marked, moving it to the Trash or deleting it, one at a
    /// time in the background. Each path is checked again first; the map updates at
    /// once and says how much free space actually came back.
    func removeMarked(permanently: Bool) {
        let items = marks.nodes
        guard !items.isEmpty, removing == nil else { return }
        let before = currentAvailable()
        reviewing = false
        removing = (0, items.count)
        let paths = items.map(\.path)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var removed: [Int] = []
            var failures: [String] = []
            for (index, path) in paths.enumerated() {
                let url = URL(fileURLWithPath: path)
                if !DiskRemovalPolicy.stillTheSame(path) {
                    failures.append("\(url.lastPathComponent): no longer where the scan saw it")
                } else {
                    do {
                        if permanently {
                            try FileManager.default.removeItem(at: url)
                        } else {
                            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                        }
                        removed.append(index)
                    } catch {
                        failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                DispatchQueue.main.async { self?.removing = (index + 1, paths.count) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for index in removed {
                    let node = items[index]
                    node.parent?.remove(node)
                    self.marks.unmark(node)
                    self.saveMarks()
                    if self.selection === node { self.selection = nil }
                    if let focus = self.focus, focus.lineage.contains(where: { $0 === node }) {
                        self.focus = node.parent
                    }
                }
                self.removing = nil
                self.refreshFreeSpace()
                let after = self.currentAvailable()
                let gained = after.flatMap { a in before.map { a > $0 ? a - $0 : 0 } }
                var sentence =
                    "\(permanently ? "Deleted" : "Moved to the Trash"): \(removed.count) of \(paths.count)"
                if let gained {
                    sentence += " · free space \(gained > 0 ? "up \(StorageFormat.bytes(gained))" : "unchanged")"
                    if !permanently, gained == 0 {
                        sentence += " (the Trash still holds it; empty it to get the space back)"
                    }
                }
                if !failures.isEmpty { sentence += " · not removed: " + failures.prefix(3).joined(separator: "; ") }
                self.notice = sentence
                self.view?.invalidateLayout()
            }
        }
    }

    private func currentAvailable() -> UInt64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        return (try? URL(fileURLWithPath: target.path).resourceValues(forKeys: keys))?
            .volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
    }

    // MARK: Actions

    func reveal(_ node: DiskNode) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
    }

    func copyPath(_ node: DiskNode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.path, forType: .string)
    }

    func contextMenu(for node: DiskNode) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
            let target = MenuAction(action)
            item.target = target
            item.representedObject = target
            menu.addItem(item)
        }
        if node.isFolder, node !== focus { add("Open “\(node.title)”") { [weak self] in self?.enter(node) } }
        if marks.isMarked(node) {
            add("Unmark") { [weak self] in self?.unmark(node) }
        } else if !marks.covers(node) {
            add("Mark for Removal") { [weak self] in self?.toggleMark(node) }
        }
        add("Reveal in Finder") { [weak self] in self?.reveal(node) }
        add("Copy Path") { [weak self] in self?.copyPath(node) }
        if focus?.parent != nil {
            menu.addItem(.separator())
            add("Go Up") { [weak self] in self?.goUp() }
        }
        return menu
    }
}

/// A closure as a menu item's target.
final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}
