import AppKit
import KolomCore

/// `Kolom --smoke-test <folder>`: the built app opens its panels and drives them
/// the way a person would, then quits on SIGTERM, writing a report and renders to
/// the folder. It never manages windows, registers shortcuts, checks for updates
/// or touches Kolom's real storage; it uses a throwaway folder instead.
enum SmokeMode {
    static let output: URL? = {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--smoke-test") else { return nil }
        let path =
            arguments.indices.contains(flag + 1)
            ? arguments[flag + 1] : NSTemporaryDirectory() + "kolom-smoke-\(getpid())"
        return URL(fileURLWithPath: path, isDirectory: true)
    }()
    static var active: Bool { output != nil }
    /// Kolom's storage for the run, inside the output folder.
    static let storage: URL? = output?.appendingPathComponent("storage", isDirectory: true)
}

final class SmokeTest {
    private struct Step {
        let name: String
        let timeout: TimeInterval
        let action: () -> Void
        let done: () -> Bool
        let check: () -> String?
    }
    private let delegate: AppDelegate
    private let output: URL
    private var steps: [Step] = []
    private var results: [[String: Any]] = []
    private var tree: URL { output.appendingPathComponent("tree", isDirectory: true) }
    /// Each display's desktop picture when the run began; a smoke run must leave them be.
    private var desktops: [String: String] = [:]

    init(delegate: AppDelegate, output: URL) {
        self.delegate = delegate
        self.output = output
    }

    private var model: KolomController { delegate.model }

