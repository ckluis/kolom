import CoreGraphics
import Foundation
import KolomCore

/// Absence retention and the startup hold.
func presenceChecks() throws {
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

}
