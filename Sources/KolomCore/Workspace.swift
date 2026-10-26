import CoreGraphics
import Foundation

public struct Tile: Codable, Equatable, Identifiable {
    public var id: String
    public var weight: Double
    public init(_ id: String, weight: Double = 1) {
        self.id = id
        self.weight = weight
    }
}
public struct Column: Codable, Equatable, Identifiable {
    public var id: UUID
    public var width: Double
    public var tiles: [Tile]
    public var gridID: UUID?
    public var gridName: String?
    public var gridRows: Int?
    public init(width: Double = 600, tiles: [Tile]) {
        id = UUID()
        self.width = width
        self.tiles = tiles
    }
}
public enum Placement: String, CaseIterable { case before, after, above, below }
public struct Workspace: Codable, Equatable {
    public var columns: [Column] = []
    public var focus: String?
    public var offset: Double = 0
    public init(columns: [Column] = [], focus: String? = nil) {
        self.columns = columns
        self.focus = focus
    }
    public var windowIDs: [String] { columns.flatMap { $0.tiles.map(\.id) } }
    public func columnIndex(_ id: String) -> Int? { columns.firstIndex { $0.tiles.contains { $0.id == id } } }
    public mutating func reconcile(_ ids: [String], defaultWidth: Double) {
        let valid = Set(ids)
        for i in columns.indices { columns[i].tiles.removeAll { !valid.contains($0.id) } }
        columns.removeAll { $0.tiles.isEmpty }
        var known = Set(windowIDs)
        for id in ids where known.insert(id).inserted { columns.append(Column(width: defaultWidth, tiles: [Tile(id)])) }
        if focus == nil || !valid.contains(focus!) { focus = windowIDs.first }
    }
    @discardableResult public mutating func remove(_ id: String) -> Tile? {
        guard let c = columnIndex(id), let t = columns[c].tiles.firstIndex(where: { $0.id == id }) else { return nil }
        let tile = columns[c].tiles.remove(at: t)
        columns.removeAll { $0.tiles.isEmpty }
        if focus == id { focus = windowIDs.first }
        return tile
    }
    @discardableResult public mutating func move(_ source: String, to target: String, placement: Placement) -> Bool {
        guard source != target, let old = columnIndex(source), let dest = columnIndex(target) else { return false }
        if placement == .above || placement == .below {
            // V1 stacks are bounded so every member remains usable on screen.
            if old != dest && columns[dest].tiles.count >= (columns[dest].gridRows ?? 3) { return false }
        }
        let width = columns[old].width
        guard let tile = remove(source), let c = columnIndex(target) else { return false }
        if placement == .before || placement == .after {
            columns.insert(Column(width: width, tiles: [tile]), at: c + (placement == .after ? 1 : 0))
        } else {
            let index = columns[c].tiles.firstIndex { $0.id == target }!
            var stackedTile = tile
            stackedTile.weight = columns[c].tiles.reduce(0) { $0 + $1.weight } / Double(columns[c].tiles.count)
            columns[c].tiles.insert(stackedTile, at: index + (placement == .below ? 1 : 0))
        }
        focus = source
        return true
    }
    public mutating func extract(_ id: String) {
        guard let c = columnIndex(id), columns[c].tiles.count > 1 else { return }
        let anchor = columns[c].tiles.first { $0.id != id }!.id
        _ = move(id, to: anchor, placement: .after)
    }
    public mutating func setWidth(_ id: String, _ width: Double) {
        guard let c = columnIndex(id), width.isFinite else { return }
        let value = max(260, min(10000, width))
        let group = columns[c].gridID
        for i in columns.indices where i == c || (group != nil && columns[i].gridID == group) {
            columns[i].width = value
        }
    }
    /// If an app rejects a narrower request, reserve its actual width for the
    /// entire stack. Never let the layout pretend the native window is smaller.
    @discardableResult public mutating func accommodateWindowWidth(_ id: String, actualWidth: Double) -> Bool {
        guard actualWidth.isFinite, actualWidth > 0, actualWidth <= 10000,
            let c = columnIndex(id), actualWidth > columns[c].width + 4
        else { return false }
        let group = columns[c].gridID
        for i in columns.indices where i == c || (group != nil && columns[i].gridID == group) {
            columns[i].width = actualWidth
        }
        return true
    }
    public mutating func setHeight(_ id: String, height: Double, availableHeight: Double, gap: Double = 16) {
        guard let c = columnIndex(id), columns[c].tiles.count > 1,
            let i = columns[c].tiles.firstIndex(where: { $0.id == id })
        else { return }
        let count = columns[c].tiles.count
        let usable = max(Double(count), availableHeight - gap * Double(count - 1))
        let minimum = min(120, usable / Double(count))
        let value = max(minimum, min(usable - minimum * Double(count - 1), height))
        let others = columns[c].tiles.indices.filter { $0 != i }
        let sum = others.reduce(0.0) { $0 + max(0.001, columns[c].tiles[$1].weight) }
        for j in others {
            columns[c].tiles[j].weight = (1 - value / usable) * max(0.001, columns[c].tiles[j].weight) / sum
        }
        columns[c].tiles[i].weight = value / usable
        if let group = columns[c].gridID {
            let weights = columns[c].tiles.map(\.weight)
            for j in columns.indices
            where j != c && columns[j].gridID == group && columns[j].tiles.count == weights.count {
                for k in weights.indices { columns[j].tiles[k].weight = weights[k] }
            }
        }
    }
    /// A grid is a named, linked group of columns. IDs are column-major.
    @discardableResult public mutating func appendGrid(
        _ ids: [String], columns count: Int, rows: Int, name: String, viewport: CGSize
    ) -> UUID? {
        guard count > 0, rows > 0, count <= 30, rows <= 30, count * rows <= 60, ids.count == count * rows,
            Set(ids).count == ids.count,
            Set(windowIDs).isDisjoint(with: ids), viewport.width.isFinite, viewport.height.isFinite
        else { return nil }
        let width = (viewport.width - Double(count - 1) * 16) / Double(count)
        let height = (viewport.height - Double(rows - 1) * 16) / Double(rows)
        guard width >= 260, height >= 120 else { return nil }
        let group = UUID()
        for c in 0..<count {
            var column = Column(width: width, tiles: ids[(c * rows)..<((c + 1) * rows)].map { Tile($0) })
            column.gridID = group
            column.gridName = String(name.prefix(80))
            column.gridRows = rows
            columns.append(column)
        }
        focus = ids.first
        return group
    }
    public mutating func reveal(_ id: String, viewportWidth: Double, gap: Double = 16) {
        guard let c = columnIndex(id) else { return }
        if let group = columns[c].gridID, let first = columns.firstIndex(where: { $0.gridID == group }),
            let last = columns.lastIndex(where: { $0.gridID == group }),
            columns[first...last].allSatisfy({ $0.gridID == group })
        {
            let width = columns[first...last].reduce(0) { $0 + $1.width } + Double(last - first) * gap
            if width <= viewportWidth + 0.5 {
                offset = columns.prefix(first).reduce(0) { $0 + $1.width + gap }
                focus = id
                clampOffset(viewportWidth: viewportWidth, gap: gap)
                return
            }
        }
        let start = columns.prefix(c).reduce(0) { $0 + $1.width + gap }
        let end = start + columns[c].width
        if start < offset {
            offset = start
        } else if end > offset + viewportWidth {
            offset = columns[c].width > viewportWidth ? start : end - viewportWidth
        }
        clampOffset(viewportWidth: viewportWidth, gap: gap)
        focus = id
    }
    public mutating func clampOffset(viewportWidth: Double, gap: Double = 16, desktopTail: Bool = false) {
        let total = columns.reduce(0) { $0 + $1.width } + Double(max(0, columns.count - 1)) * gap
        offset = max(
            0,
            min(
                offset,
                max(0, desktopTail && !columns.isEmpty ? total + gap + viewportWidth * 0.1 : total - viewportWidth)))
    }
    public func frames(in viewport: CGRect, gap: Double = 16) -> [String: CGRect] {
        var x = viewport.minX - offset
        var result: [String: CGRect] = [:]
        for col in columns {
            let usable = max(0, viewport.height - Double(max(0, col.tiles.count - 1)) * gap)
            let sum = col.tiles.reduce(0) { $0 + max(0.001, $1.weight) }
            var y = viewport.minY
            for tile in col.tiles {
                let h = usable * max(0.001, tile.weight) / sum
                result[tile.id] = CGRect(x: x, y: y, width: col.width, height: h)
                y += h + gap
            }
            x += col.width + gap
        }
        return result
    }
    public func neighbor(of id: String, direction: Int) -> String? {
        guard let c = columnIndex(id), !columns.isEmpty else { return nil }
        return columns[max(0, min(columns.count - 1, c + direction))].tiles.first?.id
    }
}

