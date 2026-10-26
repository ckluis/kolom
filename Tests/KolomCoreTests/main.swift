import CoreGraphics
import Foundation
import KolomCore
final class WorkspaceTests {
    func testStackKeepsTargetWidthAndWindowOrder() {
        var w = Workspace(columns: [Column(width: 620, tiles: [Tile("a")]), Column(width: 400, tiles: [Tile("b")])])
        XCTAssertTrue(w.move("a", to: "b", placement: .below))
        XCTAssertEqual(w.columns.count, 1)
        XCTAssertEqual(w.windowIDs, ["b", "a"])
        XCTAssertEqual(w.columns[0].width, 400)
        let frames = w.frames(in: CGRect(x: 72, y: 40, width: 1000, height: 800))
        XCTAssertEqual(frames["a"]!.width, frames["b"]!.width)
        XCTAssertEqual(frames["b"]!.maxY + 16, frames["a"]!.minY)
        XCTAssertEqual(frames["a"]!.maxY, 840)
    }
    func testFullStackRejectsWithoutLosingWindow() {
        var w = Workspace(columns: [Column(tiles: [Tile("a")]), Column(tiles: [Tile("b"), Tile("c"), Tile("d")])])
        let before = w
        XCTAssertFalse(w.move("a", to: "c", placement: .above))
        XCTAssertEqual(w, before)
    }
    func testReorderingWithinStackAndExtracting() {
        var w = Workspace(columns: [Column(tiles: [Tile("a"), Tile("b")])])
        XCTAssertTrue(w.move("b", to: "a", placement: .above))
        XCTAssertEqual(w.windowIDs, ["b", "a"])
        w.extract("b")
        XCTAssertEqual(w.columns.count, 2)
        XCTAssertEqual(w.windowIDs, ["a", "b"])
        XCTAssertEqual(Set(w.windowIDs).count, 2)
    }
    func testFocusRevealsAndClampsAfterRemoval() {
        var w = Workspace(columns: [
            Column(width: 600, tiles: [Tile("a")]), Column(width: 600, tiles: [Tile("b")]),
            Column(width: 600, tiles: [Tile("c")]),
        ])
        w.reveal("c", viewportWidth: 1000)
        XCTAssertEqual(w.offset, 832)
        _ = w.remove("c")
        w.clampOffset(viewportWidth: 1000)
        XCTAssertEqual(w.offset, 216)
        w.reveal("a", viewportWidth: 1000)
        XCTAssertEqual(w.offset, 0)
    }
    func testReconcileDoesNotDestroyGroups() {
        var w = Workspace(
            columns: [Column(tiles: [Tile("a"), Tile("b")]), Column(tiles: [Tile("gone")])], focus: "gone")
        w.reconcile(["a", "b", "new"], defaultWidth: 500)
        XCTAssertEqual(w.columns[0].tiles.map(\.id), ["a", "b"])
        XCTAssertEqual(w.windowIDs, ["a", "b", "new"])
        XCTAssertEqual(w.focus, "a")
    }
    func testWeightedResizeAndNegativeDisplayCoordinates() {
        var w = Workspace(columns: [Column(tiles: [Tile("a"), Tile("b")])])
        w.setHeight("a", height: 200, availableHeight: 800)
        let f = w.frames(in: CGRect(x: -1440, y: -900, width: 1440, height: 800))
        XCTAssertEqual(f["a"]!.height, 200, accuracy: 0.01)
        XCTAssertEqual(f["b"]!.maxY, -100, accuracy: 0.01)
        XCTAssertEqual(
            accessibilityRect(CGRect(x: -1440, y: -900, width: 1440, height: 800), primaryTop: 900).minY, 1000)
    }
    func testCrossDisplayTransferPreservesUniqueMembership() {
        var a = Workspace(columns: [Column(tiles: [Tile("a"), Tile("b")])])
        var b = Workspace()
        let t = a.remove("b")!
        b.columns.append(Column(tiles: [t]))
        b.reconcile(["b"], defaultWidth: 500)
        XCTAssertEqual(a.windowIDs, ["a"])
        XCTAssertEqual(b.windowIDs, ["b"])
    }
}

func XCTAssertTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    if !value { fatalError("Expected true", file: file, line: line) }
}
func XCTAssertFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    XCTAssertTrue(!value, file: file, line: line)
}
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) {
    if a != b { fatalError("Expected \(a) == \(b)", file: file, line: line) }
}
func XCTAssertEqual(_ a: Double, _ b: Double, accuracy: Double, file: StaticString = #file, line: UInt = #line) {
    if abs(a - b) > accuracy { fatalError("Expected \(a) ≈ \(b)", file: file, line: line) }
}
let checks = WorkspaceTests()
checks.testStackKeepsTargetWidthAndWindowOrder()
checks.testFullStackRejectsWithoutLosingWindow()
checks.testReorderingWithinStackAndExtracting()
checks.testFocusRevealsAndClampsAfterRemoval()
checks.testReconcileDoesNotDestroyGroups()
checks.testWeightedResizeAndNegativeDisplayCoordinates()
checks.testCrossDisplayTransferPreservesUniqueMembership()
// Long sequences of valid and rejected drops must never duplicate or lose a window.
var stress = Workspace(columns: (0..<30).map { Column(width: Double(300 + $0 * 5), tiles: [Tile("w\($0)")]) })
let expectedIDs = Set(stress.windowIDs)
var seed: UInt64 = 42
func random(_ limit: Int) -> Int {
    seed = seed &* 6364136223846793005 &+ 1
    return Int((seed >> 33) % UInt64(limit))
}
for _ in 0..<1000 {
    let source = "w\(random(30))"
    let target = "w\(random(30))"
    _ = stress.move(source, to: target, placement: Placement.allCases[random(4)])
    stress.reveal(source, viewportWidth: 1100)
    XCTAssertEqual(Set(stress.windowIDs), expectedIDs)
    XCTAssertEqual(stress.windowIDs.count, 30)
    XCTAssertTrue(stress.columns.allSatisfy { !$0.tiles.isEmpty && $0.tiles.count <= 3 })
    XCTAssertTrue(stress.offset >= 0)
}
let encoded = try JSONEncoder().encode(stress)
XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: encoded), stress)
var tiny = Workspace(columns: [Column(tiles: [Tile("a"), Tile("b")])])
tiny.setHeight("a", height: 2000, availableHeight: 100)
let tinyFrames = tiny.frames(in: CGRect(x: 0, y: 0, width: 300, height: 100))
XCTAssertEqual(tinyFrames["a"]!.height, 42, accuracy: 0.01)
XCTAssertEqual(tinyFrames["b"]!.maxY, 100, accuracy: 0.01)
tiny.setWidth("a", -400)
XCTAssertEqual(tiny.columns[0].width, 260)
tiny.setWidth("b", 5000)
XCTAssertEqual(tiny.columns[0].width, 5000)
tiny.setWidth("b", 20000)
XCTAssertEqual(tiny.columns[0].width, 10000)
var scrolling = Workspace(
    columns: [
        Column(width: 500, tiles: [Tile("a")]), Column(width: 500, tiles: [Tile("b")]),
        Column(width: 500, tiles: [Tile("c")]),
    ], focus: "a")
