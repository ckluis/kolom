import CoreGraphics
import Foundation
import KolomCore

/// Strip layout, drops, parking, display memory, geometry feedback, grids, startup and resource history.
func layoutChecks() throws {
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

}
