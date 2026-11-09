import CoreGraphics
import Foundation
import KolomCore

/// Idle terminal sessions.
func idleSessionChecks() throws {
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
}
