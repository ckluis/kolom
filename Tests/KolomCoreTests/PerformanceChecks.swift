import CoreGraphics
import Foundation
import KolomCore

/// Performance: grouping, GPU, network, stopping.
func performanceChecks() throws {
    // Performance grouping: everything an app is responsible for unfolds under it.
    do {
        func process(
            _ pid: Int32, _ name: String, parent: Int32 = 1, responsible: Int32? = nil, path: String = "/usr/bin/x",
            directory: String? = nil, system: Bool = false, cpu: Double? = 0.01, gpu: Double? = 0, memory: Double? = 1000
        ) -> ProcessSample {
            ProcessSample(
                id: "\(pid):1", pid: pid, parent: parent, responsible: responsible ?? pid, name: name, path: path,
                directory: directory, system: system, cpu: cpu, gpu: gpu, memory: memory)
        }
        let home = "/Users/me"
        let apps = [
            ProcessOwnerApp(pid: 100, path: "/Applications/cmux.app", id: "com.cmux", name: "cmux"),
            ProcessOwnerApp(pid: 200, path: "/Applications/Safari.app", id: "com.apple.Safari", name: "Safari"),
        ]
        let samples = [
            process(100, "cmux", path: "/Applications/cmux.app/Contents/MacOS/cmux", gpu: 0.05),
            // A terminal session: login (root-owned, from /usr/bin) → zsh → claude → node.
            process(110, "login", parent: 100, responsible: 100, path: "/usr/bin/login", system: true),
            process(111, "zsh", parent: 110, responsible: 100, path: "/bin/zsh", directory: "/Users/me/projects/kolom"),
            process(112, "claude", parent: 111, responsible: 100, directory: "/Users/me/projects/kolom", cpu: 0.2),
            process(113, "node", parent: 112, responsible: 100, cpu: nil),  // just started
            process(120, "login", parent: 100, responsible: 100, path: "/usr/bin/login", system: true),
            process(121, "zsh", parent: 120, responsible: 100, path: "/bin/zsh", directory: "/Users/me"),
            process(122, "vim", parent: 121, responsible: 100),
            process(200, "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari"),
            // Web content is started by launchd, not Safari, and runs from WebKit.framework.
            process(201, "com.apple.WebKit.WebContent", responsible: 200, path: "/System/Library/Frameworks/WebKit"),
            process(202, "com.apple.WebKit.WebContent", responsible: 200, path: "/System/Library/Frameworks/WebKit"),
            process(203, "com.apple.WebKit.Networking", responsible: 200, path: "/System/Library/Frameworks/WebKit"),
            process(300, "WindowServer", path: "/System/Library/WindowServer", system: true, gpu: 0.02),
            process(301, "mds", path: "/usr/libexec/mds", system: true),
            process(400, "postgres", path: "/opt/homebrew/bin/postgres"),
            process(401, "postgres", parent: 400, responsible: 400, path: "/opt/homebrew/bin/postgres"),
            process(500, "lonely", path: "/usr/local/bin/lonely"),
        ]
        let tree = ProcessGrouping.tree(samples, apps: apps, home: home)
        let top = Dictionary(uniqueKeysWithValues: tree.map { ($0.title, $0) })
        XCTAssertEqual(Set(top.keys), ["cmux", "Safari", "macOS", "postgres", "lonely"])
        // macOS's own parts sit under one row.
        let mac = Dictionary(uniqueKeysWithValues: top["macOS"]!.children.map { ($0.title, $0) })
        XCTAssertEqual(Set(mac.keys), ["WindowServer", "Spotlight indexing"])

        let cmux = top["cmux"]!
        XCTAssertEqual(cmux.count, 8)  // login wrappers belong to the terminal, not to macOS
        XCTAssertEqual(cmux.kind, .app)
        XCTAssertEqual(cmux.appID, "com.cmux")
        XCTAssertEqual(cmux.children.map(\.title), ["cmux", "zsh · kolom", "zsh"])
        XCTAssertTrue(cmux.children[0].detail.hasPrefix("Main process"))
        let session = cmux.children[1]
        XCTAssertEqual(session.kind, .session)
        XCTAssertEqual(session.count, 4)
        XCTAssertEqual(session.detail, "~/projects/kolom · 4 processes · claude, node")
        XCTAssertEqual(session.children.map(\.title), ["login", "zsh", "claude", "node"])
        XCTAssertEqual(session.children.map(\.depth), [0, 1, 2, 3])
        // A just-started process has no CPU reading yet; it must not blank the totals.
        XCTAssertEqual(session.cpu!, 0.01 + 0.01 + 0.2, accuracy: 1e-9)
        XCTAssertEqual(cmux.gpu!, 0.05, accuracy: 1e-9)
        XCTAssertTrue(cmux.matches("KOLOM") && cmux.matches("113") && !cmux.matches("safari"))

        let safari = top["Safari"]!
        XCTAssertEqual(safari.count, 4)
        XCTAssertEqual(safari.children.map(\.title), ["Safari", "Web Content", "Web Networking"])
        XCTAssertEqual(safari.children[1].kind, .bucket)
        XCTAssertEqual(safari.children[1].count, 2)
        XCTAssertTrue(safari.children[1].detail.contains("does not say which tab"))
        XCTAssertTrue(safari.matches("webcontent"))

        XCTAssertEqual(mac["WindowServer"]!.kind, .notable)
        XCTAssertFalse(mac["WindowServer"]!.stoppable)
        XCTAssertFalse(top["macOS"]!.stoppable)
        XCTAssertEqual(top["macOS"]!.count, 2)
        XCTAssertTrue(top["macOS"]!.detail.contains("busiest"))
        XCTAssertEqual(top["postgres"]!.count, 2)  // workers join the process responsible for them
        XCTAssertEqual(top["lonely"]!.kind, .process)
        XCTAssertTrue(top["lonely"]!.children.isEmpty)
        XCTAssertEqual(tree.map(\.count).reduce(0, +), samples.count)

        // Without the responsibility record, bundles and parents still find the owner.
        let fallback = ProcessGrouping.tree(
            samples.map { var s = $0; s.responsible = nil; return s }, apps: apps, home: home)
        XCTAssertEqual(fallback.first { $0.title == "cmux" }!.count, 8)

        // Every row has its own id, or SwiftUI draws the outline wrong.
        func ids(_ nodes: [ProcessNode]) -> [String] { nodes.flatMap { [$0.id] + ids($0.children) } }
        XCTAssertEqual(Set(ids(tree)).count, ids(tree).count)
        // Ids stay stable between samples so unfolded rows stay unfolded.
        XCTAssertEqual(
            ProcessGrouping.tree(samples.reversed(), apps: apps, home: home).flatMap { [$0.id] + $0.children.map(\.id) }
                .sorted(), tree.flatMap { [$0.id] + $0.children.map(\.id) }.sorted())

        func named(_ name: String, _ path: String) -> String { ProcessGrouping.displayName(process(9, name, path: path)) }
        XCTAssertEqual(named("2.1.316", "/Users/me/.local/share/claude/versions/2.1.316"), "claude 2.1.316")
        XCTAssertEqual(named("1.2.3", "/opt/tool/1.2.3"), "tool 1.2.3")
        XCTAssertEqual(named("node", "/opt/homebrew/bin/node"), "node")
        XCTAssertEqual(named("com.apple.WebKit.WebContent", ""), "Web Content")
        // Things macOS registers as apps without being apps of their own (0.2.6).
        do {
            let cryptex = "/System/Volumes/Preboot/Cryptexes/OS/System/Library"
            let registered = apps + [
                ProcessOwnerApp(pid: 600, path: cryptex + "/AutoFill.xpc", id: "autofill", name: "AutoFill (cmux)", owner: false),
                ProcessOwnerApp(pid: 601, path: "/opt/homebrew/bin", id: "npm", name: "npm run dev", owner: false),
                ProcessOwnerApp(pid: 603, path: "/System/Applications/Stocks.app/Contents/PlugIns/StocksWidget.appex",
                    id: "stocks.widget", name: "StocksWidget", owner: false),
                ProcessOwnerApp(pid: 604, path: "/System/Library/CoreServices/WallpaperAgent.app", id: "wallpaper",
                    name: "Wallpaper", owner: false),
                ProcessOwnerApp(pid: 605, path: "/Applications/Tool.app", id: "tool", name: "Tool", owner: true),
            ]
            var extra = samples
            var autofill = process(600, "AutoFill", responsible: 100, path: cryptex + "/AutoFill.xpc/Contents/MacOS/AutoFill",
                system: true)
            autofill.label = "AutoFill (cmux)"
            extra.append(autofill)
            // A dev server whose terminal session closed: parented by launchd, still cmux's responsibility.
            var dev = process(601, "node", responsible: 100, path: "/opt/homebrew/bin/node", directory: "/Users/me/app")
            dev.label = "npm run dev"
            extra.append(dev)
            extra.append(process(602, "esbuild", parent: 601, responsible: 100, path: "/Users/me/app/node_modules/esbuild"))
            extra.append(process(603, "StocksWidget",
                path: "/System/Applications/Stocks.app/Contents/PlugIns/StocksWidget.appex/Contents/MacOS/StocksWidget",
                system: true))
            extra.append(process(604, "WallpaperAgent",
                path: "/System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent", system: true))
            extra.append(process(605, "Tool", path: "/Applications/Tool.app/Contents/MacOS/Tool"))
            var rootOwned = process(606, "rootd", path: "/opt/rootd")
            rootOwned.user = false
            extra.append(rootOwned)
            let smarter = ProcessGrouping.tree(extra, apps: registered, home: home)
            let rows = Dictionary(uniqueKeysWithValues: smarter.map { ($0.title, $0) })
            XCTAssertEqual(Set(rows.keys), ["cmux", "Safari", "macOS", "postgres", "lonely", "Tool", "rootd"])
            let system = Dictionary(uniqueKeysWithValues: rows["macOS"]!.children.map { ($0.title, $0) })
            XCTAssertEqual(
                Set(system.keys), ["WindowServer", "Spotlight indexing", "Widgets & extensions", "Background services"])
            let terminal = rows["cmux"]!
            XCTAssertEqual(terminal.count, 11)
            XCTAssertTrue(terminal.children.contains { $0.title == "AutoFill (cmux)" && $0.kind == .process })
            let left = terminal.children.first { $0.kind == .leftover }!
            XCTAssertEqual(left.title, "Left running")
            XCTAssertEqual(left.count, 2)
            XCTAssertTrue(left.detail.contains("terminal session that started it has closed"))
            XCTAssertEqual(left.children.map(\.title), ["npm run dev · app"])
            XCTAssertEqual(left.children[0].children.map(\.title), ["npm run dev", "esbuild"])
            XCTAssertTrue(left.children[0].children[0].detail.contains("node"))
            XCTAssertEqual(system["Widgets & extensions"]!.count, 1)
            XCTAssertEqual(system["Widgets & extensions"]!.children.map(\.title), ["Widgets"])
            // The usual suspects of a slow Mac leave the macOS row for their own.
            XCTAssertEqual(system["WindowServer"]!.kind, .notable)
            XCTAssertTrue(system["WindowServer"]!.detail.contains("DisplayLink"))
            XCTAssertEqual(system["Spotlight indexing"]!.count, 1)
            XCTAssertEqual(system["Background services"]!.count, 1)  // WallpaperAgent
            XCTAssertEqual(rows["macOS"]!.count, 4)
            XCTAssertEqual(rows["Tool"]!.kind, .app)
            XCTAssertEqual(rows["Tool"]!.appID, "tool")
            // Stopping is offered only for the user's own processes outside macOS.
            XCTAssertTrue(left.stoppable && terminal.stoppable)
            // A session is stoppable through its own processes; root-owned login is left to end with its shell.
            let kolomSession = terminal.children.first { $0.title == "zsh · kolom" }!
            XCTAssertTrue(kolomSession.stoppable)
            XCTAssertEqual(Set(kolomSession.pids), [111, 112, 113])
            XCTAssertFalse(terminal.children.first { $0.title == "AutoFill (cmux)" }!.stoppable)
            XCTAssertFalse(rows["macOS"]!.stoppable)
            XCTAssertFalse(rows["rootd"]!.stoppable)
            XCTAssertTrue(rows["lonely"]!.stoppable)
            XCTAssertEqual(Set(left.pids), [601, 602])
            XCTAssertEqual(Set(ids(smarter)).count, ids(smarter).count)
            XCTAssertEqual(smarter.map(\.count).reduce(0, +), extra.count)
        }
        XCTAssertTrue(ProcessOwnerApp.isOwner(regular: true, accessory: false, path: "/System/Library/CoreServices/Finder.app"))
        XCTAssertTrue(ProcessOwnerApp.isOwner(regular: false, accessory: true, path: "/Applications/Kolom.app"))
        XCTAssertFalse(ProcessOwnerApp.isOwner(regular: false, accessory: true, path: "/System/Library/CoreServices/WallpaperAgent.app"))
        XCTAssertFalse(ProcessOwnerApp.isOwner(regular: false, accessory: false, path: "/Applications/X.app"))
        // nettop -P -d -x -J bytes_in,bytes_out
        XCTAssertTrue(NettopParser.isHeader(",bytes_in,bytes_out,"))
        XCTAssertTrue(NettopParser.line(",bytes_in,bytes_out,") == nil)
        XCTAssertEqual(NettopParser.line("gh.37667,5000,2186,")!.pid, 37667)
        XCTAssertEqual(NettopParser.line("gh.37667,5000,2186,")!.bytes, 7186)
        XCTAssertEqual(NettopParser.line("com.apple.WebKi.1320,200,30,")!.pid, 1320)
        XCTAssertEqual(NettopParser.line("2.1.299.1559,1,2,")!.pid, 1559)
        XCTAssertEqual(NettopParser.line("odd,name.42,1,2,")!.pid, 42)
        XCTAssertTrue(NettopParser.line("garbage") == nil)
        XCTAssertTrue(NettopParser.line("x.notapid,1,2,") == nil)
        let twoSamples = ",bytes_in,bytes_out,\ngh.7,900,100,\n,bytes_in,bytes_out,\ngh.7,30,10,\nnode.8,0,0,\n"
        XCTAssertEqual(NettopParser.rates(twoSamples)![7]!, 40)
        XCTAssertEqual(NettopParser.rates(twoSamples)![8]!, 0)
        XCTAssertTrue(NettopParser.rates(",bytes_in,bytes_out,\ngh.7,900,100,\n") == nil)  // stopped early
        let listing = PSListing.parse(
            "  609     1    88  16.0 108800 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer\n"
                + "81761     1   501   4.7 208064 /Applications/DisplayLink Manager.app/Contents/MacOS/DisplayLinkUserAgent\nbad line\n")
        XCTAssertEqual(listing.count, 2)
        XCTAssertEqual(listing[609]!.uid, 88)
        XCTAssertEqual(listing[609]!.cpu, 16.0)
        XCTAssertEqual(listing[609]!.memory, 108800 * 1024)
        XCTAssertEqual(listing[81761]!.path, "/Applications/DisplayLink Manager.app/Contents/MacOS/DisplayLinkUserAgent")
        XCTAssertTrue(ProcessSample.isSystem(path: "/usr/sbin/cfprefsd", uid: 501))
        XCTAssertTrue(ProcessSample.isSystem(path: "/opt/x", uid: 0))
        XCTAssertFalse(ProcessSample.isSystem(path: "/bin/zsh", uid: 501))
        XCTAssertEqual(ProcessGrouping.abbreviate("/Users/me/a", home: home), "~/a")
        XCTAssertEqual(ProcessGrouping.abbreviate("/Users/meow", home: home), "/Users/meow")
        XCTAssertTrue(ProcessGrouping.sum([nil, nil]) == nil)
        XCTAssertTrue(processGPUShare(previous: nil, current: 5, elapsed: 2) == nil)
        XCTAssertTrue(processGPUShare(previous: 9, current: 5, elapsed: 2) == nil)
        XCTAssertEqual(processGPUShare(previous: 0, current: 1_000_000_000, elapsed: 2)!, 0.5)
        print("PASS: performance groups processes by responsible app, session and kind, with GPU shares, network and stop rules")
    }

    do {
        let script = UpdateCheck.terminalScript(checkout: "/Users/me/Kolom's code")
        XCTAssertTrue(script.hasPrefix("#!/bin/zsh\n"))
        XCTAssertTrue(
            script.contains(
                "cd '/Users/me/Kolom'\\''s code' && git pull --ff-only && ./scripts/install.sh --quit-running\nresult=$?"))
        // A failed update reopens the installed Kolom so windows are not left unmanaged.
        XCTAssertTrue(script.contains("pgrep -xq Kolom || open -a Kolom"))
        print("PASS: Update now runs the quoted update command and reopens Kolom if it stops")
    }

}
