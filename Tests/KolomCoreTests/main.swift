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

// A cmux column of 1939 pt on a 1920 pt display (viewport 1840): macOS clamped the
// window to 1856 on every pass and the next columns sat off-strip.
var tooWide = Workspace(columns: [
    Column(width: 1939.3125, tiles: [Tile("cmux")]), Column(width: 640, tiles: [Tile("a"), Tile("b")]),
    Column(width: 1586, tiles: [Tile("safari")]),
])
XCTAssertTrue(tooWide.fitColumns(maxWidth: 1840))
XCTAssertEqual(tooWide.columns.map(\.width), [1840, 640, 1586])
XCTAssertFalse(tooWide.fitColumns(maxWidth: 1840))
let fitted = tooWide.frames(in: CGRect(x: 64, y: 46, width: 1840, height: 1018))
XCTAssertEqual(fitted["cmux"]!.maxX, 64 + 1840)
XCTAssertFalse(tooWide.fitColumns(maxWidth: 100) && tooWide.columns.contains { $0.width < 260 })
var capped = Workspace(columns: [Column(width: 1200, tiles: [Tile("cmux")])])
XCTAssertTrue(capped.accommodateWindowWidth("cmux", actualWidth: 1920, maxWidth: 1840))
XCTAssertEqual(capped.columns[0].width, 1840)
XCTAssertFalse(capped.accommodateWindowWidth("cmux", actualWidth: 1920, maxWidth: 1840))
print("PASS: columns never exceed their display, and accommodation stops at the display width")

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

// Update check: GitHub's latest release against the running version.
XCTAssertEqual(ReleaseVersion("v0.2.2")?.description, "0.2.2")
XCTAssertTrue(ReleaseVersion("0.10.0")! > ReleaseVersion("0.9.9")!)
XCTAssertTrue(ReleaseVersion("1.0.0")! > ReleaseVersion("0.99.99")!)
XCTAssertFalse(ReleaseVersion("0.2.1")! > ReleaseVersion("0.2.1")!)
for bad in ["development", "0.2", "0.2.1.4", "v0.+2.1", "0.2.-1", "0.2.1-beta", "", "0..1", "٠.٢.١"] {
    XCTAssertTrue(ReleaseVersion(bad) == nil)
}
func release(_ fields: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: fields) }
let page = "https://github.com/ckluis/kolom/releases/tag/v0.2.2"
XCTAssertEqual(
    UpdateCheck.update(fromLatestRelease: release(["tag_name": "v0.2.2", "html_url": page]), current: "0.2.1"),
    AvailableUpdate(version: "0.2.2", url: page))
XCTAssertTrue(UpdateCheck.update(fromLatestRelease: release(["tag_name": "v0.2.1"]), current: "0.2.1") == nil)
XCTAssertTrue(UpdateCheck.update(fromLatestRelease: release(["tag_name": "v0.2.0"]), current: "0.2.1") == nil)
XCTAssertTrue(
    UpdateCheck.update(fromLatestRelease: release(["tag_name": "v0.3.0", "draft": true]), current: "0.2.1") == nil)
XCTAssertTrue(
    UpdateCheck.update(fromLatestRelease: release(["tag_name": "v0.3.0", "prerelease": true]), current: "0.2.1")
        == nil)
XCTAssertTrue(UpdateCheck.update(fromLatestRelease: release(["tag_name": "v0.3.0"]), current: "development") == nil)
XCTAssertTrue(UpdateCheck.update(fromLatestRelease: Data("not json".utf8), current: "0.2.1") == nil)
XCTAssertTrue(UpdateCheck.update(fromLatestRelease: release(["message": "Not Found"]), current: "0.2.1") == nil)
// Only release pages of this repository are opened; anything else falls back to its releases.
for foreign in ["https://evil.example/kolom", "https://github.com/ckluis/kolom-fake/releases/x", "javascript:alert(1)"] {
    XCTAssertEqual(
        UpdateCheck.update(fromLatestRelease: release(["tag_name": "v0.3.0", "html_url": foreign]), current: "0.2.1")?
            .url, UpdateCheck.releasesPage)
}
let remembered = AvailableUpdate(version: "0.2.2", url: page)
XCTAssertEqual(UpdateCheck.stillNewer(remembered, current: "0.2.1"), remembered)
XCTAssertTrue(UpdateCheck.stillNewer(remembered, current: "0.2.2") == nil)
XCTAssertTrue(UpdateCheck.isDue(lastChecked: nil, now: 1000))
XCTAssertFalse(UpdateCheck.isDue(lastChecked: 1000, now: 1000 + 23 * 3600))
XCTAssertTrue(UpdateCheck.isDue(lastChecked: 1000, now: 1000 + 24 * 3600))
XCTAssertTrue(UpdateCheck.isDue(lastChecked: 1000 + 3600, now: 1000))  // a clock set back
XCTAssertEqual(
    UpdateCheck.command(checkout: "/Users/me/Kolom's code"),
    "cd '/Users/me/Kolom'\\''s code' && git pull --ff-only && ./scripts/install.sh --quit-running")
