import Foundation
import KolomCore

/// Which Space Kolom manages, and when the user is elsewhere.
func spaceChecks() throws {
    typealias D = SpaceTracker.Display
    var tracker = SpaceTracker()
    tracker.start(["lg": D(current: 748, all: [748, 900]), "pm": D(current: 1, all: [1])], displays: ["lg", "pm"])
    XCTAssertEqual(tracker.managed, ["lg": 748, "pm": 1])
    // Nothing moved.
    XCTAssertEqual(tracker.judge(["lg": D(current: 748, all: [748, 900]), "pm": D(current: 1, all: [1])], displays: ["lg", "pm"]), .managed)
    // Swiping to the second desktop on the LG: wait there, keep the layout.
    XCTAssertEqual(tracker.judge(["lg": D(current: 900, all: [748, 900]), "pm": D(current: 1, all: [1])], displays: ["lg", "pm"]), .away(["lg"]))
    // Back: manage again.
    XCTAssertEqual(tracker.judge(["lg": D(current: 748, all: [748, 900]), "pm": D(current: 1, all: [1])], displays: ["lg", "pm"]), .managed)
    // A full-screen app's Space is another Space too.
    XCTAssertEqual(tracker.judge(["lg": D(current: 748, all: [748]), "pm": D(current: 77, all: [1, 77])], displays: ["lg", "pm"]), .away(["pm"]))
    // A DisplayLink screen connecting adopts the Space it shows.
    XCTAssertEqual(
        tracker.judge(["lg": D(current: 748, all: [748]), "pm": D(current: 1, all: [1, 77]), "dl": D(current: 5, all: [5])], displays: ["lg", "pm", "dl"]),
        .managed)
    XCTAssertEqual(tracker.managed["dl"], 5)
    // A reconnect renumbers the LG's Space: the old one is gone, so adopt, never wait forever.
    XCTAssertEqual(tracker.judge(["lg": D(current: 812, all: [812]), "pm": D(current: 1, all: [1]), "dl": D(current: 5, all: [5])], displays: ["lg", "pm", "dl"]), .managed)
    XCTAssertEqual(tracker.managed["lg"], 812)
    // A display that left is forgotten.
    _ = tracker.judge(["lg": D(current: 812, all: [812]), "pm": D(current: 1, all: [1])], displays: ["lg", "pm"])
    XCTAssertTrue(tracker.managed["dl"] == nil)
    // Shared Spaces (separate Spaces off): every display reports the same one.
    var shared = SpaceTracker()
    shared.start(["a": D(current: 1, all: [1, 2]), "b": D(current: 1, all: [1, 2])], displays: ["a", "b"])
    XCTAssertEqual(shared.judge(["a": D(current: 2, all: [1, 2]), "b": D(current: 2, all: [1, 2])], displays: ["a", "b"]), .away(["a", "b"]))
    print("PASS: Kolom waits on another Space, resumes on return, and adopts displays and Spaces that appear or vanish")
}
