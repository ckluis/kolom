import CoreGraphics
import Foundation
import KolomCore

/// Duplicate window IDs, recovery and the agent channel.
func recoveryChecks() throws {
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

}