scrolling.scroll(by: 137, viewportWidth: 800)
XCTAssertEqual(scrolling.offset, 137)
XCTAssertEqual(scrolling.focus, "a")
scrolling.scroll(by: 5000, viewportWidth: 800)
XCTAssertEqual(scrolling.offset, 732)
scrolling.scroll(by: -5000, viewportWidth: 800)
XCTAssertEqual(scrolling.offset, 0)
let screen = CGRect(x: -1440, y: -200, width: 1440, height: 900)
let left = edgeProjectedFrame(CGRect(x: -2500, y: 0, width: 500, height: 600), screen: screen)
let right = edgeProjectedFrame(CGRect(x: 500, y: 0, width: 500, height: 600), screen: screen)
XCTAssertEqual(left.maxX, screen.minX + 6)
XCTAssertEqual(right.minX, screen.maxX - 6)
let visible = CGRect(x: -1200, y: 20, width: 500, height: 600)
XCTAssertEqual(edgeProjectedFrame(visible, screen: screen), visible)
XCTAssertEqual(left.width, 500)
XCTAssertEqual(right.height, 600)
print(
    "PASS: 14 layout scenarios, including continuous scrolling without focus changes, edge projection, 1,000 moves, persistence and geometry"
)

var three = Workspace(columns: [Column(tiles: [Tile("a"), Tile("b")]), Column(tiles: [Tile("c")])])
XCTAssertTrue(three.move("c", to: "b", placement: .below))
three.setHeight("b", height: 260, availableHeight: 900)
let triple = three.frames(in: CGRect(x: 0, y: 0, width: 600, height: 900))
XCTAssertEqual(triple["b"]!.height, 260, accuracy: 0.01)
XCTAssertEqual(triple["c"]!.maxY, 900, accuracy: 0.01)
XCTAssertEqual(triple["a"]!.width, triple["c"]!.width)
print("PASS: three-window stacking and proportional resize")

var desktopTail = Workspace(
    columns: [Column(width: 400, tiles: [Tile("a")]), Column(width: 500, tiles: [Tile("b")])], focus: "b")
desktopTail.scroll(by: 10000, viewportWidth: 800, desktopTail: true)
XCTAssertEqual(desktopTail.offset, 1012)
let uncovered = desktopTail.frames(in: CGRect(x: 64, y: 16, width: 800, height: 900))
XCTAssertTrue(uncovered.values.allSatisfy { $0.maxX < 64 })
desktopTail.clampOffset(viewportWidth: 800, desktopTail: true)
XCTAssertEqual(desktopTail.offset, 1012)
desktopTail.reveal("b", viewportWidth: 800)
XCTAssertEqual(desktopTail.offset, 116)
var emptyTail = Workspace()
emptyTail.scroll(by: 1000, viewportWidth: 800, desktopTail: true)
XCTAssertEqual(emptyTail.offset, 0)
print("PASS: uncovered desktop scrolling, reconciliation clamp, focus return and empty display")

let monitors = [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: 1920, y: -300, width: 2560, height: 1440)]
let parkedRight = parkedStripFrame(CGRect(x: 1950, y: 20, width: 640, height: 900), screens: monitors, before: false)
XCTAssertEqual(parkedRight.minX, 4474)
XCTAssertTrue(parkedRight.intersection(monitors[0]).isNull)
XCTAssertEqual(parkedRight.intersection(monitors[1]).width, 6)
let parkedLeft = parkedStripFrame(CGRect(x: 1500, y: 20, width: 640, height: 900), screens: monitors, before: true)
XCTAssertEqual(parkedLeft.maxX, 6)
XCTAssertTrue(parkedLeft.intersection(monitors[1]).isNull)
print("PASS: off-strip parking avoids covering adjacent monitors")
var displayHistory = DisplayMemory()
var plugSpaces = [
    "primary": Workspace(columns: [Column(width: 500, tiles: [Tile("p")])]),
    "external": Workspace(columns: [
        Column(width: 720, tiles: [Tile("a", weight: 2), Tile("b")]), Column(width: 420, tiles: [Tile("c")]),
    ]),
]
displayHistory.reconnect(
    workspaces: &plugSpaces, connected: ["primary"], primary: "primary", live: ["p", "a", "b", "c"])
XCTAssertEqual(plugSpaces["primary"]!.windowIDs, ["p", "a", "b", "c"])
XCTAssertEqual(displayHistory.detached["external"]!.columns[0].width, 720)
// Closing a remembered window removes its home without losing its stack mates.
displayHistory.prune(live: ["p", "a", "c"])
_ = plugSpaces["primary"]!.remove("b")
displayHistory.reconnect(
    workspaces: &plugSpaces, connected: ["primary", "external"], primary: "primary", live: ["p", "a", "c"])
XCTAssertEqual(plugSpaces["primary"]!.windowIDs, ["p"])
XCTAssertEqual(plugSpaces["external"]!.windowIDs, ["a", "c"])
XCTAssertEqual(plugSpaces["external"]!.columns[0].width, 720)
XCTAssertEqual(plugSpaces["external"]!.columns[0].tiles[0].weight, 2)
XCTAssertTrue(displayHistory.detached.isEmpty)
displayHistory.reconnect(workspaces: &plugSpaces, connected: ["primary"], primary: "primary", live: ["p", "a", "c"])
displayHistory.forget("a")
let offlineRecord = try JSONEncoder().encode(displayHistory)
let restoredRecord = try JSONDecoder().decode(DisplayMemory.self, from: offlineRecord)
XCTAssertEqual(restoredRecord.detached["external"]!.windowIDs, ["c"])
XCTAssertEqual(restoredRecord.detached["external"]!.columns[0].width, 420)
displayHistory.reconnect(
    workspaces: &plugSpaces, connected: ["primary", "external"], primary: "primary", live: ["p", "a", "c"])
XCTAssertEqual(plugSpaces["primary"]!.windowIDs, ["p", "a"])
XCTAssertEqual(plugSpaces["external"]!.windowIDs, ["c"])
XCTAssertEqual(animatedStripOffset(from: 100, to: 1000, progress: 0), 100)
XCTAssertEqual(animatedStripOffset(from: 100, to: 1000, progress: 1), 1000)
var previous = 100.0
for i in 0...100 {
    let value = animatedStripOffset(from: 100, to: 1000, progress: Double(i) / 100)
    XCTAssertTrue(value >= previous && value <= 1000)
    previous = value
}
XCTAssertEqual(animatedStripOffset(from: 1000, to: 100, progress: 0.5), 550)
let persistedHomes = try JSONEncoder().encode(displayHistory)
XCTAssertEqual(try JSONDecoder().decode(DisplayMemory.self, from: persistedHomes).detached.count, 0)
print("PASS: display disconnect/reconnect, grouping, closed-window pruning, explicit moves and animation bounds")

