import AppKit
import KolomCore

/// Colours: one muted hue per kind, lighter with depth; amber is kept for the
/// selection and for space that can be had back.
enum DiskMapPalette {
    static let amber = NSColor(red: 0.91, green: 0.64, blue: 0.24, alpha: 1)
    /// Marked for removal, and everything inside it.
    static let danger = NSColor(red: 0.86, green: 0.28, blue: 0.24, alpha: 1)

    static func base(_ kind: DiskKind, dark: Bool) -> NSColor {
        let (h, s): (CGFloat, CGFloat) = {
            switch kind {
            case .code: return (0.58, 0.34)
            case .agentScratch: return (0.76, 0.28)
            case .toolchain: return (0.47, 0.32)
            case .synced: return (0.53, 0.30)
            case .git: return (0.05, 0.36)
            case .media: return (0.92, 0.28)
            case .documents: return (0.30, 0.30)
            case .cache: return (0.14, 0.18)
            case .apps: return (0.66, 0.30)
            case .system: return (0.60, 0.08)
            case .other: return (0.10, 0.04)
            }
        }()
        return NSColor(hue: h, saturation: s, brightness: dark ? 0.46 : 0.70, alpha: 1)
    }

    static func fill(_ kind: DiskKind, level: Int, dark: Bool) -> NSColor {
        let base = self.base(kind, dark: dark)
        let lift = min(0.45, CGFloat(level) * 0.13)
        return base.blended(withFraction: lift, of: dark ? NSColor(white: 0.62, alpha: 1) : .white) ?? base
    }

    static func background(dark: Bool) -> NSColor { dark ? NSColor(white: 0.11, alpha: 1) : NSColor(white: 0.97, alpha: 1) }

    /// The Age view: warm for recent writes, cooling to grey for old ones.
    static func age(_ age: DiskAge, level: Int, dark: Bool) -> NSColor {
        let (h, s, b): (CGFloat, CGFloat, CGFloat) = {
            switch age {
            case .week: return (0.08, 0.55, 0.85)
            case .month: return (0.11, 0.42, 0.80)
            case .quarter: return (0.16, 0.30, 0.74)
            case .year: return (0.55, 0.16, 0.66)
            case .older: return (0.60, 0.06, 0.58)
            case .unknown: return (0.0, 0.0, 0.62)
            }
        }()
        let base = NSColor(hue: h, saturation: s, brightness: dark ? b * 0.62 : b, alpha: 1)
        let lift = min(0.4, CGFloat(level) * 0.11)
        return base.blended(withFraction: lift, of: dark ? NSColor(white: 0.62, alpha: 1) : .white) ?? base
    }
}

/// One drawn rectangle: a node at a nesting level.
struct TreemapTile {
    let node: DiskNode
    let rect: CGRect
    let level: Int
    /// The inner area its children were laid out in, for folders that were opened.
    let opened: Bool
}

/// Lays out `focus` with nested children, `depth` levels deep, skipping tiles too
/// small to see. Folders get a name band when there is room.
enum TreemapLayout {
    static let gap: CGFloat = 1
    static let band: CGFloat = 17
    static let slimBand: CGFloat = 13

    static func tiles(
        for focus: DiskNode, in bounds: CGRect, depth: Int = 3, measure: DiskMeasure = .size, showHidden: Bool = true
    ) -> [TreemapTile] {
        var tiles: [TreemapTile] = []
        func place(_ nodes: [DiskNode], in rect: CGRect, level: Int) {
            let visible = nodes.filter { measure.value($0) > 0 && (showHidden || !$0.isHidden) }
                .sorted { measure.value($0) > measure.value($1) }
            let rects = Treemap.layout(visible.map { measure.value($0) }, in: rect)
            for (node, frame) in zip(visible, rects) {
                let inset = frame.insetBy(dx: gap / 2, dy: gap / 2)
                guard inset.width >= 2, inset.height >= 2 else { continue }
                let header = level == 0 ? band : slimBand
                let canOpen =
                    node.isFolder && level < depth - 1 && !node.children.isEmpty && inset.width > 28
                    && inset.height > header + 14
                tiles.append(TreemapTile(node: node, rect: inset, level: level, opened: canOpen))
                if canOpen {
                    let inner = CGRect(
                        x: inset.minX + 2, y: inset.minY + header, width: inset.width - 4,
                        height: inset.height - header - 2)
                    place(node.children, in: inner, level: level + 1)
                }
            }
        }
        place(focus.children, in: bounds, level: 0)
        return tiles
    }
}