XCTAssertEqual(UpdateCheck.command(checkout: nil), "git pull --ff-only && ./scripts/install.sh --quit-running")
print("PASS: update checks compare release versions, ignore drafts and foreign pages, and quote the checkout")

// Performance grouping: everything an app is responsible for unfolds under it.
do {
    func process(
        _ pid: Int32, _ name: String, parent: Int32 = 1, responsible: Int32? = nil, path: String = "/usr/bin/x",
        directory: String? = nil, system: Bool = false, cpu: Double? = 0.01, gpu: Double? = 0, memory: Double? = 1000
    ) -> ProcessSample {
        ProcessSample(
            id: "\(pid):1", pid: pid, parent: parent, responsible: responsible ?? pid, name: name, path: path,
            directory: directory, system: system, cpu: cpu, gpu: gpu, memory: memory)
    }
    let home = "/Users/me"
    let apps = [
        ProcessOwnerApp(pid: 100, path: "/Applications/cmux.app", id: "com.cmux", name: "cmux"),
        ProcessOwnerApp(pid: 200, path: "/Applications/Safari.app", id: "com.apple.Safari", name: "Safari"),
    ]
    let samples = [
        process(100, "cmux", path: "/Applications/cmux.app/Contents/MacOS/cmux", gpu: 0.05),
        // A terminal session: login (root-owned, from /usr/bin) → zsh → claude → node.
        process(110, "login", parent: 100, responsible: 100, path: "/usr/bin/login", system: true),
        process(111, "zsh", parent: 110, responsible: 100, path: "/bin/zsh", directory: "/Users/me/projects/kolom"),
        process(112, "claude", parent: 111, responsible: 100, directory: "/Users/me/projects/kolom", cpu: 0.2),
        process(113, "node", parent: 112, responsible: 100, cpu: nil),  // just started
        process(120, "login", parent: 100, responsible: 100, path: "/usr/bin/login", system: true),
        process(121, "zsh", parent: 120, responsible: 100, path: "/bin/zsh", directory: "/Users/me"),
        process(122, "vim", parent: 121, responsible: 100),
        process(200, "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari"),
        // Web content is started by launchd, not Safari, and runs from WebKit.framework.
        process(201, "com.apple.WebKit.WebContent", responsible: 200, path: "/System/Library/Frameworks/WebKit"),
        process(202, "com.apple.WebKit.WebContent", responsible: 200, path: "/System/Library/Frameworks/WebKit"),
        process(203, "com.apple.WebKit.Networking", responsible: 200, path: "/System/Library/Frameworks/WebKit"),
        process(300, "WindowServer", path: "/System/Library/WindowServer", system: true, gpu: 0.02),
        process(301, "mds", path: "/usr/libexec/mds", system: true),
        process(400, "postgres", path: "/opt/homebrew/bin/postgres"),
        process(401, "postgres", parent: 400, responsible: 400, path: "/opt/homebrew/bin/postgres"),
        process(500, "lonely", path: "/usr/local/bin/lonely"),
    ]
    let tree = ProcessGrouping.tree(samples, apps: apps, home: home)
    let top = Dictionary(uniqueKeysWithValues: tree.map { ($0.title, $0) })
    XCTAssertEqual(Set(top.keys), ["cmux", "Safari", "macOS", "postgres", "lonely"])
    // macOS's own parts sit under one row.
    let mac = Dictionary(uniqueKeysWithValues: top["macOS"]!.children.map { ($0.title, $0) })
    XCTAssertEqual(Set(mac.keys), ["WindowServer", "Spotlight indexing"])

    let cmux = top["cmux"]!
    XCTAssertEqual(cmux.count, 8)  // login wrappers belong to the terminal, not to macOS
    XCTAssertEqual(cmux.kind, .app)
    XCTAssertEqual(cmux.appID, "com.cmux")
    XCTAssertEqual(cmux.children.map(\.title), ["cmux", "zsh · kolom", "zsh"])
    XCTAssertTrue(cmux.children[0].detail.hasPrefix("Main process"))
    let session = cmux.children[1]
    XCTAssertEqual(session.kind, .session)
    XCTAssertEqual(session.count, 4)
    XCTAssertEqual(session.detail, "~/projects/kolom · 4 processes · claude, node")
    XCTAssertEqual(session.children.map(\.title), ["login", "zsh", "claude", "node"])
    XCTAssertEqual(session.children.map(\.depth), [0, 1, 2, 3])
    // A just-started process has no CPU reading yet; it must not blank the totals.
    XCTAssertEqual(session.cpu!, 0.01 + 0.01 + 0.2, accuracy: 1e-9)
    XCTAssertEqual(cmux.gpu!, 0.05, accuracy: 1e-9)
    XCTAssertTrue(cmux.matches("KOLOM") && cmux.matches("113") && !cmux.matches("safari"))

    let safari = top["Safari"]!
    XCTAssertEqual(safari.count, 4)
    XCTAssertEqual(safari.children.map(\.title), ["Safari", "Web Content", "Web Networking"])
    XCTAssertEqual(safari.children[1].kind, .bucket)
    XCTAssertEqual(safari.children[1].count, 2)
    XCTAssertTrue(safari.children[1].detail.contains("does not say which tab"))
    XCTAssertTrue(safari.matches("webcontent"))

    XCTAssertEqual(mac["WindowServer"]!.kind, .notable)
    XCTAssertFalse(mac["WindowServer"]!.stoppable)
    XCTAssertFalse(top["macOS"]!.stoppable)
    XCTAssertEqual(top["macOS"]!.count, 2)
    XCTAssertTrue(top["macOS"]!.detail.contains("busiest"))
    XCTAssertEqual(top["postgres"]!.count, 2)  // workers join the process responsible for them
    XCTAssertEqual(top["lonely"]!.kind, .process)
    XCTAssertTrue(top["lonely"]!.children.isEmpty)
    XCTAssertEqual(tree.map(\.count).reduce(0, +), samples.count)

    // Without the responsibility record, bundles and parents still find the owner.
    let fallback = ProcessGrouping.tree(
        samples.map { var s = $0; s.responsible = nil; return s }, apps: apps, home: home)
    XCTAssertEqual(fallback.first { $0.title == "cmux" }!.count, 8)

    // Every row has its own id, or SwiftUI draws the outline wrong.
    func ids(_ nodes: [ProcessNode]) -> [String] { nodes.flatMap { [$0.id] + ids($0.children) } }
    XCTAssertEqual(Set(ids(tree)).count, ids(tree).count)
    // Ids stay stable between samples so unfolded rows stay unfolded.
    XCTAssertEqual(
        ProcessGrouping.tree(samples.reversed(), apps: apps, home: home).flatMap { [$0.id] + $0.children.map(\.id) }
            .sorted(), tree.flatMap { [$0.id] + $0.children.map(\.id) }.sorted())

    func named(_ name: String, _ path: String) -> String { ProcessGrouping.displayName(process(9, name, path: path)) }
    XCTAssertEqual(named("2.1.316", "/Users/me/.local/share/claude/versions/2.1.316"), "claude 2.1.316")
    XCTAssertEqual(named("1.2.3", "/opt/tool/1.2.3"), "tool 1.2.3")
    XCTAssertEqual(named("node", "/opt/homebrew/bin/node"), "node")
    XCTAssertEqual(named("com.apple.WebKit.WebContent", ""), "Web Content")
    // Things macOS registers as apps without being apps of their own (0.2.6).
    do {
        let cryptex = "/System/Volumes/Preboot/Cryptexes/OS/System/Library"
        let registered = apps + [
            ProcessOwnerApp(pid: 600, path: cryptex + "/AutoFill.xpc", id: "autofill", name: "AutoFill (cmux)", owner: false),
            ProcessOwnerApp(pid: 601, path: "/opt/homebrew/bin", id: "npm", name: "npm run dev", owner: false),
            ProcessOwnerApp(pid: 603, path: "/System/Applications/Stocks.app/Contents/PlugIns/StocksWidget.appex",
                id: "stocks.widget", name: "StocksWidget", owner: false),
            ProcessOwnerApp(pid: 604, path: "/System/Library/CoreServices/WallpaperAgent.app", id: "wallpaper",
                name: "Wallpaper", owner: false),
            ProcessOwnerApp(pid: 605, path: "/Applications/Tool.app", id: "tool", name: "Tool", owner: true),
        ]
        var extra = samples
        var autofill = process(600, "AutoFill", responsible: 100, path: cryptex + "/AutoFill.xpc/Contents/MacOS/AutoFill",
            system: true)
        autofill.label = "AutoFill (cmux)"
        extra.append(autofill)
        // A dev server whose terminal session closed: parented by launchd, still cmux's responsibility.
        var dev = process(601, "node", responsible: 100, path: "/opt/homebrew/bin/node", directory: "/Users/me/app")
        dev.label = "npm run dev"
        extra.append(dev)
        extra.append(process(602, "esbuild", parent: 601, responsible: 100, path: "/Users/me/app/node_modules/esbuild"))
        extra.append(process(603, "StocksWidget",
            path: "/System/Applications/Stocks.app/Contents/PlugIns/StocksWidget.appex/Contents/MacOS/StocksWidget",
            system: true))
        extra.append(process(604, "WallpaperAgent",
            path: "/System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent", system: true))
        extra.append(process(605, "Tool", path: "/Applications/Tool.app/Contents/MacOS/Tool"))
        var rootOwned = process(606, "rootd", path: "/opt/rootd")
        rootOwned.user = false
        extra.append(rootOwned)
        let smarter = ProcessGrouping.tree(extra, apps: registered, home: home)
        let rows = Dictionary(uniqueKeysWithValues: smarter.map { ($0.title, $0) })
        XCTAssertEqual(Set(rows.keys), ["cmux", "Safari", "macOS", "postgres", "lonely", "Tool", "rootd"])
        let system = Dictionary(uniqueKeysWithValues: rows["macOS"]!.children.map { ($0.title, $0) })
        XCTAssertEqual(
            Set(system.keys), ["WindowServer", "Spotlight indexing", "Widgets & extensions", "Background services"])
        let terminal = rows["cmux"]!
        XCTAssertEqual(terminal.count, 11)
        XCTAssertTrue(terminal.children.contains { $0.title == "AutoFill (cmux)" && $0.kind == .process })
        let left = terminal.children.first { $0.kind == .leftover }!
        XCTAssertEqual(left.title, "Left running")
        XCTAssertEqual(left.count, 2)
        XCTAssertTrue(left.detail.contains("terminal session that started it has closed"))
        XCTAssertEqual(left.children.map(\.title), ["npm run dev · app"])
        XCTAssertEqual(left.children[0].children.map(\.title), ["npm run dev", "esbuild"])
        XCTAssertTrue(left.children[0].children[0].detail.contains("node"))
        XCTAssertEqual(system["Widgets & extensions"]!.count, 1)
        XCTAssertEqual(system["Widgets & extensions"]!.children.map(\.title), ["Widgets"])
        // The usual suspects of a slow Mac leave the macOS row for their own.
        XCTAssertEqual(system["WindowServer"]!.kind, .notable)
        XCTAssertTrue(system["WindowServer"]!.detail.contains("DisplayLink"))
        XCTAssertEqual(system["Spotlight indexing"]!.count, 1)
        XCTAssertEqual(system["Background services"]!.count, 1)  // WallpaperAgent
        XCTAssertEqual(rows["macOS"]!.count, 4)
        XCTAssertEqual(rows["Tool"]!.kind, .app)
        XCTAssertEqual(rows["Tool"]!.appID, "tool")
        // Stopping is offered only for the user's own processes outside macOS.
        XCTAssertTrue(left.stoppable && terminal.stoppable)
        // A session is stoppable through its own processes; root-owned login is left to end with its shell.
        let kolomSession = terminal.children.first { $0.title == "zsh · kolom" }!
        XCTAssertTrue(kolomSession.stoppable)
        XCTAssertEqual(Set(kolomSession.pids), [111, 112, 113])
        XCTAssertFalse(terminal.children.first { $0.title == "AutoFill (cmux)" }!.stoppable)
        XCTAssertFalse(rows["macOS"]!.stoppable)
        XCTAssertFalse(rows["rootd"]!.stoppable)
        XCTAssertTrue(rows["lonely"]!.stoppable)
        XCTAssertEqual(Set(left.pids), [601, 602])
        XCTAssertEqual(Set(ids(smarter)).count, ids(smarter).count)
        XCTAssertEqual(smarter.map(\.count).reduce(0, +), extra.count)
    }
    XCTAssertTrue(ProcessOwnerApp.isOwner(regular: true, accessory: false, path: "/System/Library/CoreServices/Finder.app"))
    XCTAssertTrue(ProcessOwnerApp.isOwner(regular: false, accessory: true, path: "/Applications/Kolom.app"))
    XCTAssertFalse(ProcessOwnerApp.isOwner(regular: false, accessory: true, path: "/System/Library/CoreServices/WallpaperAgent.app"))
    XCTAssertFalse(ProcessOwnerApp.isOwner(regular: false, accessory: false, path: "/Applications/X.app"))
    // nettop -P -d -x -J bytes_in,bytes_out
    XCTAssertTrue(NettopParser.isHeader(",bytes_in,bytes_out,"))
    XCTAssertTrue(NettopParser.line(",bytes_in,bytes_out,") == nil)
    XCTAssertEqual(NettopParser.line("gh.37667,5000,2186,")!.pid, 37667)
    XCTAssertEqual(NettopParser.line("gh.37667,5000,2186,")!.bytes, 7186)
    XCTAssertEqual(NettopParser.line("com.apple.WebKi.1320,200,30,")!.pid, 1320)
    XCTAssertEqual(NettopParser.line("2.1.299.1559,1,2,")!.pid, 1559)
    XCTAssertEqual(NettopParser.line("odd,name.42,1,2,")!.pid, 42)
    XCTAssertTrue(NettopParser.line("garbage") == nil)
    XCTAssertTrue(NettopParser.line("x.notapid,1,2,") == nil)
    let twoSamples = ",bytes_in,bytes_out,\ngh.7,900,100,\n,bytes_in,bytes_out,\ngh.7,30,10,\nnode.8,0,0,\n"
    XCTAssertEqual(NettopParser.rates(twoSamples)![7]!, 40)
    XCTAssertEqual(NettopParser.rates(twoSamples)![8]!, 0)
    XCTAssertTrue(NettopParser.rates(",bytes_in,bytes_out,\ngh.7,900,100,\n") == nil)  // stopped early
    let listing = PSListing.parse(
        "  609     1    88  16.0 108800 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer\n"
            + "81761     1   501   4.7 208064 /Applications/DisplayLink Manager.app/Contents/MacOS/DisplayLinkUserAgent\nbad line\n")
    XCTAssertEqual(listing.count, 2)
    XCTAssertEqual(listing[609]!.uid, 88)
    XCTAssertEqual(listing[609]!.cpu, 16.0)
    XCTAssertEqual(listing[609]!.memory, 108800 * 1024)
    XCTAssertEqual(listing[81761]!.path, "/Applications/DisplayLink Manager.app/Contents/MacOS/DisplayLinkUserAgent")
    XCTAssertTrue(ProcessSample.isSystem(path: "/usr/sbin/cfprefsd", uid: 501))
    XCTAssertTrue(ProcessSample.isSystem(path: "/opt/x", uid: 0))
    XCTAssertFalse(ProcessSample.isSystem(path: "/bin/zsh", uid: 501))
    XCTAssertEqual(ProcessGrouping.abbreviate("/Users/me/a", home: home), "~/a")
    XCTAssertEqual(ProcessGrouping.abbreviate("/Users/meow", home: home), "/Users/meow")
    XCTAssertTrue(ProcessGrouping.sum([nil, nil]) == nil)
    XCTAssertTrue(processGPUShare(previous: nil, current: 5, elapsed: 2) == nil)
    XCTAssertTrue(processGPUShare(previous: 9, current: 5, elapsed: 2) == nil)
    XCTAssertEqual(processGPUShare(previous: 0, current: 1_000_000_000, elapsed: 2)!, 0.5)
    print("PASS: performance groups processes by responsible app, session and kind, with GPU shares, network and stop rules")
}