/// Accessibility coordinates use a top-left origin; AppKit uses a bottom-left origin.
public func accessibilityRect(_ rect: CGRect, primaryTop: Double) -> CGRect {
    CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
}

extension Workspace {
    /// Continuous viewport movement must not mutate the currently focused window.
    public mutating func scroll(by delta: Double, viewportWidth: Double, gap: Double = 16, desktopTail: Bool = false) {
        offset += delta
        clampOffset(viewportWidth: viewportWidth, gap: gap, desktopTail: desktopTail)
    }
}

/// Keep a small piece of off-strip windows on the owning screen. macOS relocates
/// completely off-screen windows. Virtual frames remain unchanged in Workspace.
public func edgeProjectedFrame(_ frame: CGRect, screen: CGRect, sliver: Double = 6) -> CGRect {
    var result = frame
    if frame.maxX <= screen.minX + sliver {
        result.origin.x = screen.minX + sliver - frame.width
    } else if frame.minX >= screen.maxX - sliver {
        result.origin.x = screen.maxX - sliver
    }
    return result
}

/// Park fully off-strip windows at an outer desktop edge so their hidden body
/// cannot cover the adjacent display's workspace.
public func parkedStripFrame(_ frame: CGRect, screens: [CGRect], before: Bool, sliver: Double = 6) -> CGRect {
    guard let outer = screens.min(by: { before ? $0.minX < $1.minX : $0.maxX > $1.maxX }) else { return frame }
    return CGRect(
        x: before ? outer.minX + sliver - frame.width : outer.maxX - sliver, y: outer.minY + 16, width: frame.width,
        height: frame.height)
}

