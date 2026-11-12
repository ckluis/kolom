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
    // Leaving full screen: macOS removes the full-screen Space as it shows the one
    // beneath, and Kolom may read the Spaces only after it is gone. The strip beneath
    // returns with its widths, not as new 640-point columns.
    var full = SpaceStrips()
    full.start(["lg": S(current: 915, ordered: [915])])
    var beneath = strip(["cmux", "safari"])
    beneath.setWidth("cmux", 1733)
    beneath.setWidth("safari", 1527)
    var lg = ["lg": beneath]
    XCTAssertEqual(full.update(["lg": S(current: 926, ordered: [915, 926])], workspaces: &lg), ["lg"])
    lg["lg"]!.reconcile(["zoom"], defaultWidth: 640)  // a window opened in full screen
    XCTAssertEqual(full.update(["lg": S(current: 915, ordered: [915])], workspaces: &lg), ["lg"])
    XCTAssertEqual(lg["lg"]!.windowIDs, ["cmux", "safari", "zoom"])
    XCTAssertEqual(lg["lg"]!.columns.map(\.width), [1733, 1527, 640])
    XCTAssertTrue(full.elsewhere.isEmpty)
    // Seen leaving while the full-screen Space is still listed: the same result.
    var listed = SpaceStrips()
    listed.start(["lg": S(current: 915, ordered: [915])])
    lg = ["lg": beneath]
    _ = listed.update(["lg": S(current: 926, ordered: [915, 926])], workspaces: &lg)
    XCTAssertEqual(listed.update(["lg": S(current: 915, ordered: [915, 926])], workspaces: &lg), ["lg"])
    XCTAssertEqual(lg["lg"], beneath)
    // Kept across a restart.
    let saved = try JSONEncoder().encode(strips)
    XCTAssertEqual(try JSONDecoder().decode(SpaceStrips.self, from: saved), strips)
    // The WindowServer, not Accessibility's list, says where a window is: a window
    // listed while on a Space not shown waits in that Space's strip and is never placed.
    var exact = SpaceStrips()
    exact.start(["lg": S(current: 797, ordered: [797, 813]), "pm": S(current: 1, ordered: [1])])
    XCTAssertFalse(exact.wait("safari", on: 1))  // shown: it is placed as usual
    XCTAssertTrue(exact.wait("cmux", on: 813))
    XCTAssertTrue(exact.wait("cmux", on: 813))  // once
    XCTAssertEqual(exact.stashed["lg"]?[813]?.windowIDs, ["cmux"])
    XCTAssertTrue(exact.isShown(797) && !exact.isShown(813))
    XCTAssertFalse(exact.wait("x", on: 999))  // a Space Kolom does not know
    var visible = ["lg": strip(["notes"]), "pm": strip(["safari"])]
    _ = exact.update(["lg": S(current: 813, ordered: [797, 813]), "pm": S(current: 1, ordered: [1])], workspaces: &visible)
    XCTAssertEqual(visible["lg"]!.windowIDs, ["cmux"])  // the waiting window shows with its Space
    XCTAssertEqual(exact.stashed["lg"]?[797]?.windowIDs, ["notes"])
    XCTAssertTrue(exact.wait("notes", on: 797))  // still there: stays waiting
    print("PASS: each display's Spaces keep their own strips, swap on a switch, follow renumbering and let moved windows go")
}