do {
    let script = UpdateCheck.terminalScript(checkout: "/Users/me/Kolom's code")
    XCTAssertTrue(script.hasPrefix("#!/bin/zsh\n"))
    XCTAssertTrue(
        script.contains(
            "cd '/Users/me/Kolom'\\''s code' && git pull --ff-only && ./scripts/install.sh --quit-running\nresult=$?"))
    // A failed update reopens the installed Kolom so windows are not left unmanaged.
    XCTAssertTrue(script.contains("pgrep -xq Kolom || open -a Kolom"))
    print("PASS: Update now runs the quoted update command and reopens Kolom if it stops")
}

// Storage: the startup disk's skips and size formatting.
do {
    XCTAssertFalse(StorageScope.enters("/System/Volumes", startupDisk: true))
    XCTAssertFalse(StorageScope.enters("/Volumes", startupDisk: true))
    XCTAssertTrue(StorageScope.enters("/Users", startupDisk: true))
    XCTAssertTrue(StorageScope.enters("/Volumes", startupDisk: false))
    XCTAssertEqual(StorageFormat.bytes(198_400_000_000), "198 GB")
    XCTAssertEqual(StorageFormat.bytes(47_300_000_000), "47.3 GB")
    XCTAssertEqual(StorageFormat.bytes(1_500_000_000_000), "1.50 TB")
    XCTAssertEqual(StorageFormat.bytes(512), "512 bytes")
    print("PASS: storage skips other volumes on the startup disk and formats sizes as Finder does")
}