/// The treemap itself. Drawn with Core Graphics in flipped coordinates; tiles are
/// recomputed only when the focus or size changes.
final class TreemapView: NSView {
    var model: DiskMapModel? {
        didSet { invalidateLayout() }
    }
    private var tiles: [TreemapTile] = []
    private var laidOutFor: (ObjectIdentifier, CGSize)?
    private var tracking: NSTrackingArea?
    /// Zoom animation: a layout region drawn into a destination, eased over time.
    private var animation: (start: CFTimeInterval, from: CGRect, inward: Bool)?
    private var animationTimer: Timer?
    private static let animationLength: CFTimeInterval = 0.26

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    func invalidateLayout() {
        laidOutFor = nil
        needsDisplay = true
    }

    /// Animates going in (the tile grows to fill the view) or up (the view
    /// shrinks back to where the folder sits in its parent).
    func animateZoom(from rect: CGRect, inward: Bool) {
        invalidateLayout()
        animation = (CACurrentMediaTime(), rect, inward)
        animationTimer?.invalidate()
        animationTimer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self, let animation = self.animation else {
                timer.invalidate()
                return
            }
            if CACurrentMediaTime() - animation.start >= Self.animationLength {
                self.animation = nil
                timer.invalidate()
            }
            self.needsDisplay = true
        }
        RunLoop.main.add(animationTimer!, forMode: .common)
    }

    /// Where a node's tile is now, in view coordinates.
    func rect(of node: DiskNode) -> CGRect? {
        ensureLayout()
        return tiles.first { $0.node === node }?.rect
    }

    private func ensureLayout() {
        guard let focus = model?.focus else {
            tiles = []
            return
        }
        let key = (ObjectIdentifier(focus), bounds.size)
        if let laidOutFor, laidOutFor.0 == key.0, laidOutFor.1 == key.1 { return }
        tiles = TreemapLayout.tiles(
            for: focus, in: bounds.insetBy(dx: 1, dy: 1), depth: model?.depth ?? 3, measure: model?.measure ?? .size,
            showHidden: model?.showHidden ?? true)
        laidOutFor = key
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidateLayout()
    }

    // MARK: Drawing

    private var dark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        DiskMapPalette.background(dark: dark).setFill()
        bounds.fill()
        guard let model else { return }
        if model.root == nil {
            drawOverview(model.overview, in: context)
            return
        }
        ensureLayout()
        context.saveGState()
        if let animation {
            let t = min(1, (CACurrentMediaTime() - animation.start) / Self.animationLength)
            let e = CGFloat(1 - pow(1 - t, 3))
            let (region, destination): (CGRect, CGRect) =
                animation.inward
                ? (bounds, lerp(animation.from, bounds, e))
                : (lerp(animation.from, bounds, e), bounds)
            context.clip(to: bounds)
            context.translateBy(x: destination.minX, y: destination.minY)
            context.scaleBy(x: destination.width / region.width, y: destination.height / region.height)
            context.translateBy(x: -region.minX, y: -region.minY)
        }
        for tile in tiles { draw(tile, in: context) }
        // Hover and selection on top, so nested tiles never hide them.
        if animation == nil {
            if let hover = model.hover, let tile = tiles.first(where: { $0.node === hover }) {
                NSColor.white.withAlphaComponent(dark ? 0.10 : 0.22).setFill()
                NSBezierPath(rect: tile.rect).fill()
            }
            if let selection = model.selection, let tile = tiles.first(where: { $0.node === selection }) {
                DiskMapPalette.amber.setStroke()
                let path = NSBezierPath(rect: tile.rect.insetBy(dx: 1, dy: 1))
                path.lineWidth = 2
                path.stroke()
            }
        }
        context.restoreGState()
    }

    private func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    private func draw(_ tile: TreemapTile, in context: CGContext) {
        let node = tile.node
        let age = model?.measure == .age
        var fill =
            age
            ? DiskMapPalette.age(DiskAge.of(node.modified), level: tile.level, dark: dark)
            : node.role == .smallerFiles
                ? DiskMapPalette.fill(node.kind, level: tile.level + 1, dark: dark).withAlphaComponent(0.7)
                : DiskMapPalette.fill(node.kind, level: tile.level, dark: dark)
        // A filter keeps the colour of matches and the folders that hold them.
        let dimmed = model.map { !$0.filter.isEmpty && !$0.matches.contains(ObjectIdentifier(node)) } ?? false
        if dimmed {
            fill = fill.blended(withFraction: 0.78, of: DiskMapPalette.background(dark: dark)) ?? fill
        }
        fill.setFill()
        tile.rect.fill()
        if node.reclaim != nil, !dimmed { hatch(tile.rect, in: context) }
        if let marks = model?.marks, marks.covers(node) {
            DiskMapPalette.danger.withAlphaComponent(marks.isMarked(node) ? 0.62 : 0.30).setFill()
            tile.rect.fill(using: .sourceOver)
        }
        if tile.level == 0, node.isFolder {
            // A strip of the kind's own colour along the top of a top-level folder.
            DiskMapPalette.base(node.kind, dark: dark).setFill()
            CGRect(x: tile.rect.minX, y: tile.rect.minY, width: tile.rect.width, height: 3).fill()
        }
        let header = tile.level == 0 ? TreemapLayout.band : TreemapLayout.slimBand
        if tile.opened {
            label(node, in: CGRect(x: tile.rect.minX + 5, y: tile.rect.minY + (tile.level == 0 ? 3 : 0), width: tile.rect.width - 10, height: header - 2), level: tile.level)
        } else if tile.rect.width > 46, tile.rect.height > 15 {
            label(node, in: tile.rect.insetBy(dx: 5, dy: 3), level: tile.level, centered: tile.rect.height > 34)
        }
    }

    static func count(_ files: Int) -> String {
        if files >= 1_000_000 { return String(format: "%.1fM files", Double(files) / 1_000_000) }
        if files >= 10_000 { return "\(files / 1000)K files" }
        return files == 1 ? "1 file" : "\(files.formatted()) files"
    }

    private func hatch(_ rect: CGRect, in context: CGContext) {
        context.saveGState()
        context.clip(to: rect)
        context.setStrokeColor(DiskMapPalette.amber.withAlphaComponent(dark ? 0.42 : 0.55).cgColor)
        context.setLineWidth(1)
        let step: CGFloat = 7
        var x = rect.minX - rect.height
        while x < rect.maxX {
            context.move(to: CGPoint(x: x, y: rect.maxY))
            context.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += step
        }
        context.strokePath()
        context.restoreGState()
    }

    private func label(_ node: DiskNode, in rect: CGRect, level: Int, centered: Bool = false) {
        // The number the area stands for: files in the Files view, bytes otherwise.
        let size = model?.measure == .files ? Self.count(node.files) : StorageFormat.bytes(node.size)
        let nameFont = NSFont.systemFont(ofSize: level == 0 ? 11.5 : 10, weight: level == 0 ? .semibold : .medium)
        let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: level == 0 ? 10.5 : 9.5, weight: .regular)
        let ink = dark ? NSColor(white: 1, alpha: 0.9) : NSColor(white: 0.08, alpha: 0.88)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let name = NSAttributedString(
            string: node.title, attributes: [.font: nameFont, .foregroundColor: ink, .paragraphStyle: paragraph])
        let sizeText = NSAttributedString(string: size, attributes: [.font: sizeFont, .foregroundColor: ink.withAlphaComponent(0.7)])
        let sizeWidth = sizeText.size().width
        if centered, rect.height > 30 {
            let nameHeight = name.size().height
            let total = nameHeight + sizeText.size().height
            let y = rect.midY - total / 2
            name.draw(with: CGRect(x: rect.minX, y: y, width: rect.width, height: nameHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            if sizeWidth < rect.width { sizeText.draw(at: CGPoint(x: rect.minX, y: y + nameHeight)) }
            return
        }
        let showSize = rect.width > sizeWidth + 40
        let nameWidth = rect.width - (showSize ? sizeWidth + 6 : 0)
        guard nameWidth > 14 else { return }
        name.draw(with: CGRect(x: rect.minX, y: rect.minY, width: nameWidth, height: rect.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if showSize { sizeText.draw(at: CGPoint(x: rect.maxX - sizeWidth, y: rect.minY + 0.5)) }
    }

    /// While scanning: the top-level folders measured so far, in one muted colour.
    private func drawOverview(_ buckets: [(name: String, bytes: UInt64)], in context: CGContext) {
        let rects = Treemap.layout(buckets.map { Double($0.bytes) }, in: bounds.insetBy(dx: 1, dy: 1))
        let fill = DiskMapPalette.fill(.other, level: 1, dark: dark)
        for (bucket, rect) in zip(buckets, rects) {
            let tile = rect.insetBy(dx: 0.5, dy: 0.5)
            guard tile.width > 2, tile.height > 2 else { continue }
            fill.setFill()
            tile.fill()
            if tile.width > 46, tile.height > 15 {
                let node = DiskNode(name: bucket.name, role: .folder)
                node.size = bucket.bytes
                label(node, in: tile.insetBy(dx: 5, dy: 3), level: 0, centered: tile.height > 34)
            }
        }
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    /// The deepest tile under a point.
    func node(at point: CGPoint) -> DiskNode? {
        ensureLayout()
        return tiles.last { $0.rect.contains(point) }?.node
    }

    /// Space and X act on the tile under the pointer if the pointer moved last,
    /// otherwise on the keyboard's selection.
    private var pointerLast = false

    override func mouseMoved(with event: NSEvent) {
        pointerLast = true
        let point = convert(event.locationInWindow, from: nil)
        let node = self.node(at: point)
        if node !== model?.hover {
            model?.hover = node
            needsDisplay = true
        }
    }

    /// Scrolling over a folder goes into it (toward the pointer), scrolling back goes up:
    /// one step per gesture, with a short pause so momentum does not skip levels.
    private var scrollAccumulated: CGFloat = 0
    private var scrollPausedUntil = Date.distantPast

    override func scrollWheel(with event: NSEvent) {
        guard let model, model.root != nil else { return super.scrollWheel(with: event) }
        if event.phase == .began || event.phase == .ended { scrollAccumulated = 0 }
        guard Date() > scrollPausedUntil, event.momentumPhase == [] else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        scrollAccumulated += delta
        guard abs(scrollAccumulated) > 24 else { return }
        let inward = scrollAccumulated > 0
        scrollAccumulated = 0
        zoom(inward: inward, at: convert(event.locationInWindow, from: nil))
    }

    /// Pinching does the same as scrolling: apart goes in, together goes up.
    private var pinchAccumulated: CGFloat = 0

    override func magnify(with event: NSEvent) {
        guard model?.root != nil else { return super.magnify(with: event) }
        if event.phase == .began { pinchAccumulated = 0 }
        guard Date() > scrollPausedUntil else { return }
        pinchAccumulated += event.magnification
        guard abs(pinchAccumulated) > 0.12 else { return }
        let inward = pinchAccumulated > 0
        pinchAccumulated = 0
        zoom(inward: inward, at: convert(event.locationInWindow, from: nil))
    }

    /// One step in (into the folder at this level under the pointer) or out.
    private func zoom(inward: Bool, at point: CGPoint) {
        guard let model else { return }
        scrollPausedUntil = Date().addingTimeInterval(0.45)
        if inward {
            var hit = node(at: point)
            while let current = hit, let parent = current.parent, parent !== model.focus { hit = parent }
            if let folder = hit, folder.isFolder { model.enter(folder) }
        } else {
            model.goUp()
        }
    }

    override func mouseExited(with event: NSEvent) {
        model?.hover = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let node = node(at: point) else { return }
        if event.modifierFlags.contains(.command) {
            model?.toggleMark(node)  // ⌘-click marks without moving the selection
        } else if event.clickCount >= 2 {
            model?.enter(node)
        } else {
            model?.select(node)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let node = node(at: point) else { return nil }
        model?.select(node)
        return model?.contextMenu(for: node)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let model else { return super.keyDown(with: event) }
        if [123, 124, 125, 126, 48].contains(event.keyCode) { pointerLast = false }
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 36, 76: model.enter(model.selection ?? model.hover)  // return, enter
        case 51, 53:  // delete, escape
            if event.keyCode == 53, !model.filter.isEmpty {
                model.filter = ""
            } else if model.isScanning, event.keyCode == 53 {
                model.stop()
            } else if event.keyCode == 53, model.focus?.parent == nil {
                model.requestClose?()
            } else {
                model.goUp()
            }
        case 123: command ? model.back() : model.move(.left)
        case 124: command ? model.forward() : model.move(.right)
        case 125: model.move(.down)
        case 126: model.move(.up)
        case 48: model.nextSibling(reverse: event.modifierFlags.contains(.shift))  // tab
        default:
            switch event.charactersIgnoringModifiers {
            case " ", "x": model.toggleMark(pointerLast ? (model.hover ?? model.selection) : (model.selection ?? model.hover))
            case "c": if !model.marks.isEmpty { model.reviewing = true }
            case "[" where command: model.back()
            case "]" where command: model.forward()
            case "[": model.depth = max(1, model.depth - 1)
            case "]": model.depth = min(6, model.depth + 1)
            case "/": model.filterFocus += 1
            case "t": model.measure = DiskMeasure.allCases[(DiskMeasure.allCases.firstIndex(of: model.measure)! + 1) % 3]
            case ".": model.showHidden.toggle()
            case "?": model.showingHelp = true
            case "r" where command: model.rescan()
            case "o": if let node = model.selection { model.reveal(node) }
            default: super.keyDown(with: event)
            }
        }
    }

    /// Tiles at the same level as `node`, inside the same folder, for arrow keys.
    func siblingRects(of node: DiskNode) -> [(DiskNode, CGRect)] {
        ensureLayout()
        guard let parent = node.parent else { return [] }
        return tiles.filter { $0.node.parent === parent }.map { ($0.node, $0.rect) }
    }
}
