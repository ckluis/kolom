import CoreGraphics
import Foundation
import KolomCore

/// The display staircase and pointer routing.
func displayChecks() throws {
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

}