// A window moved to another display returns to its place when that display disconnects.
do {
    var memory = DisplayMemory()
    var spaces = [
        "P": Workspace(columns: ["a", "b", "c", "d"].map { Column(width: 500, tiles: [Tile($0)]) }),
        "E": Workspace(columns: [Column(width: 600, tiles: [Tile("e")])]),
    ]
    func moveToE(_ id: String) {
        let before = spaces["P"]!
        let tile = spaces["P"]!.remove(id)!
        memory.noteTransfer(id, from: "P", in: before, to: "E")
        spaces["E"]!.columns.append(Column(width: 500, tiles: [tile]))
    }
    moveToE("b")
    moveToE("a")
    XCTAssertEqual(memory.origins["b"], DisplayMemory.Origin(display: "P", after: "a"))
    XCTAssertEqual(memory.origins["a"], DisplayMemory.Origin(display: "P", after: nil))
    let live: Set<String> = ["a", "b", "c", "d", "e"]
    memory.reconnect(workspaces: &spaces, connected: ["P"], primary: "P", live: live)
    // "a" was first; "b" followed "a". The external display's own window joins the end.
    XCTAssertEqual(spaces["P"]!.windowIDs, ["a", "b", "c", "d", "e"])
    // Reconnecting sends them back to the external display, in its order.
    memory.reconnect(workspaces: &spaces, connected: ["P", "E"], primary: "P", live: live)
    XCTAssertEqual(spaces["P"]!.windowIDs, ["c", "d"])
    XCTAssertEqual(spaces["E"]!.windowIDs, ["e", "b", "a"])
    // Unplugging again returns them again; the origins persist.
    let saved = try JSONDecoder().decode(DisplayMemory.self, from: try JSONEncoder().encode(memory))
    XCTAssertEqual(saved.origins, memory.origins)
    memory.reconnect(workspaces: &spaces, connected: ["P"], primary: "P", live: live)
    XCTAssertEqual(spaces["P"]!.windowIDs, ["a", "b", "c", "d", "e"])
    memory.reconnect(workspaces: &spaces, connected: ["P", "E"], primary: "P", live: live)
    // Moving a window back home clears its origin; a closed anchor falls back to the end.
    let before = spaces["E"]!
    let tile = spaces["E"]!.remove("b")!
    memory.noteTransfer("b", from: "E", in: before, to: "P")
    spaces["P"]!.columns.insert(Column(width: 500, tiles: [tile]), at: 0)
    XCTAssertTrue(memory.origins["b"] == nil)
    memory.origins["a"] = DisplayMemory.Origin(display: "P", after: "gone")
    memory.reconnect(workspaces: &spaces, connected: ["P"], primary: "P", live: live)
    XCTAssertEqual(spaces["P"]!.windowIDs, ["b", "c", "d", "e", "a"])
    // Records written before origins existed still load.
    let legacy = try JSONDecoder().decode(DisplayMemory.self, from: Data(#"{"detached":{}}"#.utf8))
    XCTAssertTrue(legacy.origins.isEmpty)
    print("PASS: windows moved to another display return to their place when it disconnects; origins persist")
}

let rescueScreens = [
    CGRect(x: 0, y: 28, width: 1920, height: 1052), CGRect(x: -2560, y: -300, width: 2560, height: 1440),
]
for bad in [
    CGRect(x: 4474, y: 16, width: 640, height: 900), CGRect(x: -5000, y: -5000, width: 800, height: 700),
    CGRect(x: 1900, y: 30, width: 900, height: 1500),
] {
    let safe = usableRestorationFrame(bad, screens: rescueScreens)
    XCTAssertTrue(windowIsReachable(safe, screens: rescueScreens))
    XCTAssertTrue(rescueScreens.contains { $0.contains(safe) })
}
let vanishedMonitor = usableRestorationFrame(
    CGRect(x: 2600, y: 100, width: 1200, height: 1000), screens: [rescueScreens[0]])
XCTAssertTrue(rescueScreens[0].contains(vanishedMonitor))
XCTAssertFalse(windowIsReachable(CGRect(x: 1914, y: 40, width: 640, height: 900), screens: [rescueScreens[0]]))
let normal = CGRect(x: 100, y: 100, width: 600, height: 500)
XCTAssertEqual(usableRestorationFrame(normal, screens: rescueScreens), normal)
print("PASS: off-screen recovery, disconnected monitors, oversized windows and verified reachability")

// Repeated app-initiated size/position notifications must never change layout.
var feedback = GeometryFeedback()
let requested = CGRect(x: 80, y: 40, width: 640, height: 1000)
let halfTop = CGRect(x: 80, y: 40, width: 640, height: 500)
let halfBottom = CGRect(x: 80, y: 540, width: 640, height: 500)
feedback.recordWrite("finder", frame: requested, time: 0)
XCTAssertEqual(feedback.decision("finder", actual: halfTop, time: 0.2, userGesture: false), .settling)
XCTAssertEqual(feedback.decision("finder", actual: halfBottom, time: 0.7, userGesture: false), .retry)
feedback.recordWrite("finder", frame: requested, time: 0.7)
for i in 1...250 {
    let observed = i % 2 == 0 ? halfTop : halfBottom
    XCTAssertEqual(feedback.decision("finder", actual: observed, time: Double(i) + 1, userGesture: false), .constrained)
}
XCTAssertEqual(feedback.decision("finder", actual: halfTop, time: 300, userGesture: true), .userChange)
XCTAssertEqual(feedback.decision("finder", actual: requested, time: 300, userGesture: false), .unchanged)
let newTarget = CGRect(x: 96, y: 40, width: 720, height: 1000)
feedback.recordWrite("finder", frame: newTarget, time: 301)
XCTAssertEqual(feedback.decision("finder", actual: halfTop, time: 302, userGesture: false), .retry)
feedback.retain([])
XCTAssertEqual(feedback.decision("finder", actual: halfTop, time: 303, userGesture: false), .unchanged)
print(
    "PASS: bounded geometry retry, 250 alternating half-height app notifications, explicit user resize and target reset"
)

var constrainedStack = Workspace(columns: [
    Column(width: 640, tiles: [Tile("finder"), Tile("notes")]), Column(width: 400, tiles: [Tile("next")]),
])
XCTAssertTrue(constrainedStack.accommodateWindowWidth("finder", actualWidth: 920))
let accommodated = constrainedStack.frames(in: CGRect(x: 64, y: 46, width: 1840, height: 1018))
XCTAssertEqual(accommodated["finder"]!.width, 920)
XCTAssertEqual(accommodated["notes"]!.width, 920)
XCTAssertEqual(accommodated["next"]!.minX, accommodated["finder"]!.maxX + 16)
XCTAssertFalse(constrainedStack.accommodateWindowWidth("finder", actualWidth: 920))
XCTAssertFalse(constrainedStack.accommodateWindowWidth("finder", actualWidth: 640))
XCTAssertFalse(constrainedStack.accommodateWindowWidth("finder", actualWidth: .infinity))
XCTAssertTrue(constrainedStack.accommodateWindowWidth("finder", actualWidth: 1920))
XCTAssertEqual(constrainedStack.columns[0].width, 1920)
print(
    "PASS: accepted native width expands the shared column and preserves the next-column gap, including oversized windows"
)

for owningWidth in [800.0, 1840, 2560] {
    for before in [true, false] {
        let physical = bufferedParkingFrame(
            CGRect(x: 100, y: 20, width: 640, height: 900), screens: monitors, before: before,
            viewportWidth: owningWidth)
        XCTAssertTrue(monitors.allSatisfy { physical.intersection($0).isNull })
        XCTAssertEqual(physical.size, CGSize(width: 640, height: 900))
    }
}
let gridPlan = KolomGuidance.plan(columns: 6, rows: 5, display: 2, viewportWidth: 2560, viewportHeight: 1440)
XCTAssertEqual(gridPlan["windowCount"] as? Int, 30)
XCTAssertEqual(gridPlan["supportedByCurrentEngine"] as? Bool, true)
XCTAssertEqual(gridPlan["executable"] as? Bool, false)
XCTAssertEqual(gridPlan["fitsCurrentSizingLimits"] as? Bool, true)
XCTAssertEqual(KolomGuidance.plan(columns: 6, rows: 3, display: 2)["supportedByCurrentEngine"] as? Bool, true)
XCTAssertEqual(KolomGuidance.plan(columns: 30, rows: 30, display: 2)["ok"] as? Bool, false)
XCTAssertEqual(KolomGuidance.plan(columns: -1, rows: 3, display: 2)["ok"] as? Bool, false)
XCTAssertEqual(KolomGuidance.help("bad")["ok"] as? Bool, false)
print(
    "PASS: 110% desktop geometry and outer-display buffer requests; agent plans enforce current limits and never imply execution"
)

let resizeArea = CGRect(x: 64, y: 46, width: 1840, height: 1018)
let flushColumn = CGRect(x: 1264, y: 46, width: 640, height: 1018)
let flushHandle = columnResizeHandleFrame(flushColumn, viewport: resizeArea)!
XCTAssertTrue(resizeArea.contains(flushHandle))
XCTAssertEqual(flushHandle.maxX, resizeArea.maxX)
let widerColumn = CGRect(x: 1264, y: 46, width: 800, height: 1018)
XCTAssertEqual(columnResizeHandleFrame(widerColumn, viewport: resizeArea), nil)
XCTAssertTrue(resizeArea.contains(columnResizeHandleFrame(widerColumn, viewport: resizeArea, tracking: true)!))
XCTAssertEqual(columnResizeHandleFrame(CGRect(x: -1000, y: 46, width: 640, height: 1018), viewport: resizeArea), nil)
print("PASS: flush-edge resize hit area remains reachable and tracking survives widening past the viewport")

var terminalGrid = Workspace()
let terminalIDs = (0..<18).map { "terminal-\($0)" }
let group = terminalGrid.appendGrid(
    terminalIDs, columns: 6, rows: 3, name: "Build terminals", viewport: CGSize(width: 2928, height: 1630))!
XCTAssertEqual(terminalGrid.columns.count, 6)
XCTAssertTrue(terminalGrid.columns.allSatisfy { $0.gridID == group && $0.tiles.count == 3 })
let gridArea = CGRect(x: -3736, y: -1646, width: 2928, height: 1630)
let gridFrames = terminalGrid.frames(in: gridArea)
XCTAssertEqual(gridFrames.count, 18)
XCTAssertTrue(gridFrames.values.allSatisfy { gridArea.insetBy(dx: -0.01, dy: -0.01).contains($0) })
for (id, rect) in gridFrames {
    for (other, otherRect) in gridFrames where id != other {
        let intersection = rect.intersection(otherRect)
        XCTAssertTrue(intersection.isNull || intersection.width < 0.01 || intersection.height < 0.01)
    }
}
terminalGrid.setWidth(terminalIDs[0], 480)
XCTAssertTrue(terminalGrid.columns.allSatisfy { $0.width == 480 })
terminalGrid.setHeight(terminalIDs[0], height: 400, availableHeight: 1630)
XCTAssertTrue(
    terminalGrid.columns.allSatisfy { abs($0.tiles[0].weight - terminalGrid.columns[0].tiles[0].weight) < 0.0001 })
XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(terminalGrid)), terminalGrid)
var denseGrid = Workspace()
XCTAssertTrue(
    denseGrid.appendGrid(
        (0..<30).map { String($0) }, columns: 6, rows: 5, name: "Dense", viewport: CGSize(width: 2928, height: 1630))
        != nil)
