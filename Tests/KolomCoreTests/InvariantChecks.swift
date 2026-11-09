import CoreGraphics
import Foundation
import KolomCore

/// Randomized invariants for the layout core.
func invariantChecks() throws {
    // Randomized invariants for the layout core, driven the way KolomController
    // drives it: window open/close, moves, stacks, grids, scrolling, display
    // disconnect/reconnect and transfers between displays. After every step each live
    // window is in exactly one workspace, closed windows never return, and geometry
    // stays finite. Seeded, so any failure reproduces.
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
    func checkLayoutInvariants(
        _ spaces: [String: Workspace], live: Set<String>, closed: Set<String>, step: String
    ) {
        var seen: [String: Int] = [:]
        for (key, space) in spaces {
            for id in space.windowIDs { seen[id, default: 0] += 1 }
            for column in space.columns {
                if column.tiles.isEmpty { fatalError("\(step): empty column in \(key)") }
                if !column.width.isFinite || column.width <= 0 { fatalError("\(step): bad width \(column.width)") }
                if column.gridID == nil && column.tiles.count > 3 {
                    fatalError("\(step): ordinary stack of \(column.tiles.count) in \(key)")
                }
            }
            if !space.offset.isFinite || space.offset < 0 { fatalError("\(step): bad offset \(space.offset) in \(key)") }
            if let focus = space.focus, !space.windowIDs.contains(focus) {
                fatalError("\(step): focus \(focus) not in \(key)")
            }
            for frame in space.frames(in: CGRect(x: 64, y: 46, width: 1800, height: 1000)).values {
                if !(frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite) {
                    fatalError("\(step): non-finite frame")
                }
            }
        }
        for id in live where seen[id] != 1 { fatalError("\(step): live window \(id) appears \(seen[id] ?? 0) times") }
        for id in seen.keys where !live.contains(id) {
            fatalError("\(step): \(closed.contains(id) ? "closed" : "unknown") window \(id) is in the layout")
        }
    }
    do {
        let physical = ["P", "L", "R"]
        var totalSteps = 0
        for seed in UInt64(1)...300 {
            var rng = SplitMix64(state: seed)
            var spaces: [String: Workspace] = ["P": Workspace(), "L": Workspace(), "R": Workspace()]
            var memory = DisplayMemory()
            var connected = Set(physical)
            var live = Set<String>()
            var closed = Set<String>()
            var next = 0
            var grids: [UUID] = []
            func keys() -> [String] { physical.filter { connected.contains($0) } }
            func any<T>(_ values: [T]) -> T? {
                values.isEmpty ? nil : values[Int.random(in: 0..<values.count, using: &rng)]
            }
            func display(of id: String) -> String? { spaces.first { $0.value.windowIDs.contains(id) }?.key }
            for step in 0..<120 {
                let action = Int.random(in: 0..<16, using: &rng)
                var label = "seed \(seed) step \(step) action \(action)"
                switch action {
                case 0, 1:  // A window opens on a connected display.
                    guard let key = any(keys()) else { break }
                    let id = "w\(next)"
                    next += 1
                    live.insert(id)
                    spaces[key, default: Workspace()].reconcile(
                        (spaces[key]?.windowIDs ?? []) + [id], defaultWidth: Double.random(in: 300...900, using: &rng))
                    spaces[key]?.reveal(id, viewportWidth: 1800)
                case 2:  // A window closes; refresh reconciles every workspace against live windows.
                    guard let id = any(Array(live)) else { break }
                    live.remove(id)
                    closed.insert(id)
                    for key in Array(spaces.keys) {
                        let ids = spaces[key]!.windowIDs.filter { live.contains($0) }
                        spaces[key]?.reconcile(ids, defaultWidth: 640)
                    }
                    memory.prune(live: live)
                case 3, 4:  // Drag or palette move within a display.
                    guard let source = any(Array(live)), let key = display(of: source),
                        let target = any(spaces[key]!.windowIDs), let placement = any(Placement.allCases)
                    else { break }
                    label += " move \(source)->\(target) \(placement)"
                    _ = spaces[key]?.move(source, to: target, placement: placement)
                case 5:  // Unstack.
                    guard let id = any(Array(live)), let key = display(of: id) else { break }
                    spaces[key]?.extract(id)
                case 6:  // Width and height drags, including absurd values.
                    guard let id = any(Array(live)), let key = display(of: id) else { break }
                    spaces[key]?.setWidth(id, any([Double.random(in: -100...20000, using: &rng), .nan, .infinity])!)
                    spaces[key]?.setHeight(
                        id, height: Double.random(in: -50...3000, using: &rng), availableHeight: 1000)
                    _ = spaces[key]?.accommodateWindowWidth(id, actualWidth: Double.random(in: 0...12000, using: &rng))
                case 7:  // Scrolling and desktop reveal.
                    guard let key = any(keys()) else { break }
                    spaces[key]?.scroll(
                        by: any([Double.random(in: -5000...5000, using: &rng), .greatestFiniteMagnitude])!,
                        viewportWidth: 1800, desktopTail: true)
                case 8:  // A terminal grid is created.
                    guard let key = any(keys()) else { break }
                    let columns = Int.random(in: 1...4, using: &rng)
                    let rows = Int.random(in: 1...3, using: &rng)
                    let ids = (0..<(columns * rows)).map { "g\(next + $0)" }
                    if let group = spaces[key, default: Workspace()].appendGrid(
                        ids, columns: columns, rows: rows, name: "T", viewport: CGSize(width: 1800, height: 1000))
                    {
                        next += ids.count
                        live.formUnion(ids)
                        grids.append(group)
                    }
                case 9:  // Undo of a grid.
                    guard let group = any(grids), let undone = undoGrid(group, in: spaces) else { break }
                    spaces = undone
                case 10:  // A secondary display disconnects.
                    guard let gone = any(["L", "R"].filter { connected.contains($0) }) else { break }
                    connected.remove(gone)
                    memory.reconnect(
                        workspaces: &spaces, connected: physical.filter { connected.contains($0) }, primary: "P",
                        live: live)
                case 11:  // Displays reconnect.
                    connected = Set(physical)
                    memory.reconnect(workspaces: &spaces, connected: physical, primary: "P", live: live)
                case 14:  // A window moves to another connected display (titlebar drag or menu).
                    guard let id = any(Array(live)), let from = display(of: id),
                        let to = any(keys().filter { $0 != from }), let before = spaces[from],
                        let tile = spaces[from]?.remove(id)
                    else { break }
                    label += " transfer \(id) \(from)->\(to)"
                    memory.noteTransfer(id, from: from, in: before, to: to)
                    spaces[to, default: Workspace()].columns.append(Column(width: 640, tiles: [tile]))
                default:  // Clamp after a viewport change (shelf opened, display resized).
                    for key in Array(spaces.keys) {
                        spaces[key]?.clampOffset(
                            viewportWidth: Double.random(in: 260...3000, using: &rng), desktopTail: true)
                    }
                }
                checkLayoutInvariants(spaces, live: live, closed: closed, step: label)
                totalSteps += 1
            }
            // Reconnecting everything returns every live window to a connected display.
            memory.reconnect(workspaces: &spaces, connected: physical, primary: "P", live: live)
            checkLayoutInvariants(spaces, live: live, closed: closed, step: "seed \(seed) final")
            XCTAssertTrue(memory.detached.isEmpty)
        }
        print("PASS: \(totalSteps) randomized layout steps keep every live window in exactly one workspace")
    }

}
