import CoreGraphics
import Foundation
import KolomCore

/// Windows that leave and come back to their stack.
func windowReturnChecks() throws {
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

}
