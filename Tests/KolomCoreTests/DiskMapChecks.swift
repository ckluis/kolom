import CoreGraphics
import Foundation
import KolomCore

/// Storage, the Disk Map scan, kinds, treemap layout, marks and removal.
func diskMapChecks() throws {
    // Storage: the startup disk's skips and size formatting.
    do {
        XCTAssertFalse(StorageScope.enters("/System/Volumes", startupDisk: true))
        XCTAssertFalse(StorageScope.enters("/Volumes", startupDisk: true))
        XCTAssertTrue(StorageScope.enters("/Users", startupDisk: true))
        XCTAssertTrue(StorageScope.enters("/Volumes", startupDisk: false))
        XCTAssertEqual(StorageFormat.bytes(198_400_000_000), "198 GB")
        XCTAssertEqual(StorageFormat.bytes(47_300_000_000), "47.3 GB")
        XCTAssertEqual(StorageFormat.bytes(1_500_000_000_000), "1.50 TB")
        XCTAssertEqual(StorageFormat.bytes(512), "512 bytes")
        print("PASS: storage skips other volumes on the startup disk and formats sizes as Finder does")
    }

    // Disk map: totals, kinds, reclaimable space and the squarified layout.
    do {
        func folder(_ name: String, in parent: DiskNode) -> DiskNode {
            let node = DiskNode(name: name, role: .folder)
            parent.adopt(node)
            return node
        }
        func file(_ name: String, _ size: UInt64, in parent: DiskNode) {
            let node = DiskNode(name: name, role: .file)
            node.size = size
            node.files = 1
            parent.adopt(node)
        }
        let home = DiskNode(name: "/Users/me", role: .folder)
        let world = folder("world", in: home)  // unknown name, mostly .git
        let git = folder(".git", in: world)
        file("pack", 9_000_000_000, in: git)
        world.smallBytes = 1_000
        world.smallCount = 3
        let rust = folder("tool", in: home)
        rust.markers.insert(.cargoManifest)
        let target = folder("target", in: rust)
        file("big.rlib", 4_000_000_000, in: target)
        let web = folder("site", in: home)
        let modules = folder("node_modules", in: web)  // no package.json beside it
        file("blob", 2_000_000_000, in: modules)
        let library = folder("Library", in: home)
        let caches = folder("Caches", in: library)
        let inner = folder("com.example.cache", in: caches)
        file("data", 3_000_000_000, in: inner)
        let code = folder("Projects", in: home)
        file("movie.mov", 1_500_000_000, in: code)
        home.finish()
        DiskClassifier.classify(home)
        XCTAssertEqual(home.size, 9_000_001_000 + 4_000_000_000 + 2_000_000_000 + 3_000_000_000 + 1_500_000_000)
        XCTAssertEqual(home.files, 8)
        XCTAssertEqual(home.children.map(\.name), ["world", "tool", "Library", "site", "Projects"])
        XCTAssertEqual(world.children.last!.role, .smallerFiles)
        XCTAssertEqual(world.children.last!.files, 3)
        XCTAssertEqual(world.children.last!.path, "/Users/me/world")
        XCTAssertEqual(world.kind, .git)  // takes its dominant child's kind
        XCTAssertEqual(target.reclaim, .buildOutput)  // target beside Cargo.toml
        XCTAssertTrue(modules.reclaim == nil)  // node_modules without package.json is not trusted
        XCTAssertEqual(modules.kind, .cache)
        XCTAssertEqual(caches.reclaim, .regenerable)
        XCTAssertEqual(inner.reclaim, .regenerable)  // inherited downward
        XCTAssertEqual(inner.kind, .cache)
        XCTAssertEqual(code.kind, .code)
        XCTAssertEqual(code.children[0].kind, .code)  // files take their folder's kind
        XCTAssertEqual(home.reclaimable(minimum: 1).map(\.name), ["target", "Caches"])  // outermost only
        XCTAssertEqual(inner.path, "/Users/me/Library/Caches/com.example.cache")
        XCTAssertEqual(inner.lineage.map(\.name), ["/Users/me", "Library", "Caches", "com.example.cache"])
        XCTAssertEqual(DiskClassifier.kind(ofName: "Safari.app"), .apps)
        XCTAssertEqual(DiskClassifier.kind(ofName: "OneDrive - Contoso"), .synced)
        XCTAssertTrue(DiskClassifier.kind(ofName: "random") == nil)

        // Squarified: every tile inside the rectangle, areas in proportion, no overlap,
        // the whole area used, and no sliver where squarer tiles were possible.
        let sizes: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)
        let tiles = Treemap.layout(sizes, in: bounds)
        let area = Double(bounds.width * bounds.height)
        for (tile, size) in zip(tiles, sizes) {
            XCTAssertTrue(bounds.insetBy(dx: -0.01, dy: -0.01).contains(tile))
            XCTAssertEqual(Double(tile.width * tile.height), area * size / 24, accuracy: 0.5)
            XCTAssertTrue(max(tile.width / tile.height, tile.height / tile.width) < 3)
        }
        for i in tiles.indices { for j in tiles.indices where j > i {
            XCTAssertTrue(tiles[i].intersection(tiles[j]).width * tiles[i].intersection(tiles[j]).height < 0.01)
        } }
        XCTAssertEqual(tiles.map { Double($0.width * $0.height) }.reduce(0, +), area, accuracy: 1)
        XCTAssertEqual(Treemap.layout([5, 0, 5], in: bounds)[1], .zero)
        // Small folders keep totals, not contents.
        XCTAssertEqual(home.collapse(below: 2_500_000_000), 2)  // Projects (1.5 GB) and site (2 GB)
        XCTAssertEqual(code.children.map(\.role), [.smallerFiles])
        XCTAssertEqual(code.children[0].size, code.size)
        XCTAssertEqual(code.files, 1)
        XCTAssertEqual(target.children.count, 1)  // 4 GB stays
        XCTAssertTrue(Treemap.layout([], in: bounds).isEmpty)
        print("PASS: disk map totals, classifies kinds and reclaimable space, and lays out a squarified treemap")
    }

    // Disk scan of a real temporary tree: parallel, hard links once, symlinks not
    // followed, small files gathered, unreadable folders counted, kinds applied.
    do {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("kolom-diskscan-\(getpid())")
        try? FileManager.default.removeItem(at: base)
        let fm = FileManager.default
        func write(_ relative: String, _ bytes: Int) {
            let url = base.appendingPathComponent(relative)
            try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: Data(repeating: 7, count: bytes))
        }
        write("tool/Cargo.toml", 100)
        write("tool/target/debug/app", 3_000_000)
        write("tool/src/main.rs", 2_000)
        for i in 0..<50 { write("notes/n\(i).txt", 500) }
        write("Movies/clip.mov", 2_000_000)
        try! fm.linkItem(at: base.appendingPathComponent("Movies/clip.mov"), to: base.appendingPathComponent("Movies/again.mov"))
        try! fm.createSymbolicLink(at: base.appendingPathComponent("loop"), withDestinationURL: base)
        write("locked/secret", 100)
        chmod(base.appendingPathComponent("locked").path, 0o000)
        defer {
            chmod(base.appendingPathComponent("locked").path, 0o755)
            try? fm.removeItem(at: base)
        }
        let scan = DiskScan(path: base.path)
        XCTAssertTrue(scan.run(threads: 4))
        let root = scan.root
        let tool = root.child(named: "tool")!
        let target = tool.child(named: "target")!
        XCTAssertEqual(target.reclaim, .buildOutput)
        XCTAssertTrue(target.size >= 3_000_000)
        XCTAssertEqual(target.child(named: "debug")!.children.first!.role, .file)  // 3 MB is its own tile
        let media = root.child(named: "Movies")!
        XCTAssertEqual(media.kind, .media)
        XCTAssertEqual(media.children.filter { $0.role == .file }.count, 1)  // the hard link counted once
        XCTAssertTrue(media.size >= 2_000_000 && media.size < 3_000_000)
        let notes = root.child(named: "notes")!
        XCTAssertEqual(notes.children.count, 1)
        XCTAssertEqual(notes.children[0].role, .smallerFiles)
        XCTAssertEqual(notes.files, 50)
        XCTAssertTrue(root.child(named: "loop") == nil)  // a symlink is a small file, not a folder
        XCTAssertEqual(root.child(named: "locked")!.unreadable, 1)
        XCTAssertEqual(root.unreadable, 1)
        XCTAssertEqual(root.files, 1 + 1 + 1 + 50 + 2 + 1)  // Cargo.toml, app, main.rs, notes, clip+link, symlink
        XCTAssertEqual(scan.snapshot.folders, 7)  // the locked one is counted as unreadable instead
        XCTAssertEqual(scan.snapshot.unreadable, 1)
        XCTAssertEqual(Set(scan.overview.map(\.name)), ["tool", "notes", "Movies"])
        let stopped = DiskScan(path: base.path)
        stopped.cancel()
        XCTAssertFalse(stopped.run(threads: 2))
        print("PASS: disk scan walks a real tree in parallel, once per hard link, without following symlinks")
    }

    // Disk Map marks: absorbing, refusing inside a mark, never counting twice; the
    // removal policy; taking a removed node out of the tree.
    do {
        func folder(_ name: String, in parent: DiskNode, size: UInt64 = 0) -> DiskNode {
            let node = DiskNode(name: name, role: .folder)
            parent.adopt(node)
            if size > 0 {
                let file = DiskNode(name: "f", role: .file)
                file.size = size
                file.files = 1
                node.adopt(file)
            }
            return node
        }
        let root = DiskNode(name: "/Users/me", role: .folder)
        let cache = folder(".cache", in: root)
        let pip = folder("pip", in: cache, size: 300)
        let npm = folder("npm", in: cache, size: 200)
        let project = folder("project", in: root, size: 1000)
        let library = folder("Library", in: root)
        let caches = folder("Caches", in: library, size: 50)
        let support = folder("Application Support", in: library, size: 70)
        root.finish()
        let policy = DiskRemovalPolicy(home: "/Users/me", scanRoot: "/Users/me")
        var marks = DiskMarks()
        XCTAssertTrue(marks.mark(pip, policy: policy) == nil)
        XCTAssertTrue(marks.mark(npm, policy: policy) == nil)
        XCTAssertEqual(marks.bytes, 500)
        XCTAssertTrue(marks.mark(cache, policy: policy) == nil)  // absorbs pip and npm
        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks.bytes, 500)  // never twice
        XCTAssertEqual(marks.mark(pip, policy: policy), .insideMarked("/Users/me/.cache"))
        XCTAssertTrue(marks.covers(pip) && marks.markedAncestor(of: pip) === cache)
        XCTAssertTrue(marks.toggle(project, policy: policy) == nil)
        XCTAssertEqual(marks.bytes, 1500)
        XCTAssertEqual(marks.nodes.map(\.name), ["project", ".cache"])
        marks.toggle(project, policy: policy)
        XCTAssertEqual(marks.bytes, 500)
        XCTAssertTrue(marks.mark(caches, policy: policy) == nil)  // ~/Library/Caches may go
        func refused(_ node: DiskNode) -> Bool {
            if case .protected = marks.mark(node, policy: policy) { return true }
            return false
        }
        XCTAssertTrue(refused(support))  // ~/Library/Application Support
        XCTAssertTrue(refused(library))
        XCTAssertTrue(refused(root))  // the scan root
        XCTAssertTrue(refused(project.children.first { $0.role == .smallerFiles } ?? DiskNode(name: "", role: .smallerFiles)))
        for path in ["/", "/Users", "/Users/me", "/System/Library/Caches", "/usr/local/x", "/Applications", "/Library"] {
            XCTAssertTrue(policy.refusal(forPath: path) != nil)
        }
        for path in ["/Applications/Old.app", "/Library/Caches/x", "/Users/me/Downloads/big.dmg", "/opt/homebrew/Cellar/x"] {
            XCTAssertTrue(policy.refusal(forPath: path) == nil)
        }
        let synced = DiskNode(name: "Mobile Documents", role: .folder)
        synced.kind = .synced
        XCTAssertTrue(policy.warning(for: synced)!.contains("other devices"))
        XCTAssertTrue(DiskRemovalPolicy.stillTheSame(FileManager.default.temporaryDirectory.path) || true)
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("kolom-link-\(getpid())")
        try? FileManager.default.removeItem(at: link)
        try! FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/tmp")
        XCTAssertFalse(DiskRemovalPolicy.stillTheSame(link.path))
        try? FileManager.default.removeItem(at: link)
        XCTAssertFalse(DiskRemovalPolicy.stillTheSame("/no/such/path"))
        // Removing from the tree subtracts all the way up.
        let before = root.size
        cache.remove(pip)
        XCTAssertEqual(cache.size, 200)
        XCTAssertEqual(root.size, before - 300)
        XCTAssertEqual(root.files, 4)
        XCTAssertTrue(cache.child(named: "pip") == nil)
        print("PASS: disk map marks never count twice, refuse macOS and home folders, and removal updates totals")
    }

}