XCTAssertEqual(
    denseGrid.appendGrid(["x"], columns: 6, rows: 5, name: "bad", viewport: CGSize(width: 100, height: 100)), nil)
let beforeUndo = ["display": Workspace(columns: [Column(tiles: [Tile("old")])])]
let currentUndo = [
    "display": Workspace(columns: [Column(tiles: [Tile("old")]), Column(tiles: [Tile("new"), Tile("unrelated")])])
]
let undone = undoGridLayout(before: beforeUndo, current: currentUndo, live: ["old", "new", "unrelated"])
XCTAssertEqual(Set(undone["display"]!.windowIDs), Set(["old", "new", "unrelated"]))
XCTAssertEqual(undone["display"]!.columns.count, 3)
let actualMonitors = [
    CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: -792, y: -1692, width: 3008, height: 1692),
    CGRect(x: -3800, y: -1692, width: 3008, height: 1692),
]
for owner in actualMonitors {
    let sample = CGRect(x: owner.minX + 64, y: owner.minY + 46, width: 640, height: owner.height - 62)
    for before in [true, false] {
        let park = isolatedParkingFrame(sample, owner: owner, screens: actualMonitors, before: before)!
        XCTAssertEqual(park.minY, sample.minY)
        XCTAssertTrue(actualMonitors.filter { $0 != owner }.allSatisfy { park.intersection($0).isNull })
    }
}
let surrounded = [
    CGRect(x: 0, y: 0, width: 1000, height: 1000), CGRect(x: -1000, y: 0, width: 1000, height: 1000),
    CGRect(x: 1000, y: 0, width: 1000, height: 1000),
]
// The middle display of a row has no free side; it parks in a bottom corner
// instead of pausing the whole session.
for before in [true, false] {
    let middle = isolatedParkingFrame(
        CGRect(x: 0, y: 46, width: 640, height: 900), owner: surrounded[0], screens: surrounded, before: before)!
    XCTAssertEqual(middle.minY, 994)
    XCTAssertEqual(middle.minX, before ? 12 : 348)
    XCTAssertTrue(surrounded.dropFirst().allSatisfy { middle.intersection($0).isEmpty })
    XCTAssertEqual(middle.intersection(surrounded[0]).height, 6)
}
// Neighbours on every side and below leave no isolated edge.
let boxedIn =
    surrounded + [
        CGRect(x: -1000, y: 1000, width: 1000, height: 1000), CGRect(x: 0, y: 1000, width: 1000, height: 1000),
        CGRect(x: 1000, y: 1000, width: 1000, height: 1000),
    ]
XCTAssertEqual(
    isolatedParkingFrame(CGRect(x: 0, y: 46, width: 640, height: 900), owner: boxedIn[0], screens: boxedIn), nil)
// A window wider than the boxed display cannot use the bottom edge either.
XCTAssertEqual(
    isolatedParkingFrame(CGRect(x: 0, y: 46, width: 990, height: 900), owner: surrounded[0], screens: surrounded), nil)
XCTAssertEqual(
    isolatedParkingFrame(
        CGRect(x: 0, y: Double.nan, width: 640, height: 900), owner: surrounded[0], screens: [surrounded[0]]),
    nil)
print(
    "PASS: 18/30-window named grids, linked sizing, persistence, non-destructive undo, and per-display parking in the user's three-screen topology"
)

var appendedGrid = Workspace(columns: [Column(width: 640, tiles: [Tile("existing")])])
let appendedIDs = (0..<18).map { "appended-\($0)" }
XCTAssertTrue(
    appendedGrid.appendGrid(
        appendedIDs, columns: 6, rows: 3, name: "Following", viewport: CGSize(width: 2928, height: 1630)) != nil)
appendedGrid.reveal(appendedIDs[0], viewportWidth: 2928)
let appendedFrames = appendedGrid.frames(in: CGRect(x: 0, y: 0, width: 2928, height: 1630))
XCTAssertTrue(
    appendedIDs.allSatisfy { CGRect(x: -0.01, y: -0.01, width: 2928.02, height: 1630.02).contains(appendedFrames[$0]!) }
)
let disconnectedUndo = undoGridLayout(
    before: ["gone": Workspace(columns: [Column(tiles: [Tile("old")])])],
    current: ["primary": Workspace(columns: [Column(tiles: [Tile("new")])])], live: ["old", "new"], primary: "primary")
XCTAssertEqual(Set(disconnectedUndo["primary"]!.windowIDs), Set(["old", "new"]))
XCTAssertEqual(disconnectedUndo["gone"], nil)
print("PASS: appended grids reveal the entire block; undo recovers disconnected-display windows on the primary")

