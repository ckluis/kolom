import Foundation
import KolomCore

/// Every display × Space has its own strip.
func spaceStripChecks() throws {
    typealias S = SpaceStrips.Shown
    func strip(_ ids: [String]) -> Workspace {
        var w = Workspace()
        w.reconcile(ids, defaultWidth: 640)
        return w
    }
    var strips = SpaceStrips()
    strips.start(["top": S(current: 748, ordered: [748, 900]), "bottom": S(current: 1, ordered: [1])])
    var workspaces = ["top": strip(["safari", "notes"]), "bottom": strip(["cmux"])]
    // The top display swipes to its second Space: only its strip changes.
    XCTAssertEqual(strips.update(["top": S(current: 900, ordered: [748, 900]), "bottom": S(current: 1, ordered: [1])], workspaces: &workspaces), ["top"])
    XCTAssertTrue(workspaces["top"]!.windowIDs.isEmpty)
    XCTAssertEqual(workspaces["bottom"]!.windowIDs, ["cmux"])
    XCTAssertEqual(strips.elsewhere, ["safari", "notes"])
    XCTAssertTrue(strips.space(of: "safari")! == ("top", 748))
    // A window opened there belongs to that Space's strip.
    workspaces["top"]!.reconcile(["terminal"], defaultWidth: 640)
    // Back: the first Space's strip returns as it was; the second waits.
    XCTAssertEqual(strips.update(["top": S(current: 748, ordered: [748, 900]), "bottom": S(current: 1, ordered: [1])], workspaces: &workspaces), ["top"])
    XCTAssertEqual(workspaces["top"]!.windowIDs, ["safari", "notes"])
    XCTAssertEqual(strips.elsewhere, ["terminal"])
    // Nothing changed: nothing swaps.
    XCTAssertTrue(strips.update(["top": S(current: 748, ordered: [748, 900]), "bottom": S(current: 1, ordered: [1])], workspaces: &workspaces).isEmpty)
    // The terminal is moved to this Space with Mission Control: listed here now, it leaves its waiting strip.
    strips.claim(["safari", "notes", "terminal"])
    XCTAssertTrue(strips.elsewhere.isEmpty)
    XCTAssertTrue(strips.stashed["top"] == nil)
    // A DisplayLink reconnect renumbers every Space of the top display; strips follow by position.
    workspaces["top"]!.reconcile(["safari"], defaultWidth: 640)
    _ = strips.update(["top": S(current: 900, ordered: [748, 900])], workspaces: &workspaces)
    XCTAssertEqual(strips.space(of: "safari")!.space, 748)
    _ = strips.update(["top": S(current: 1900, ordered: [1748, 1900])], workspaces: &workspaces)
    XCTAssertEqual(strips.shown["top"], 1900)
    XCTAssertEqual(strips.space(of: "safari")!.space, 1748)
    XCTAssertEqual(strips.update(["top": S(current: 1748, ordered: [1748, 1900])], workspaces: &workspaces), ["top"])
    XCTAssertEqual(workspaces["top"]!.windowIDs, ["safari"])
    // Only the shown Space renumbered (no match by position): keep the strip on screen.
    let onScreen = workspaces["top"]!
    _ = strips.update(["top": S(current: 5000, ordered: [5000])], workspaces: &workspaces)
    XCTAssertEqual(workspaces["top"], onScreen)
    XCTAssertEqual(strips.shown["top"], 5000)
    // A display that disconnects keeps its strips; a new display shows what it shows.
    _ = strips.update(["bottom": S(current: 1, ordered: [1]), "new": S(current: 42, ordered: [42])], workspaces: &workspaces)
    XCTAssertEqual(strips.shown["new"], 42)
    XCTAssertEqual(strips.shown["top"], 5000)
    // A removed Space's strip is let go (macOS moved its windows elsewhere).
    var removal = SpaceStrips()
    removal.start(["d": S(current: 1, ordered: [1, 2])])
    var ws = ["d": strip(["a"])]
    _ = removal.update(["d": S(current: 2, ordered: [1, 2])], workspaces: &ws)
    XCTAssertEqual(removal.elsewhere, ["a"])
    _ = removal.update(["d": S(current: 2, ordered: [2])], workspaces: &ws)
    XCTAssertTrue(removal.elsewhere.isEmpty)
    // Kept across a restart.
    let saved = try JSONEncoder().encode(strips)
    XCTAssertEqual(try JSONDecoder().decode(SpaceStrips.self, from: saved), strips)
    print("PASS: each display's Spaces keep their own strips, swap on a switch, follow renumbering and let moved windows go")
}