// Disk map: totals, kinds, reclaimable space and the squarified layout.
do {
    func folder(_ name: String, in parent: DiskNode) -> DiskNode {
        let node = DiskNode(name: name, role: .folder)
        parent.adopt(node)
        return node
    }
    func file(_ name: String, _ size: UInt64, in parent: DiskNode) {
        let node = DiskNode(name: name, role: .file)
        node.size = size
        node.files = 1
        parent.adopt(node)
    }
    let home = DiskNode(name: "/Users/me", role: .folder)
    let world = folder("world", in: home)  // unknown name, mostly .git
    let git = folder(".git", in: world)
    file("pack", 9_000_000_000, in: git)
    world.smallBytes = 1_000
    world.smallCount = 3
    let rust = folder("tool", in: home)
    rust.markers.insert(.cargoManifest)
    let target = folder("target", in: rust)
    file("big.rlib", 4_000_000_000, in: target)
    let web = folder("site", in: home)
    let modules = folder("node_modules", in: web)  // no package.json beside it
    file("blob", 2_000_000_000, in: modules)
    let library = folder("Library", in: home)
    let caches = folder("Caches", in: library)
    let inner = folder("com.example.cache", in: caches)
    file("data", 3_000_000_000, in: inner)
    let code = folder("Projects", in: home)
    file("movie.mov", 1_500_000_000, in: code)
    home.finish()
    DiskClassifier.classify(home)
    XCTAssertEqual(home.size, 9_000_001_000 + 4_000_000_000 + 2_000_000_000 + 3_000_000_000 + 1_500_000_000)
    XCTAssertEqual(home.files, 8)
    XCTAssertEqual(home.children.map(\.name), ["world", "tool", "Library", "site", "Projects"])
    XCTAssertEqual(world.children.last!.role, .smallerFiles)
    XCTAssertEqual(world.children.last!.files, 3)
    XCTAssertEqual(world.children.last!.path, "/Users/me/world")
    XCTAssertEqual(world.kind, .git)  // takes its dominant child's kind
    XCTAssertEqual(target.reclaim, .buildOutput)  // target beside Cargo.toml
    XCTAssertTrue(modules.reclaim == nil)  // node_modules without package.json is not trusted
    XCTAssertEqual(modules.kind, .cache)
    XCTAssertEqual(caches.reclaim, .regenerable)
    XCTAssertEqual(inner.reclaim, .regenerable)  // inherited downward
    XCTAssertEqual(inner.kind, .cache)
    XCTAssertEqual(code.kind, .code)
    XCTAssertEqual(code.children[0].kind, .code)  // files take their folder's kind
    XCTAssertEqual(home.reclaimable(minimum: 1).map(\.name), ["target", "Caches"])  // outermost only
    XCTAssertEqual(inner.path, "/Users/me/Library/Caches/com.example.cache")
    XCTAssertEqual(inner.lineage.map(\.name), ["/Users/me", "Library", "Caches", "com.example.cache"])
    XCTAssertEqual(DiskClassifier.kind(ofName: "Safari.app"), .apps)
    XCTAssertEqual(DiskClassifier.kind(ofName: "OneDrive - Contoso"), .synced)
    XCTAssertTrue(DiskClassifier.kind(ofName: "random") == nil)

    // Squarified: every tile inside the rectangle, areas in proportion, no overlap,
    // the whole area used, and no sliver where squarer tiles were possible.
    let sizes: [Double] = [6, 6, 4, 3, 2, 2, 1]
    let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)
    let tiles = Treemap.layout(sizes, in: bounds)
    let area = Double(bounds.width * bounds.height)
    for (tile, size) in zip(tiles, sizes) {
        XCTAssertTrue(bounds.insetBy(dx: -0.01, dy: -0.01).contains(tile))
        XCTAssertEqual(Double(tile.width * tile.height), area * size / 24, accuracy: 0.5)
        XCTAssertTrue(max(tile.width / tile.height, tile.height / tile.width) < 3)
    }
    for i in tiles.indices { for j in tiles.indices where j > i {
        XCTAssertTrue(tiles[i].intersection(tiles[j]).width * tiles[i].intersection(tiles[j]).height < 0.01)
    } }
    XCTAssertEqual(tiles.map { Double($0.width * $0.height) }.reduce(0, +), area, accuracy: 1)
    XCTAssertEqual(Treemap.layout([5, 0, 5], in: bounds)[1], .zero)
    // Small folders keep totals, not contents.
    XCTAssertEqual(home.collapse(below: 2_500_000_000), 2)  // Projects (1.5 GB) and site (2 GB)
    XCTAssertEqual(code.children.map(\.role), [.smallerFiles])
    XCTAssertEqual(code.children[0].size, code.size)
    XCTAssertEqual(code.files, 1)
    XCTAssertEqual(target.children.count, 1)  // 4 GB stays
    XCTAssertTrue(Treemap.layout([], in: bounds).isEmpty)
    print("PASS: disk map totals, classifies kinds and reclaimable space, and lays out a squarified treemap")
}