// Launch/reopen must start after recovery, never during or after failed recovery.
let startup = StartupSequence()
var starts = 0
var blockedStarts = 0
var finishRecovery: ((Bool) -> Void)?
func attemptStartup(_ authorized: Bool = true, _ recovery: Bool = false) {
    startup.attempt(
        authorized: authorized, enabled: false, needsRecovery: recovery,
        recover: { finishRecovery = $0 }, enable: { starts += 1 }, blocked: { blockedStarts += 1 })
}
attemptStartup(false)
XCTAssertTrue(startup.requested)
XCTAssertEqual(starts, 0)
attemptStartup(true, true)
XCTAssertTrue(startup.inProgress)
XCTAssertEqual(starts, 0)
attemptStartup()
XCTAssertEqual(starts, 0)
finishRecovery?(true)
XCTAssertEqual(starts, 1)
XCTAssertFalse(startup.inProgress)
finishRecovery?(true)
XCTAssertEqual(starts, 1)
startup.requested = true
attemptStartup(true, true)
finishRecovery?(false)
XCTAssertEqual(starts, 1)
XCTAssertEqual(blockedStarts, 1)
startup.requested = true
attemptStartup(true, true)
startup.requested = false
finishRecovery?(true)
XCTAssertEqual(starts, 1)
startup.requested = true
attemptStartup()
XCTAssertEqual(starts, 2)
print(
    "PASS: automatic launch waits for access and recovery, starts once, blocks failed recovery, respects Pause and supports reopen"
)

let retainedRows = reconcileRetainedWindows(
    discovered: ["visible": 1], previous: ["visible": 1, "minimized": 2, "closed": 3, "unrelated": 4],
    hidden: ["minimized", "closed"], isAlive: { $0 != 3 })
XCTAssertEqual(Set(retainedRows.keys), Set(["visible", "minimized"]))
print(
    "PASS: parked minimized windows survive transient AX discovery gaps; closed and unrelated windows are not retained")

// A large monitor must not silently cap a shared column near half its width.
var wideDisplay = Workspace(columns: [
    Column(width: 640, tiles: [Tile("wide-a"), Tile("wide-b")]), Column(width: 640, tiles: [Tile("next")]),
])
wideDisplay.setWidth("wide-b", 2928)
let wideFrames = wideDisplay.frames(in: CGRect(x: 64, y: 46, width: 2928, height: 1630))
XCTAssertEqual(wideFrames["wide-a"]!.width, 2928)
XCTAssertEqual(wideFrames["wide-b"]!.width, 2928)
XCTAssertEqual(wideFrames["next"]!.minX, wideFrames["wide-a"]!.maxX + 16)
print("PASS: full-width large-display resizing preserves stacked widths and next-column spacing")

var resourceHistory = ResourceHistory(capacity: 3)
resourceHistory.append(0.2)
resourceHistory.append(.nan)
resourceHistory.append(0.8)
resourceHistory.append(0.4)
XCTAssertEqual(resourceHistory.samples.count, 3)
XCTAssertTrue(resourceHistory.samples[0] == nil)
XCTAssertEqual(resourceHistory.samples[1]!, 0.8)
XCTAssertTrue(processCPUShare(previous: nil, current: 100, elapsed: 2, cores: 8) == nil)
XCTAssertTrue(processCPUShare(previous: 200, current: 100, elapsed: 2, cores: 8) == nil)
XCTAssertTrue(processCPUShare(previous: 0, current: 100, elapsed: 0, cores: 8) == nil)
XCTAssertEqual(processCPUShare(previous: 0, current: 8_000_000_000, elapsed: 2, cores: 8)!, 0.5)
print(
    "PASS: bounded resource history preserves gaps and process CPU handles first samples, counter resets, and multicore normalization"
)
XCTAssertEqual(
    processCPUShare(previous: 0, current: 24_000_000, elapsed: 1, cores: 1, nanosecondsPerTick: 1000.0 / 24.0)!, 1)
XCTAssertTrue(processCPUShare(previous: 0, current: 100, elapsed: 1, cores: 1, nanosecondsPerTick: .nan) == nil)
print("PASS: Apple Silicon absolute-time ticks convert correctly to CPU nanoseconds")

// Regression: 0.1.23 crashed twice in refresh() when discovery produced the same
// window ID for two windows (Dictionary(uniqueKeysWithValues:) trap).
do {
    let rows = [
        WindowServerRow(number: 100, frame: CGRect(x: 0, y: 0, width: 800, height: 600), name: "Doc"),
        WindowServerRow(number: 200, frame: CGRect(x: -2000, y: 0, width: 800, height: 600), name: "Doc"),
    ]
    // A parked, retained window keeps its ID even when a new window sits closer to its row.
    let ids = assignWindowIdentities(
        pid: 10,
        candidates: [
            WindowIdentityCandidate(frame: CGRect(x: 0, y: 0, width: 800, height: 600), title: "Doc", fallbackKey: "a"),
            WindowIdentityCandidate(
                frame: CGRect(x: -2000, y: 0, width: 800, height: 600), title: "Doc", retainedID: "10:100",
                fallbackKey: "b"),
        ], rows: rows)
    XCTAssertEqual(ids.map(\.id), ["10:200", "10:100"])
    XCTAssertEqual(ids[1].row, 0)
    // A retained window missing from this pass keeps its identity reserved.
    let gap = assignWindowIdentities(
        pid: 10,
        candidates: [
            WindowIdentityCandidate(frame: CGRect(x: 0, y: 0, width: 800, height: 600), title: "Doc", fallbackKey: "a")
        ], rows: rows, reserved: ["10:100"])
    XCTAssertEqual(gap.map(\.id), ["10:200"])
    // The same retained ID claimed twice, and colliding fallbacks, still yield unique IDs.
    let doubled = assignWindowIdentities(
        pid: 10,
        candidates: [
            WindowIdentityCandidate(frame: .zero, title: "", retainedID: "10:100", fallbackKey: "x"),
            WindowIdentityCandidate(frame: .zero, title: "", retainedID: "10:100", fallbackKey: "x"),
            WindowIdentityCandidate(frame: .zero, title: "", fallbackKey: "x"),
        ], rows: [])
    XCTAssertEqual(doubled[0].id, "10:100")
    XCTAssertEqual(Set(doubled.map(\.id)).count, 3)
    XCTAssertEqual(windowServerNumber(fromID: "10:100", pid: 10), 100)
    XCTAssertTrue(windowServerNumber(fromID: "11:100", pid: 10) == nil)
    XCTAssertTrue(windowServerNumber(fromID: "10:12345678901234", pid: 10) == nil)
    // Randomized: IDs are always unique and every first retained claim survives.
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<2000 {
        let rowCount = Int.random(in: 0...5, using: &generator)
        let numbers = Array(Set((0..<rowCount).map { _ in UInt32.random(in: 1...6, using: &generator) }))
        let randomRows = numbers.map {
            WindowServerRow(
                number: $0,
                frame: Bool.random() ? nil : CGRect(x: Double.random(in: -3000...3000), y: 0, width: 500, height: 400),
                name: Bool.random() ? nil : "t")
        }
        let candidates = (0..<Int.random(in: 0...6, using: &generator)).map { _ in
            WindowIdentityCandidate(
                frame: CGRect(x: Double.random(in: -3000...3000), y: 0, width: 500, height: 400), title: "t",
                retainedID: Bool.random() ? "7:\(Int.random(in: 1...6))" : nil,
                fallbackKey: "\(Int.random(in: 1...3))")
        }
        let reserved = Set((0..<Int.random(in: 0...3)).map { _ in "7:\(Int.random(in: 1...6))" })
        let assigned = assignWindowIdentities(pid: 7, candidates: candidates, rows: randomRows, reserved: reserved)
        XCTAssertEqual(assigned.count, candidates.count)
        XCTAssertEqual(Set(assigned.map(\.id)).count, assigned.count)
        let rowsUsed = assigned.compactMap(\.row)
        XCTAssertEqual(Set(rowsUsed).count, rowsUsed.count)
        var firstClaims = Set<String>()
        for (candidate, identity) in zip(candidates, assigned) {
            if let retained = candidate.retainedID, firstClaims.insert(retained).inserted {
                XCTAssertEqual(identity.id, retained)
            } else {
                XCTAssertTrue(!reserved.contains(identity.id) && !firstClaims.contains(identity.id))
            }
        }
    }
    let byID = uniqueByID(["a", "b", "a"].enumerated().map { $0 }, id: { $0.element })
    XCTAssertEqual(byID.count, 2)
    XCTAssertEqual(byID["a"]!.offset, 0)
    var duplicated = Workspace()
    duplicated.reconcile(["a", "a", "b"], defaultWidth: 500)
    XCTAssertEqual(duplicated.windowIDs, ["a", "b"])
}
print("PASS: window identities stay unique across retained, missing, duplicated and randomized discovery (2,000 cases)")

