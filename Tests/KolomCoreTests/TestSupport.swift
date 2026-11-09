import CoreGraphics
import Foundation
import KolomCore

/// Shared helpers for the core checks: a minimal XCTest stand-in and fixtures.
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