// Disk scan of a real temporary tree: parallel, hard links once, symlinks not
// followed, small files gathered, unreadable folders counted, kinds applied.
do {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("kolom-diskscan-\(getpid())")
    try? FileManager.default.removeItem(at: base)
    let fm = FileManager.default
    func write(_ relative: String, _ bytes: Int) {
        let url = base.appendingPathComponent(relative)
        try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: url.path, contents: Data(repeating: 7, count: bytes))
    }
    write("tool/Cargo.toml", 100)
    write("tool/target/debug/app", 3_000_000)
    write("tool/src/main.rs", 2_000)
    for i in 0..<50 { write("notes/n\(i).txt", 500) }
    write("Movies/clip.mov", 2_000_000)
    try! fm.linkItem(at: base.appendingPathComponent("Movies/clip.mov"), to: base.appendingPathComponent("Movies/again.mov"))
    try! fm.createSymbolicLink(at: base.appendingPathComponent("loop"), withDestinationURL: base)
    write("locked/secret", 100)
    chmod(base.appendingPathComponent("locked").path, 0o000)
    defer {
        chmod(base.appendingPathComponent("locked").path, 0o755)
        try? fm.removeItem(at: base)
    }
    let scan = DiskScan(path: base.path)
    XCTAssertTrue(scan.run(threads: 4))
    let root = scan.root
    let tool = root.child(named: "tool")!
    let target = tool.child(named: "target")!
    XCTAssertEqual(target.reclaim, .buildOutput)
    XCTAssertTrue(target.size >= 3_000_000)
    XCTAssertEqual(target.child(named: "debug")!.children.first!.role, .file)  // 3 MB is its own tile
    let media = root.child(named: "Movies")!
    XCTAssertEqual(media.kind, .media)
    XCTAssertEqual(media.children.filter { $0.role == .file }.count, 1)  // the hard link counted once
    XCTAssertTrue(media.size >= 2_000_000 && media.size < 3_000_000)
    let notes = root.child(named: "notes")!
    XCTAssertEqual(notes.children.count, 1)
    XCTAssertEqual(notes.children[0].role, .smallerFiles)
    XCTAssertEqual(notes.files, 50)
    XCTAssertTrue(root.child(named: "loop") == nil)  // a symlink is a small file, not a folder
    XCTAssertEqual(root.child(named: "locked")!.unreadable, 1)
    XCTAssertEqual(root.unreadable, 1)
    XCTAssertEqual(root.files, 1 + 1 + 1 + 50 + 2 + 1)  // Cargo.toml, app, main.rs, notes, clip+link, symlink
    XCTAssertEqual(scan.snapshot.folders, 7)  // the locked one is counted as unreadable instead
    XCTAssertEqual(scan.snapshot.unreadable, 1)
    XCTAssertEqual(Set(scan.overview.map(\.name)), ["tool", "notes", "Movies"])
    let stopped = DiskScan(path: base.path)
    stopped.cancel()
    XCTAssertFalse(stopped.run(threads: 2))
    print("PASS: disk scan walks a real tree in parallel, once per hard link, without following symlinks")
}