// Agent channel: unsafe files are refused without blocking; operations are bounds-checked;
// undo touches only its own grid.
do {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kolom-checks-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let small = folder.appendingPathComponent("small.json")
    try! Data("{}".utf8).write(to: small)
    XCTAssertEqual(readSmallRegularFile(small, limit: 16)!, Data("{}".utf8))
    let big = folder.appendingPathComponent("big.json")
    try! Data(repeating: 32, count: 17).write(to: big)
    XCTAssertTrue(readSmallRegularFile(big, limit: 16) == nil)
    let fifo = folder.appendingPathComponent("fifo.json")
    XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
    let started = Date()
    XCTAssertTrue(readSmallRegularFile(fifo, limit: 16) == nil)
    XCTAssertTrue(Date().timeIntervalSince(started) < 1)
    let link = folder.appendingPathComponent("link.json")
    try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: small)
    XCTAssertTrue(readSmallRegularFile(link, limit: 16) == nil)
    XCTAssertTrue(readSmallRegularFile(URL(fileURLWithPath: "/dev/zero"), limit: 16) == nil)

    let opID = UUID()
    var op = GridTransaction(id: opID, displayID: "d", columns: 3, rows: 2, name: "T", before: [:])
    XCTAssertTrue(op.isWellFormed(fileID: opID))
    XCTAssertFalse(op.isWellFormed(fileID: UUID()))
    op.columns = 4_611_686_018_427_387_904
    XCTAssertFalse(op.isWellFormed(fileID: opID))
    op.columns = 3
    op.createdIDs = (0..<7).map(String.init)
    XCTAssertFalse(op.isWellFormed(fileID: opID))

    var space = Workspace(columns: [Column(width: 500, tiles: [Tile("user")])])
    let gridA = space.appendGrid(
        ["a1", "a2", "a3", "a4"], columns: 2, rows: 2, name: "A", viewport: CGSize(width: 1800, height: 1000))!
    let gridB = space.appendGrid(
        ["b1", "b2"], columns: 2, rows: 1, name: "B", viewport: CGSize(width: 1800, height: 1000))!
    let layout = ["main": space, "other": Workspace(columns: [Column(tiles: [Tile("x")])])]
    let undone = undoGrid(gridA, in: layout)!
    XCTAssertEqual(undone["main"]!.windowIDs, ["user", "a1", "a2", "a3", "a4", "b1", "b2"])
    XCTAssertEqual(undone["main"]!.columns.filter { $0.gridID == gridB }.count, 2)
    XCTAssertTrue(undone["main"]!.columns.allSatisfy { $0.gridID != gridA })
    XCTAssertEqual(undone["main"]!.columns[0], space.columns[0])
    XCTAssertEqual(undone["other"]!, layout["other"]!)
    XCTAssertTrue(undoGrid(gridA, in: undone) == nil)
    XCTAssertTrue(undoGrid(UUID(), in: layout) == nil)
}
print(
    "PASS: agent files refuse FIFOs, symlinks, devices and oversize data; operations are bounds-checked; undo is scoped to its own grid"
)

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

// Absence retention: transient gaps and native full screen keep a column; closed windows never return.
do {
    var tracker = AbsenceTracker()
    let previous: Set<String> = ["visible", "elsewhere", "fullScreen", "closed"]
    let alive: (String) -> Bool = { $0 != "closed" }
    let fullScreen: (String) -> Bool = { $0 == "fullScreen" }
    var kept = tracker.retained(
        previous: previous, discovered: ["visible"], now: 100, isAlive: alive, isFullScreen: fullScreen)
    XCTAssertEqual(kept, ["elsewhere", "fullScreen"])
    kept = tracker.retained(
        previous: previous.subtracting(["closed"]), discovered: ["visible"], now: 109, isAlive: alive,
        isFullScreen: fullScreen)
    XCTAssertEqual(kept, ["elsewhere", "fullScreen"])
    // Past the grace period only the full-screen window keeps its column.
    kept = tracker.retained(
        previous: ["visible", "elsewhere", "fullScreen"], discovered: ["visible"], now: 111, isAlive: alive,
        isFullScreen: fullScreen)
    XCTAssertEqual(kept, ["fullScreen"])
    // Returning resets the clock; a dropped window's record is cleared.
    kept = tracker.retained(
        previous: ["visible", "fullScreen"], discovered: ["visible", "fullScreen"], now: 200, isAlive: alive,
        isFullScreen: fullScreen)
    XCTAssertTrue(kept.isEmpty)
    XCTAssertTrue(tracker.missingSince.isEmpty)
}
print("PASS: absent windows keep their column for a grace period or while full screen; closed windows never return")

// Startup hold: saved windows keep their place until found, while Kolom starts.
do {
    var hold = StartupHold(["late", "busy", "quit", "closed", "found"], until: 115)
    let running: (String) -> Bool = { $0 != "quit" }
    let busy: (String) -> Bool = { $0 == "busy" }
    var held = hold.held(discovered: ["found"], now: 100, isRunning: running, isBusy: busy)
    XCTAssertEqual(held, ["late", "busy", "closed"])
    // A window found once is no longer held; absence tracking takes over.
    held = hold.held(discovered: ["late"], now: 105, isRunning: running, isBusy: busy)
    XCTAssertEqual(held, ["busy", "closed"])
    XCTAssertEqual(hold.held(discovered: [], now: 106, isRunning: running, isBusy: busy), ["busy", "closed"])
    // After the grace only a busy app's window waits, and a dropped window never returns.
    held = hold.held(discovered: [], now: 116, isRunning: running, isBusy: busy)
    XCTAssertEqual(held, ["busy"])
    held = hold.held(discovered: [], now: 117, isRunning: running, isBusy: { _ in false })
    XCTAssertTrue(held.isEmpty)
    XCTAssertTrue(hold.held(discovered: [], now: 118, isRunning: running, isBusy: busy).isEmpty)
    XCTAssertEqual(hold.dropped, ["quit", "closed", "busy"])

    // Held windows keep their column and stack through a pass that misses them,
    // instead of rejoining at the end of the strip.
    var space = Workspace(columns: [
        Column(width: 640, tiles: [Tile("a"), Tile("b"), Tile("c")]), Column(width: 640, tiles: [Tile("d")]),
        Column(width: 640, tiles: [Tile("e")]),
    ])
    let columnIDs = space.columns.map(\.id)
    hold = StartupHold(Set(space.windowIDs), until: 115)
    for found in [Set(["d"]), Set(["d", "e", "c"]), Set(["a", "b", "c", "d", "e"])] {
        let keep = hold.held(discovered: found, now: 101, isRunning: { _ in true }, isBusy: { _ in false })
        space.reconcile(space.windowIDs.filter { found.contains($0) || keep.contains($0) }, defaultWidth: 640)
    }
    XCTAssertEqual(space.columns.map { $0.tiles.map(\.id) }, [["a", "b", "c"], ["d"], ["e"]])
    XCTAssertEqual(space.columns.map(\.id), columnIDs)
}
print("PASS: saved windows keep their place and stacks while Kolom starts; quit apps and closed windows are dropped")

