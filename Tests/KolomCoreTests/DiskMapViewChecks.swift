import Foundation
import KolomCore

/// Disk Map views: measures, ages, filters, finding marked paths again.
func diskMapViewChecks() throws {
    let root = DiskNode(name: "/Users/me", role: .folder)
    func folder(_ name: String, in parent: DiskNode) -> DiskNode {
        let node = DiskNode(name: name, role: .folder)
        parent.adopt(node)
        return node
    }
    let code = folder("code", in: root)
    let kolom = folder("kolom", in: code)
    let git = folder(".git", in: kolom)
    let movie = DiskNode(name: "movie.mov", role: .file)
    movie.size = 5_000_000_000
    movie.files = 1
    movie.modified = 1_000
    folder("Movies", in: root).adopt(movie)
    git.smallBytes = 1_000
    git.smallCount = 4_000
    kolom.modified = Date().timeIntervalSince1970 - 3 * 86_400
    root.finish()
    XCTAssertEqual(DiskMeasure.size.value(root.child(named: "Movies")!), 5_000_000_000)
    XCTAssertEqual(DiskMeasure.files.value(code), 4_000)  // many small files outweigh one big one
    XCTAssertEqual(DiskMeasure.files.value(root.child(named: "Movies")!), 1)
    let now = 100 * 86_400.0
    XCTAssertEqual(DiskAge.of(now - 2 * 86_400, now: now), .week)
    XCTAssertEqual(DiskAge.of(now - 20 * 86_400, now: now), .month)
    XCTAssertEqual(DiskAge.of(now - 60 * 86_400, now: now), .quarter)
    XCTAssertEqual(DiskAge.of(400 * 86_400.0 - 200 * 86_400, now: 400 * 86_400.0), .year)
    XCTAssertEqual(DiskAge.of(1, now: 1_000 * 86_400.0), .older)
    XCTAssertEqual(DiskAge.of(0, now: now), .unknown)
    let lit = DiskFilter.matches(in: root, query: "GIT")
    XCTAssertTrue(lit.contains(ObjectIdentifier(git)) && lit.contains(ObjectIdentifier(kolom)) && lit.contains(ObjectIdentifier(root)))
    XCTAssertFalse(lit.contains(ObjectIdentifier(root.child(named: "Movies")!)))
    XCTAssertTrue(DiskFilter.matches(in: root, query: "  ").isEmpty)
    XCTAssertTrue(git.isHidden && !kolom.isHidden)
    XCTAssertTrue(root.find(path: "/Users/me/code/kolom/.git") === git)
    XCTAssertTrue(root.find(path: "/Users/me/code/gone") == nil)
    XCTAssertTrue(root.find(path: "/Users/other") == nil)
    XCTAssertTrue(root.find(path: "/Users/me") === root)
    print("PASS: Disk Map views measure size or files, age last writes, light filter matches and their folders, and find marked paths again")
}