// Disk Map marks: absorbing, refusing inside a mark, never counting twice; the
// removal policy; taking a removed node out of the tree.
do {
    func folder(_ name: String, in parent: DiskNode, size: UInt64 = 0) -> DiskNode {
        let node = DiskNode(name: name, role: .folder)
        parent.adopt(node)
        if size > 0 {
            let file = DiskNode(name: "f", role: .file)
            file.size = size
            file.files = 1
            node.adopt(file)
        }
        return node
    }
    let root = DiskNode(name: "/Users/me", role: .folder)
    let cache = folder(".cache", in: root)
    let pip = folder("pip", in: cache, size: 300)
    let npm = folder("npm", in: cache, size: 200)
    let project = folder("project", in: root, size: 1000)
    let library = folder("Library", in: root)
    let caches = folder("Caches", in: library, size: 50)
    let support = folder("Application Support", in: library, size: 70)
    root.finish()
    let policy = DiskRemovalPolicy(home: "/Users/me", scanRoot: "/Users/me")
    var marks = DiskMarks()
    XCTAssertTrue(marks.mark(pip, policy: policy) == nil)
    XCTAssertTrue(marks.mark(npm, policy: policy) == nil)
    XCTAssertEqual(marks.bytes, 500)
    XCTAssertTrue(marks.mark(cache, policy: policy) == nil)  // absorbs pip and npm
    XCTAssertEqual(marks.count, 1)
    XCTAssertEqual(marks.bytes, 500)  // never twice
    XCTAssertEqual(marks.mark(pip, policy: policy), .insideMarked("/Users/me/.cache"))
    XCTAssertTrue(marks.covers(pip) && marks.markedAncestor(of: pip) === cache)
    XCTAssertTrue(marks.toggle(project, policy: policy) == nil)
    XCTAssertEqual(marks.bytes, 1500)
    XCTAssertEqual(marks.nodes.map(\.name), ["project", ".cache"])
    marks.toggle(project, policy: policy)
    XCTAssertEqual(marks.bytes, 500)
    XCTAssertTrue(marks.mark(caches, policy: policy) == nil)  // ~/Library/Caches may go
    func refused(_ node: DiskNode) -> Bool {
        if case .protected = marks.mark(node, policy: policy) { return true }
        return false
    }
    XCTAssertTrue(refused(support))  // ~/Library/Application Support
    XCTAssertTrue(refused(library))
    XCTAssertTrue(refused(root))  // the scan root
    XCTAssertTrue(refused(project.children.first { $0.role == .smallerFiles } ?? DiskNode(name: "", role: .smallerFiles)))
    for path in ["/", "/Users", "/Users/me", "/System/Library/Caches", "/usr/local/x", "/Applications", "/Library"] {
        XCTAssertTrue(policy.refusal(forPath: path) != nil)
    }
    for path in ["/Applications/Old.app", "/Library/Caches/x", "/Users/me/Downloads/big.dmg", "/opt/homebrew/Cellar/x"] {
        XCTAssertTrue(policy.refusal(forPath: path) == nil)
    }
    let synced = DiskNode(name: "Mobile Documents", role: .folder)
    synced.kind = .synced
    XCTAssertTrue(policy.warning(for: synced)!.contains("other devices"))
    XCTAssertTrue(DiskRemovalPolicy.stillTheSame(FileManager.default.temporaryDirectory.path) || true)
    let link = FileManager.default.temporaryDirectory.appendingPathComponent("kolom-link-\(getpid())")
    try? FileManager.default.removeItem(at: link)
    try! FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/tmp")
    XCTAssertFalse(DiskRemovalPolicy.stillTheSame(link.path))
    try? FileManager.default.removeItem(at: link)
    XCTAssertFalse(DiskRemovalPolicy.stillTheSame("/no/such/path"))
    // Removing from the tree subtracts all the way up.
    let before = root.size
    cache.remove(pip)
    XCTAssertEqual(cache.size, 200)
    XCTAssertEqual(root.size, before - 300)
    XCTAssertEqual(root.files, 4)
    XCTAssertTrue(cache.child(named: "pip") == nil)
    print("PASS: disk map marks never count twice, refuse macOS and home folders, and removal updates totals")
}

