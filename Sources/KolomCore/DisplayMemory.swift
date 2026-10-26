import Foundation

/// Remembers only still-open windows that were displaced by a disconnected display,
/// and where windows moved to another display came from.
public struct DisplayMemory: Codable {
    /// Where a window lived before it was moved to another display: that display
    /// and the window heading the column to its left (nil when it was first).
    public struct Origin: Codable, Equatable {
        public var display: String
        public var after: String?
        public init(display: String, after: String?) {
            self.display = display
            self.after = after
        }
    }
    public var detached: [String: Workspace] = [:]
    public var origins: [String: Origin] = [:]
    enum CodingKeys: String, CodingKey { case detached, origins }
    public init() {}
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        detached = try container.decodeIfPresent([String: Workspace].self, forKey: .detached) ?? [:]
        // Records written before origins existed have none.
        origins = try container.decodeIfPresent([String: Origin].self, forKey: .origins) ?? [:]
    }
    public mutating func prune(live: Set<String>) {
        for id in Array(detached.keys) {
            let ids = detached[id]!.windowIDs.filter { live.contains($0) }
            detached[id]?.reconcile(ids, defaultWidth: 640)
            if detached[id]?.columns.isEmpty == true { detached.removeValue(forKey: id) }
        }
        origins = origins.filter { live.contains($0.key) }
    }
    /// Call before moving `window` out of `workspace` (on `display`) to `destination`.
    /// The first home is kept across further moves; moving back home clears it.
    public mutating func noteTransfer(
        _ window: String, from display: String, in workspace: Workspace, to destination: String
    ) {
        forget(window)
        if origins[window]?.display == destination {
            origins.removeValue(forKey: window)
            return
        }
        guard origins[window] == nil, let c = workspace.columnIndex(window) else { return }
        let after = workspace.columns[..<c].last { $0.tiles.contains { $0.id != window } }?.tiles.first {
            $0.id != window
        }?.id
        origins[window] = Origin(display: display, after: after)
    }
    public mutating func forget(_ window: String) {
        for id in Array(detached.keys) {
            _ = detached[id]?.remove(window)
            if detached[id]?.columns.isEmpty == true { detached.removeValue(forKey: id) }
        }
    }
    public mutating func reconnect(
        workspaces: inout [String: Workspace], connected: [String], primary: String, live: Set<String>
    ) {
        prune(live: live)
        for id in Array(workspaces.keys).sorted() where !connected.contains(id) {
            guard var old = workspaces.removeValue(forKey: id) else { continue }
            old.reconcile(old.windowIDs.filter { live.contains($0) }, defaultWidth: 640)
            if !old.columns.isEmpty {
                // Do not overwrite an earlier remembered home during another unplug.
                var remembered = old
                for window in old.windowIDs where detached.values.contains(where: { $0.windowIDs.contains(window) }) {
                    _ = remembered.remove(window)
                }
                if !remembered.columns.isEmpty { detached[id] = remembered }
                // A window moved here from a connected display goes back to its place
                // there; everything else joins the primary display at the end. A column
                // whose anchor is itself coming back waits until the anchor is placed.
                var pending: [(column: Column, origin: Origin)] = []
                for column in old.columns {
                    if let origin = column.tiles.compactMap({ origins[$0.id] }).first(where: {
                        $0.display != id && connected.contains($0.display)
                    }) {
                        pending.append((column, origin))
                    } else {
                        workspaces[primary, default: Workspace()].columns.append(column)
                    }
                }
                var placed: [String: Int] = [:]
                while !pending.isEmpty {
                    let waiting = Set(pending.flatMap { $0.column.tiles.map(\.id) })
                    let ready =
                        pending.firstIndex { $0.origin.after.map { !waiting.contains($0) } ?? true } ?? 0
                    let (column, origin) = pending.remove(at: ready)
                    var home = workspaces[origin.display] ?? Workspace()
                    let anchor = origin.after.flatMap { home.columnIndex($0) }
                    // Columns returning to the same place keep their order; a closed anchor
                    // sends the column to the end of its home display.
                    let index: Int
                    if let after = origin.after, let anchor {
                        let key = origin.display + "\u{0}" + after
                        index = min(home.columns.count, anchor + 1 + placed[key, default: 0])
                        placed[key, default: 0] += 1
                    } else if origin.after == nil {
                        let key = origin.display + "\u{0}"
                        index = min(home.columns.count, placed[key, default: 0])
                        placed[key, default: 0] += 1
                    } else {
                        index = home.columns.count
                    }
                    home.columns.insert(column, at: index)
                    workspaces[origin.display] = home
                }
            }
        }
        for id in connected {
            if let home = detached.removeValue(forKey: id) {
                for window in home.windowIDs {
                    for key in Array(workspaces.keys) { _ = workspaces[key]?.remove(window) }
                }
                let current = workspaces[id] ?? Workspace()
                workspaces[id] = Workspace(columns: home.columns + current.columns, focus: home.focus ?? current.focus)
            }
            if workspaces[id] == nil { workspaces[id] = Workspace() }
        }
    }
}

public func animatedStripOffset(from: Double, to: Double, progress: Double) -> Double {
    let t = max(0, min(1, progress))
    let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    return from + (to - from) * eased
}
