import Foundation
import CoreGraphics

public struct AgentRequest: Codable {
    public var id: UUID
    public var session: String
    public var created: Double
    public var action: String
    public var columns: Int?
    public var rows: Int?
    public var displayID: String?
    public var name: String?
    public var operation: UUID?
    public init(
        id: UUID = UUID(), session: String, action: String, columns: Int? = nil, rows: Int? = nil,
        displayID: String? = nil, name: String? = nil, operation: UUID? = nil
    ) {
        self.id = id
        self.session = session
        created = Date().timeIntervalSince1970
        self.action = action
        self.columns = columns
        self.rows = rows
        self.displayID = displayID
        self.name = name
        self.operation = operation
    }
}
public struct AgentSession: Codable {
    public var token: String
    public var pid: Int32
    public var created: Double
    public init(pid: Int32) {
        token = UUID().uuidString + UUID().uuidString
        self.pid = pid
        created = Date().timeIntervalSince1970
    }
}
public struct GridTransaction: Codable {
    public var id: UUID
    public var phase: String
    public var detail: String
    public var displayID: String
    public var columns: Int
    public var rows: Int
    public var name: String
    public var createdIDs: [String] = []
    public var before: [String: Workspace]
    public var groupID: UUID?
    public var verified: Int = 0
    public var updated: Double = Date().timeIntervalSince1970
    public init(id: UUID, displayID: String, columns: Int, rows: Int, name: String, before: [String: Workspace]) {
        self.id = id
        self.displayID = displayID
        self.columns = columns
        self.rows = rows
        self.name = name
        self.before = before
        phase = "creating"
        detail = "Creating distinct Terminal windows"
    }
}

/// Keep parked native windows beside their own display, not on another display's
/// vertical lane. Prefer the side the window left from, then the opposite side.
/// A display with neighbours on both sides (the middle of a row) falls back to
/// its bottom edge: the window stays inside the owner's horizontal span, with
/// only a sliver of its title bar on the owner, so macOS does not relocate it.
/// Return nil only when no candidate is clear of every other display.
public func isolatedParkingFrame(
    _ frame: CGRect, owner: CGRect, screens: [CGRect], before: Bool = true, sliver: Double = 6
) -> CGRect? {
    guard frame.width.isFinite, frame.height.isFinite, frame.minY.isFinite else { return nil }
    let foreign = screens.filter { $0 != owner }
    func clear(_ candidate: CGRect) -> Bool {
        foreign.allSatisfy {
            let overlap = candidate.insetBy(dx: -12, dy: -12).intersection($0)
            return overlap.isNull || overlap.width <= 0 || overlap.height <= 0
        }
    }
    func x(_ left: Bool) -> Double { left ? owner.minX + sliver - frame.width : owner.maxX - sliver }
    for left in [before, !before] {
        let candidate = CGRect(x: x(left), y: frame.minY, width: frame.width, height: frame.height)
        if clear(candidate) { return candidate }
    }
    let margin = 12.0
    guard frame.width <= owner.width - 2 * margin else { return nil }
    for left in [before, !before] {
        let candidate = CGRect(
            x: left ? owner.minX + margin : owner.maxX - margin - frame.width, y: owner.maxY - sliver,
            width: frame.width, height: frame.height)
        if clear(candidate) { return candidate }
    }
    return nil
}

public func undoGridLayout(
    before: [String: Workspace], current: [String: Workspace], live: Set<String>, primary: String? = nil
) -> [String: Workspace] {
    var result = before
    for key in Array(result.keys) {
        let ids = result[key]!.windowIDs.filter { live.contains($0) }
        result[key]?.reconcile(ids, defaultWidth: 640)
    }
    if let fallback = primary ?? current.keys.sorted().first {
        for key in Array(result.keys) where current[key] == nil {
            let displaced = result.removeValue(forKey: key)!
            result[fallback, default: Workspace()].columns.append(contentsOf: displaced.columns)
        }
    }
    var known = Set(result.values.flatMap(\.windowIDs))
    for (display, space) in current {
        for column in space.columns {
            let new = column.tiles.filter { live.contains($0.id) && !known.contains($0.id) }
            for tile in new {
                result[display, default: Workspace()].columns.append(Column(width: 640, tiles: [Tile(tile.id)]))
                known.insert(tile.id)
            }
        }
    }
    return result
}

/// Read a small regular file for the local agent channel. Refuses symlinks,
/// FIFOs, devices and anything larger than `limit`, and never blocks on open,
/// so a same-user process cannot hang Kolom or make it read without bound.
public func readSmallRegularFile(_ url: URL, limit: Int) -> Data? {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= limit else {
        return nil
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16384)
    while data.count <= limit {
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count < 0 { return nil }
        if count == 0 { break }
        data.append(buffer, count: count)
    }
    return data.count <= limit ? data : nil
}
public let agentRequestLimit = 16384
public let agentOperationLimit = 1 << 20

extension GridTransaction {
    /// Operation files are written by Kolom, but any same-user process can edit
    /// them. Check bounds before any arithmetic or window access.
    /// Undo needs the grid this operation placed. A partial undo can be retried.
    public var undoAvailable: Bool { groupID != nil && !createdIDs.isEmpty && phase != "undone" }
    public func isWellFormed(fileID: UUID) -> Bool {
        id == fileID && (1...30).contains(columns) && (1...30).contains(rows) && columns * rows <= 60
            && createdIDs.count <= columns * rows && Set(createdIDs).count == createdIDs.count && name.count <= 80
    }
}

/// Undo one grid operation and nothing else: the grid's linked columns become
/// ordinary single-window columns in the same place. Other columns, displays,
/// later grids and the user's own changes are untouched. Returns nil when the
/// grid is no longer in the layout.
public func undoGrid(_ group: UUID, in workspaces: [String: Workspace], width: Double = 640) -> [String: Workspace]? {
    var result = workspaces
    var found = false
    for key in Array(result.keys) {
        guard var space = result[key], space.columns.contains(where: { $0.gridID == group }) else { continue }
        found = true
        space.columns = space.columns.flatMap { column -> [Column] in
            guard column.gridID == group else { return [column] }
            return column.tiles.map { Column(width: width, tiles: [Tile($0.id)]) }
        }
        result[key] = space
    }
    return found ? result : nil
}