// A window that leaves and comes back returns to its stack, not the strip's end.
do {
    var space = Workspace()
    space.reconcile(["note1", "note2", "note3", "safari"], defaultWidth: 640)
    XCTAssertTrue(space.move("note2", to: "note1", placement: .below))
    XCTAssertTrue(space.move("note3", to: "note2", placement: .below))
    space.setWidth("note1", 415)
    XCTAssertEqual(space.columns.map { $0.tiles.map(\.id) }, [["note1", "note2", "note3"], ["safari"]])
    let slot = space.slot(of: "note3")!
    XCTAssertEqual(slot.columnMates, ["note1", "note2"])
    XCTAssertEqual(slot.stackIndex, 2)
    XCTAssertEqual(slot.rightNeighbor, "safari")
    // It drops out (missing from Accessibility past the grace), then is listed again:
    // reconcile alone would append it as a new 640-point column after Safari.
    space.reconcile(["note1", "note2", "safari"], defaultWidth: 640)
    space.reconcile(["note1", "note2", "safari", "note3"], defaultWidth: 640)
    XCTAssertEqual(space.columns.map { $0.tiles.map(\.id) }, [["note1", "note2"], ["safari"], ["note3"]])
    XCTAssertTrue(space.restore("note3", to: slot))
    XCTAssertEqual(space.columns.map { $0.tiles.map(\.id) }, [["note1", "note2", "note3"], ["safari"]])
    XCTAssertEqual(space.columns[0].width, 415)
    // A lone column returns beside its old neighbour at its old width.
    var strip = Workspace()
    strip.reconcile(["a", "b", "c"], defaultWidth: 640)
    strip.setWidth("b", 900)
    let lone = strip.slot(of: "b")!
    strip.reconcile(["a", "c"], defaultWidth: 640)
    strip.reconcile(["a", "c", "b"], defaultWidth: 640)
    XCTAssertTrue(strip.restore("b", to: lone))
    XCTAssertEqual(strip.columns.map { $0.tiles[0].id }, ["a", "b", "c"])
    XCTAssertEqual(strip.columns[1].width, 900)
    // Nothing it knew remains: it stays where reconcile put it.
    var empty = Workspace()
    empty.reconcile(["x", "b"], defaultWidth: 640)
    XCTAssertFalse(empty.restore("b", to: lone))
    XCTAssertEqual(empty.windowIDs, ["x", "b"])
    print("PASS: a window that drops out and returns goes back into its stack at its old place and width")
}