    func start() {
        desktops = Self.desktopPictures()
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        makeTree()
        define()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.next(0) }
    }

    private func makeTree() {
        let fm = FileManager.default
        try? fm.removeItem(at: tree)
        for (path, size) in [
            ("keep/photo.raw", 3_000_000), ("junk/cache/blob", 4_000_000), ("junk/old.log", 1_500_000),
            ("tool/Cargo.toml", 200), ("tool/target/debug/app", 2_500_000),
        ] {
            let url = tree.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: Data(repeating: 7, count: size))
        }
    }

    private func define() {
        let monitor = ResourceMonitor.shared
        steps = [
            Step(
                name: "launch", timeout: 10, action: {}, done: { !self.model.displays.isEmpty },
                check: {
                    self.model.enabled ? "window management started in smoke mode" : nil
                }),
            Step(
                name: "performance panel shows grouped processes", timeout: 25,
                action: { self.model.togglePerformance(self.model.displays.first?.id) },
                done: {
                    self.delegate.performancePanel?.isVisible == true && monitor.detailsReady
                        && monitor.nodes.count > 3
                },
                check: {
                    let all = self.flatten(monitor.nodes)
                    guard all.contains(where: { $0.pids.contains(getpid()) || $0.pid == getpid() }) else {
                        return "this process is not in the table"
                    }
                    guard monitor.cpu != nil else { return "no CPU reading" }
                    return self.render(self.delegate.performancePanel, "performance")
                }),
            Step(
                name: "disk map scans a folder", timeout: 25,
                action: {
                    self.model.openDiskMap(.init(path: self.tree.path, name: "smoke tree", startupDisk: false))
                },
                done: { self.delegate.diskMapModel?.root != nil && self.delegate.diskMapPanel?.isVisible == true },
                check: {
                    guard let map = self.delegate.diskMapModel, let root = map.root else { return "no scan" }
                    guard root.size >= 10_000_000 else { return "scan measured \(root.size) bytes" }
                    guard root.child(named: "tool")?.child(named: "target")?.reclaim == .buildOutput else {
                        return "target beside Cargo.toml not recognised as build output"
                    }
                    guard !self.model.viewport(self.model.displays.first!).isEmpty else { return "no viewport" }
                    return self.render(self.delegate.diskMapPanel, "disk-map")
                }),
            Step(
                name: "disk map marks and deletes", timeout: 15,
                action: {
                    guard let map = self.delegate.diskMapModel, let junk = map.root?.child(named: "junk") else { return }
                    map.toggleMark(junk)
                    if let root = map.root { map.toggleMark(root) }  // the mapped folder itself is refused
                    map.removeMarked(permanently: true)
                },
                done: {
                    guard let map = self.delegate.diskMapModel else { return false }
                    return map.removing == nil && map.notice != nil
                },
                check: {
                    let fm = FileManager.default
                    guard !fm.fileExists(atPath: self.tree.appendingPathComponent("junk").path) else {
                        return "the marked folder is still there"
                    }
                    guard fm.fileExists(atPath: self.tree.appendingPathComponent("keep/photo.raw").path) else {
                        return "an unmarked file was removed"
                    }
                    guard self.delegate.diskMapModel?.root?.child(named: "junk") == nil else {
                        return "the map still shows the removed folder"
                    }
                    return nil
                }),
            Step(
                name: "disk map closes and frees its scan", timeout: 5, action: { self.model.closeDiskMap() },
                done: { self.delegate.diskMapPanel == nil && self.delegate.diskMapModel == nil },
                check: { self.model.diskMapShown ? "still reserved beside Performance" : nil }),
            Step(
                name: "guide opens and closes", timeout: 10, action: { self.model.toggleGuide() },
                done: { self.delegate.guidePanel?.isVisible == true },
                check: {
                    let rendered = self.render(self.delegate.guidePanel, "guide")
                    self.model.toggleGuide()
                    return rendered
                }),
            Step(
                name: "desktop pictures untouched", timeout: 2, action: {}, done: { true },
                check: {
                    let now = Self.desktopPictures()
                    let changed = now.filter { self.desktops[$0.key] != $0.value }.map(\.key)
                    return changed.isEmpty ? nil : "changed on \(changed.count) display(s)"
                }),
        ]
    }

    static func desktopPictures() -> [String: String] {
        Dictionary(
            NSScreen.screens.map { screen in
                (screen.localizedName + "\(screen.frame)", NSWorkspace.shared.desktopImageURL(for: screen)?.path ?? "")
            }, uniquingKeysWith: { a, _ in a })
    }

    private func next(_ index: Int) {
        guard index < steps.count else {
            finish(passed: true)
            return
        }
        let step = steps[index]
        let started = Date()
        step.action()
        func poll() {
            if step.done() {
                let failure = step.check()
                record(step.name, ok: failure == nil, seconds: Date().timeIntervalSince(started), detail: failure)
                if failure != nil {
                    finish(passed: false)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.next(index + 1) }
                }
            } else if Date().timeIntervalSince(started) > step.timeout {
                record(step.name, ok: false, seconds: step.timeout, detail: "timed out")
                finish(passed: false)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { poll() }
            }
        }
        poll()
    }

    private func record(_ name: String, ok: Bool, seconds: TimeInterval, detail: String?) {
        var entry: [String: Any] = ["step": name, "ok": ok, "seconds": (seconds * 100).rounded() / 100]
        if let detail { entry["detail"] = detail }
        results.append(entry)
        print("smoke: \(ok ? "PASS" : "FAIL") \(name)\(detail.map { " · \($0)" } ?? "")")
    }

    /// Writes the report; on success, quits through SIGTERM as the installer does.
    private func finish(passed: Bool) {
        let report: [String: Any] = [
            "passed": passed, "build": BuildInfo.label, "steps": results,
            "displays": model.displays.map { ["id": $0.id, "frame": "\($0.frame)"] },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("smoke-report.json"))
        }
        guard passed else { exit(1) }
        print("smoke: quitting on SIGTERM")
        kill(getpid(), SIGTERM)
    }

    private func flatten(_ nodes: [ProcessNode]) -> [ProcessNode] {
        nodes.flatMap { [$0] + flatten($0.children) }
    }

    /// Draws a panel to a PNG; a blank or single-colour panel fails.
    private func render(_ window: NSWindow?, _ name: String) -> String? {
        guard let view = window?.contentView, view.bounds.width > 10, view.bounds.height > 10 else {
            return "\(name): no content"
        }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "\(name): no bitmap" }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: output.appendingPathComponent("\(name).png"))
        }
        var colours = Set<UInt32>()
        let stepX = max(1, bitmap.pixelsWide / 60)
        let stepY = max(1, bitmap.pixelsHigh / 60)
        for x in stride(from: 0, to: bitmap.pixelsWide, by: stepX) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                colours.insert(
                    UInt32(colour.redComponent * 31) << 10 | UInt32(colour.greenComponent * 31) << 5
                        | UInt32(colour.blueComponent * 31))
            }
        }
        return colours.count < 8 ? "\(name): drew only \(colours.count) colours" : nil
    }
}