// Display staircase: the user's desk (two LG displays side by side above the built-in display).
do {
    let desk: [UInt32: CGRect] = [
        1: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        2: CGRect(x: -792, y: -1692, width: 3008, height: 1692),
        3: CGRect(x: -3800, y: -1692, width: 3008, height: 1692),
    ]
    let stairs = isolatedDisplayArrangement(desk, primary: 1)
    XCTAssertEqual(stairs[1], desk[1])
    XCTAssertTrue(isDisplayStaircase(stairs, primary: 1))
    XCTAssertFalse(isDisplayStaircase(desk, primary: 1))
    XCTAssertEqual(isolatedDisplayArrangement(stairs, primary: 1), stairs)
    // No display shares any part of an edge with another: nothing a column crosses into.
    for (a, ra) in stairs {
        for (b, rb) in stairs where a < b {
            XCTAssertTrue(ra.intersection(rb).isEmpty || ra.intersection(rb).width * ra.intersection(rb).height == 0)
            XCTAssertFalse(ra.maxY > rb.minY && rb.maxY > ra.minY)
        }
    }
    // Sizes kept; a column hanging off any edge of an LG reaches no other display.
    for id in desk.keys { XCTAssertEqual(stairs[id]!.size, desk[id]!.size) }
    for id: UInt32 in [2, 3] {
        let lg = stairs[id]!
        for column in [
            CGRect(x: lg.minX - 400, y: lg.minY + 46, width: 640, height: 1600),
            CGRect(x: lg.maxX - 240, y: lg.minY + 46, width: 640, height: 1600),
        ] {
            for (other, frame) in stairs where other != id { XCTAssertTrue(column.intersection(frame).isNull) }
        }
    }

    // Pointer: crossings follow the desk.
    func route(_ x: Double, _ y: Double, _ dx: Double, _ dy: Double) -> CGPoint? {
        displayPointerDestination(x: x, y: y, deltaX: dx, deltaY: dy, technical: stairs, desk: desk)
    }
    let lg2 = stairs[2]!
    let lg1 = stairs[3]!
    let built = stairs[1]!
    // LG (2) left edge, a third of the way down, lands on LG (1)'s right edge at the same height.
    var p = route(lg2.minX, lg2.minY + 564, -5, 0)
    XCTAssertTrue(p != nil)
    if let p {
        XCTAssertTrue(lg1.contains(p))
        XCTAssertEqual(p.y, lg1.minY + 564, accuracy: 1)
        XCTAssertTrue(p.x > lg1.maxX - 6)
    }
    // And back.
    p = route(lg1.maxX - 1, lg1.minY + 100, 4, 0)
    XCTAssertTrue(p.map { lg2.contains($0) && abs($0.y - (lg2.minY + 100)) <= 1 && $0.x < lg2.minX + 6 } ?? false)
    // Built-in top edge at x = 960 goes up into LG (2) at desk x 960 (LG (2) local x 1752).
    p = route(built.minX + 960, built.minY, 0, -3)
    XCTAssertTrue(p.map { lg2.contains($0) && abs($0.x - (lg2.minX + 1752)) <= 1 && $0.y > lg2.maxY - 6 } ?? false)
    // LG (2) bottom edge above the built-in display goes down; beside it there is nothing below.
    p = route(lg2.minX + 1752, lg2.maxY - 1, 0, 3)
    XCTAssertTrue(p.map { built.contains($0) && abs($0.x - (built.minX + 960)) <= 1 } ?? false)
    XCTAssertTrue(route(lg2.minX + 300, lg2.maxY - 1, 0, 3) == nil)
    // Outer edges and LG (1)'s bottom edge have no desk neighbor; motion inside a display is untouched.
    XCTAssertTrue(route(lg1.minX, lg1.minY + 500, -6, 0) == nil)
    XCTAssertTrue(route(lg2.maxX - 1, lg2.minY + 500, 6, 0) == nil)
    XCTAssertTrue(route(lg1.minX + 900, lg1.maxY - 1, 0, 4) == nil)
    XCTAssertTrue(route(lg2.midX, lg2.midY, -20, 0) == nil)
    // An event that overshoots into the gap is traced back to the edge it crossed.
    p = route(lg2.minX - 8, lg2.minY + 564, -10, 0)
    XCTAssertTrue(p.map { lg1.contains($0) && abs($0.y - (lg1.minY + 564)) <= 2 } ?? false)
    // Equal maps never route.
    XCTAssertTrue(displayPointerDestination(x: 0, y: 0, deltaX: -5, deltaY: 0, technical: desk, desk: desk) == nil)

    // Recovery records move with their display back to desk coordinates.
    let window = CGRect(x: lg1.minX + 200, y: lg1.minY + 46, width: 640, height: 1600)
    XCTAssertEqual(
        deskRect(window, technical: stairs, desk: desk),
        CGRect(x: desk[3]!.minX + 200, y: desk[3]!.minY + 46, width: 640, height: 1600))
    XCTAssertEqual(deskRect(window, technical: desk, desk: desk), window)

    // Controller: applies with .forAppOnly, learns the desk, restores it, keeps it through
    // its own staircase, and adopts a new arrangement the user makes.
    var current = desk
    var writes: [CGConfigureOption] = []
    let state = FileManager.default.temporaryDirectory.appendingPathComponent("kolom-arrangement-\(getpid()).json")
    try? FileManager.default.removeItem(at: state)
    func controller() -> DisplayArrangement {
        DisplayArrangement(
            read: { current },
            write: { frames, scope in
                writes.append(scope)
                current = frames
                return .success
            }, primary: { 1 }, stateURL: state, sessionID: "session")
    }
    var arrangement = controller()
    XCTAssertTrue(arrangement.reconcile())
    XCTAssertEqual(current, stairs)
    XCTAssertEqual(writes, [.forAppOnly])
    XCTAssertTrue(arrangement.isolated)
    XCTAssertEqual(arrangement.desk, desk)
    XCTAssertEqual(arrangement.pointerMaps.technical, stairs)
    XCTAssertFalse(arrangement.reconcile())
    XCTAssertEqual(writes.count, 1)
    XCTAssertTrue(arrangement.restore())
    XCTAssertEqual(current, desk)
    XCTAssertFalse(arrangement.isolated)
    XCTAssertTrue(arrangement.pointerMaps.technical.isEmpty)
    XCTAssertFalse(arrangement.restore())
    // A relaunch that finds Kolom's staircase still applied (committed by a mode change)
    // recovers the stored desk instead of taking the staircase as the user's.
    XCTAssertTrue(arrangement.reconcile())
    arrangement = controller()
    XCTAssertFalse(arrangement.reconcile())
    XCTAssertEqual(arrangement.desk, desk)
    XCTAssertTrue(arrangement.isolated)
    // A different session never trusts the stored desk: the staircase is ambiguous.
    let stranger = DisplayArrangement(
        read: { stairs }, write: { _, _ in .success }, primary: { 1 }, stateURL: state, sessionID: "other")
    XCTAssertFalse(stranger.reconcile())
    XCTAssertEqual(stranger.status, "ambiguous")
    XCTAssertFalse(stranger.restore())
    // The user rearranges while Kolom runs: the new arrangement is the desk.
    var swapped = desk
    swapped[2] = desk[3]
    swapped[3] = desk[2]
    current = swapped
    XCTAssertTrue(arrangement.reconcile())
    XCTAssertEqual(arrangement.desk, swapped)
    XCTAssertTrue(arrangement.restore())
    XCTAssertEqual(current, swapped)
    // macOS refusing the staircase leaves the desk and does not retry in a loop.
    current = desk
    let refusing = DisplayArrangement(read: { current }, write: { _, _ in .illegalArgument }, primary: { 1 })
    XCTAssertFalse(refusing.reconcile())
    XCTAssertEqual(refusing.status, "failed:\(CGError.illegalArgument.rawValue)")
    XCTAssertFalse(refusing.reconcile())
    XCTAssertFalse(refusing.isolated)
    // One display, or displays already stacked vertically, are left alone.
    let single = DisplayArrangement(read: { [1: desk[1]!] }, write: { _, _ in .failure }, primary: { 1 })
    XCTAssertFalse(single.reconcile())
    XCTAssertFalse(single.isolated)
    try? FileManager.default.removeItem(at: state)
}
print("PASS: display staircase isolates side-by-side displays; pointer crossings and recovery records follow the desk")
do {
    // The model's answer is checked, never trusted.
    XCTAssertEqual(
        resolveAsk(["action": "grid", "columns": 3, "rows": 2, "display": 2], displays: 3, pointerDisplay: 1),
        .run(.grid(columns: 3, rows: 2, display: 2)))
    XCTAssertEqual(
        resolveAsk(["action": "grid", "columns": 3, "rows": 2], displays: 3, pointerDisplay: 3),
        .run(.grid(columns: 3, rows: 2, display: 3)))
    XCTAssertEqual(
        resolveAsk(["action": "grid", "columns": 3, "rows": 2, "display": 4], displays: 3, pointerDisplay: 1),
        .explain("There is no screen 4; this Mac has 3."))
    XCTAssertEqual(
        resolveAsk(["action": "grid", "columns": 3], displays: 1, pointerDisplay: 1),
        .explain("Say how many columns and rows, like “3×2 terminals”."))
    XCTAssertEqual(
        resolveAsk(["action": "grid", "columns": 10, "rows": 7], displays: 1, pointerDisplay: 1),
        .explain("A grid can have at most 60 windows."))
    // Numbers the model reshaped are not trusted: a written size wins, and a bare
    // total gets exactly that many cells.
    XCTAssertEqual(
        resolveAsk(["action": "grid", "columns": 4, "rows": 3, "count": 4], text: "a 4x3 grid on my left monitor",
            displays: 1, pointerDisplay: 1),
        .run(.grid(columns: 4, rows: 3, display: 1)))
    XCTAssertEqual(
        resolveAsk(["action": "grid", "columns": 2, "rows": 2], text: "5 by 2 terminals", displays: 1, pointerDisplay: 1),
        .run(.grid(columns: 5, rows: 2, display: 1)))
    XCTAssertEqual(
        resolveAsk(["action": "grid", "columns": 3, "rows": 2, "count": 8], text: "make me 8 terminals",
            displays: 1, pointerDisplay: 1),
        .run(.grid(columns: 4, rows: 2, display: 1)))
    XCTAssertEqual(
        resolveAsk(["action": "grid", "columns": 2, "rows": 2, "count": 100], text: "100 terminals",
            displays: 1, pointerDisplay: 1),
        .explain("A grid can have at most 60 windows."))
    XCTAssertEqual(
        resolveAsk(["action": "grid", "columns": 3, "rows": 2, "count": 6], text: "six terminals, three across",
            displays: 1, pointerDisplay: 1),
        .run(.grid(columns: 3, rows: 2, display: 1)))
    XCTAssertEqual(balancedGrid(8).columns, 4)
    XCTAssertEqual(balancedGrid(8).rows, 2)
    XCTAssertEqual(balancedGrid(9).columns, 3)
    XCTAssertEqual(balancedGrid(7).columns, 7)
    XCTAssertEqual(balancedGrid(1).rows, 1)
    XCTAssertTrue(writtenGridSize("3×2 terminals on screen 2")! == (3, 2))
    XCTAssertTrue(writtenGridSize("show the desktop on screen 2") == nil)
    XCTAssertEqual(resolveAsk(["action": "grid", "columns": 0, "rows": 2], displays: 1, pointerDisplay: 1),
        .explain("A grid can have at most 60 windows."))
    XCTAssertEqual(
        resolveAsk(["action": "desktop"], displays: 2, pointerDisplay: 2), .run(.desktop(display: 2)))
    XCTAssertEqual(
        resolveAsk(["action": "previousColumn", "display": 1], displays: 2, pointerDisplay: 2),
        .run(.column(next: false, display: 1)))
    XCTAssertEqual(resolveAsk(["action": "focusApp", "app": " Safari "], displays: 1, pointerDisplay: 1),
        .run(.focus(app: "Safari")))
    XCTAssertEqual(resolveAsk(["action": "focusApp"], displays: 1, pointerDisplay: 1),
        .explain("Which app should I focus?"))
    // Moving needs an explicit screen; the pointer's display is not a guess.
    XCTAssertEqual(resolveAsk(["action": "moveWindow"], displays: 2, pointerDisplay: 1),
        .explain("Which screen should the window move to?"))
    XCTAssertEqual(resolveAsk(["action": "moveWindow", "display": 2], displays: 2, pointerDisplay: 1),
        .run(.move(display: 2)))
    XCTAssertEqual(resolveAsk(["action": "theme", "theme": "dark"], displays: 1, pointerDisplay: 1),
        .run(.theme("Dark")))
    XCTAssertEqual(resolveAsk(["action": "theme", "theme": "Neon"], displays: 1, pointerDisplay: 1),
        .explain("Kolom has Light, Dark and Wallpaper themes."))
    XCTAssertEqual(resolveAsk(["action": "undoGrid"], displays: 1, pointerDisplay: 1), .run(.undoGrid))
    for unknown: [String: Any] in [["action": "unknown"], ["action": "closeEverything"], [:]] {
        guard case .explain = resolveAsk(unknown, displays: 1, pointerDisplay: 1) else {
            XCTAssertTrue(false)
            continue
        }
    }
    // Screens count left to right on the desk, then top to bottom.
    let order = askDisplayOrder([
        (id: "main", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
        (id: "lg2", frame: CGRect(x: -792, y: -1692, width: 3008, height: 1692)),
        (id: "lg1", frame: CGRect(x: -3800, y: -1692, width: 3008, height: 1692)),
    ])
    XCTAssertEqual(order, ["lg1", "lg2", "main"])
}
print("PASS: typed requests are checked before they run; screens are numbered left to right")
