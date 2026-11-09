import AppKit
import KolomCore

/// What a Disk Map window shows: one scan, where you are in it, what is selected.
final class DiskMapModel: ObservableObject {
    struct Target {
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
    let depth = 3
    weak var view: TreemapView?
    private var scan: DiskScan?
    private var timer: Timer?
    private var backStack: [DiskNode] = []
    private var forwardStack: [DiskNode] = []

    init(target: Target) {
        self.target = target
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