/// Experimental physical parking beyond every connected display. The 110%
/// desktop column contributes a 10% viewport margin outside the global edge.
/// macOS may relocate these requests; callers must inspect actual native bounds.
public func bufferedParkingFrame(_ frame: CGRect, screens: [CGRect], before: Bool, viewportWidth: Double) -> CGRect {
    guard let edge = screens.min(by: { before ? $0.minX < $1.minX : $0.maxX > $1.maxX }) else { return frame }
    let margin = max(16, viewportWidth * 0.1)
    return CGRect(
        x: before ? edge.minX - margin - frame.width : edge.maxX + margin, y: edge.minY + 16, width: frame.width,
        height: frame.height)
}

/// Keep a reachable hit target when an edge is flush with the viewport. During
/// tracking, retain that target even if resizing carries the column off-screen.
public func columnResizeHandleFrame(_ column: CGRect, viewport: CGRect, tracking: Bool = false) -> CGRect? {
    guard viewport.width >= 10, viewport.height > 0,
        tracking || (column.maxX > viewport.minX + 8 && column.maxX <= viewport.maxX + 0.5)
    else { return nil }
    return CGRect(
        x: max(viewport.minX, min(column.maxX - 4, viewport.maxX - 10)), y: viewport.minY, width: 10,
        height: viewport.height)
}

/// Restore a normal window to a wholly usable frame, including when its original
/// monitor is gone or an older session recorded an off-screen parking position.
public func usableRestorationFrame(_ proposed: CGRect, screens: [CGRect], index: Int = 0) -> CGRect {
    guard let primary = screens.first else { return proposed }
    let screen =
        screens.max { a, b in
            let x = a.intersection(proposed)
            let y = b.intersection(proposed)
            return (x.isNull ? 0 : x.width * x.height) < (y.isNull ? 0 : y.width * y.height)
        }.flatMap { $0.intersects(proposed) ? $0 : nil } ?? primary
    let area = screen.insetBy(dx: 16, dy: 16)
    let width = min(max(100, proposed.width), area.width)
    let height = min(max(80, proposed.height), area.height)
    let fallback = CGFloat(index % 8) * 24
    let x = proposed.intersects(screen) ? proposed.minX : area.minX + fallback
    let y = proposed.intersects(screen) ? proposed.minY : area.minY + fallback
    return CGRect(
        x: max(area.minX, min(x, area.maxX - width)), y: max(area.minY, min(y, area.maxY - height)), width: width,
        height: height)
}

public func windowIsReachable(_ frame: CGRect, screens: [CGRect]) -> Bool {
    // At least a useful stretch of title bar and body must be on one display.
    screens.contains { screen in
        let title = CGRect(x: frame.minX, y: frame.minY, width: min(frame.width, 180), height: min(frame.height, 40))
        return screen.contains(title) && frame.intersection(screen).width >= min(180, frame.width)
            && frame.intersection(screen).height >= min(100, frame.height)
    }
}