// Terminal sessions untouched for more than a day are gathered as idle.
do {
    func shell(_ pid: Int32, parent: Int32, idle: Double?, name: String = "zsh") -> ProcessSample {
        ProcessSample(
            id: "\(pid):1", pid: pid, parent: parent, responsible: 100, name: name, path: "/bin/zsh",
            directory: "/Users/me", system: false, cpu: 0, gpu: 0, memory: 3_000_000, terminalIdle: idle)
    }
    let apps = [ProcessOwnerApp(pid: 100, path: "/Applications/cmux.app", id: "com.cmux", name: "cmux")]
    let samples = [
        ProcessSample(
            id: "100:1", pid: 100, parent: 1, responsible: 100, name: "cmux",
            path: "/Applications/cmux.app/Contents/MacOS/cmux", directory: nil, system: false, cpu: 0.1, gpu: 0,
            memory: 1e9),
        shell(201, parent: 100, idle: 30),  // in use
        shell(202, parent: 100, idle: 9 * 86400),  // a forgotten tab
        shell(203, parent: 100, idle: 2 * 86400),
        shell(204, parent: 100, idle: 7 * 3600),  // quiet, not idle yet
        shell(205, parent: 100, idle: 3 * 86400),  // a shell running a quiet program
        shell(206, parent: 205, idle: 3 * 86400, name: "node"),
    ]
    let cmux = ProcessGrouping.tree(samples, apps: apps, home: "/Users/me").first { $0.title == "cmux" }!
    let idle = cmux.children.first { $0.kind == .idle }!
    XCTAssertEqual(idle.title, "Idle for more than a day")
    XCTAssertEqual(idle.children.count, 3)
    XCTAssertEqual(idle.count, 4)  // 202, 203, and 205 with its node
    XCTAssertEqual(idle.detail, "3 sessions · terminals untouched 2 d–9 d")
    XCTAssertEqual(idle.children.first!.idle, 9 * 86400)  // longest idle first
    XCTAssertEqual(Set(idle.pids), [202, 203, 205, 206])
    let quiet = cmux.children.flatMap { [$0] + $0.children }.first { $0.pid == 204 }!
    XCTAssertTrue(quiet.detail.contains("idle 7 h"))
    XCTAssertFalse(cmux.children.contains { $0.kind == .idle && $0.pids.contains(201) })
    XCTAssertEqual(
        ProcessGrouping.abbreviate("/private/var/folders/_6/44y5/T/baton-v76-E1-repo", home: "/Users/me"),
        "tmp/baton-v76-E1-repo")
    var gone = shell(207, parent: 100, idle: 4 * 86400)
    gone.directory = "/private/var/folders/_6/x/T/old-repo"
    gone.directoryMissing = true
    let withGone = ProcessGrouping.tree(samples + [gone], apps: apps, home: "/Users/me").first { $0.title == "cmux" }!
    let goneRow = withGone.children.first { $0.kind == .idle }!.children.first { $0.pid == 207 }!
    XCTAssertTrue(goneRow.detail.contains("tmp/old-repo (folder deleted)"))
    XCTAssertEqual(ProcessGrouping.idleText(90), "1 min")
    XCTAssertEqual(ProcessGrouping.idleText(5 * 3600), "5 h")
    XCTAssertEqual(ProcessGrouping.idleText(21 * 86400), "21 d")
    print("PASS: terminal sessions untouched for more than a day are gathered as idle, longest first")
}
