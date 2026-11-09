import AppKit
import ApplicationServices
import SwiftUI
import KolomCore

/// What Kolom writes down: layout, live state, pauses, window events, geometry.
extension KolomController {
    /// Why windows left and came back, so a layout that "lost something" can be explained.
    func logWindowEvent(_ event: String, id: String, detail: String) {
        var log =
            (try? Data(contentsOf: windowEventsURL)).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]]
            } ?? []
        var entry: [String: Any] = [
            "time": Date().timeIntervalSince1970, "event": event, "window": id, "detail": detail,
            "build": BuildInfo.label,
        ]
        if let w = windows[id] {
            entry["app"] = w.bundleID
            entry["title"] = String(w.title.prefix(60))
        }
        log.append(entry)
        if let data = try? JSONSerialization.data(withJSONObject: Array(log.suffix(60)), options: [.sortedKeys]) {
            try? data.write(to: windowEventsURL, options: .atomic)
        }
    }
    /// Keep the last pauses on disk: a pause restores every window and removes the
    /// rails, which looks like a crash unless its reason can be read afterwards.
    func logPause(_ reason: String, detail: String? = nil) {
        var log =
            (try? Data(contentsOf: pauseLogURL)).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]]
            } ?? []
        var entry: [String: Any] = [
            "time": Date().timeIntervalSince1970, "reason": reason,
            "version": BuildInfo.version, "build": BuildInfo.label,
        ]
        if let detail { entry["detail"] = detail }
        log.append(entry)
        if let data = try? JSONSerialization.data(withJSONObject: Array(log.suffix(30)), options: [.sortedKeys]) {
            try? data.write(to: pauseLogURL, options: .atomic)
        }
    }
    func takePauseReason() -> String {
        defer { pauseReason = nil }
        return pauseReason.map { " · " + $0 } ?? ""
    }
    func saveLayout() {
        guard !demo else { return }
        pendingSave?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.flushLayout() }
        pendingSave = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
    }
    func flushLayout() {
        pendingSave?.cancel()
        pendingSave = nil
        guard !demo, let data = try? JSONEncoder().encode(workspaces) else { return }
        try? data.write(to: stateURL, options: .atomic)
        if let history = try? JSONEncoder().encode(displayMemory) {
            try? history.write(to: displayMemoryURL, options: .atomic)
        }
    }
    func recordResize(_ id: String, axis: String, phase: String, start: Double, delta: Double) {
        resizeDiagnostics.append([
            "time": Date().timeIntervalSince1970, "window": id, "axis": axis, "phase": phase, "start": start,
            "delta": delta,
        ])
        if resizeDiagnostics.count > 64 { resizeDiagnostics.removeFirst(resizeDiagnostics.count - 64) }
        if let data = try? JSONSerialization.data(withJSONObject: resizeDiagnostics, options: [.sortedKeys]) {
            try? data.write(to: storage.appendingPathComponent("resize-feedback.json"), options: .atomic)
        }
    }
    func writeLiveState() {
        func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }
        let rendered =
            (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]) ?? []
        let full = displays.map(\.fullFrame)
        let rows = displays.enumerated().map { index, d -> [String: Any] in
            let space = workspaces[d.id] ?? Workspace()
            return [
                "id": d.id, "index": index + 1, "name": d.name, "bounds": rect(full[index]),
                "viewport": rect(viewport(d)), "offset": space.offset,
                "columns": space.columns.map { c -> [String: Any] in
                    [
                        "width": c.width,
                        "windows": c.tiles.compactMap { tile -> [String: Any]? in
                            guard let w = windows[tile.id] else { return nil }
                            let actual =
                                bridge.unresponsivePIDs.contains(w.pid) ? w.frame : bridge.frame(w.element) ?? w.frame
                            let number = UInt32(w.id.split(separator: ":").last ?? "")
                            let cg = rendered.first {
                                ($0[kCGWindowNumber as String] as? UInt32) == number
                                    && ($0[kCGWindowOwnerPID as String] as? Int32) == w.pid
                            }
                            let drawn = (cg?[kCGWindowBounds as String] as? [String: Any]).flatMap {
                                CGRect(dictionaryRepresentation: $0 as CFDictionary)
                            }
                            let overlaps = displays.indices.filter { $0 != index }.compactMap {
                                other -> [String: Any]? in
                                let intersection = actual.intersection(full[other])
                                guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
                                    return nil
                                }
                                return [
                                    "display": displays[other].id, "width": intersection.width,
                                    "height": intersection.height,
                                ]
                            }
                            let drawnOverlaps = displays.indices.filter { $0 != index }.compactMap {
                                other -> [String: Any]? in
                                guard let drawn else { return nil }
                                let intersection = drawn.intersection(full[other])
                                guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
                                    return nil
                                }
                                return [
                                    "display": displays[other].id, "width": intersection.width,
                                    "height": intersection.height,
                                ]
                            }
                            return [
                                "id": w.id, "app": w.bundleID, "actual": rect(actual),
                                "requested": expected[w.id].map(rect) ?? [], "offStrip": offStrip.contains(w.id),
                                "foreignOverlaps": overlaps, "onScreen": cg != nil,
                                "renderedBounds": drawn.map(rect) ?? [], "renderedForeignOverlaps": drawnOverlaps,
                            ]
                        },
                    ]
                },
            ]
        }
        let state: [String: Any] = [
            "pid": getpid(), "permissionGranted": permissionGranted, "restoring": restoring,
            "recoveryAvailable": recoveryAvailable, "timestamp": Date().timeIntervalSince1970,
            "version": BuildInfo.version, "build": BuildInfo.label, "update": updates.liveState, "enabled": enabled,
            "suspended": suspension?.rawValue ?? NSNull(),

            "agentBusy": agentBusy, "desktopColumnRatio": 1.1,
            "displayArrangement": arrangement.status, "pointerWarps": pointerRouter.warpCount,
            "isolateDisplays": isolateDisplays, "status": status, "parking": "per-display-safe-edge",
            "presentation": "native windows; displays kept apart while managing", "displays": rows,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            try? data.write(to: storage.appendingPathComponent("live-state.json"), options: .atomic)
        }
    }
    func recordGeometryObservation(_ window: NativeWindow, requested: CGRect, decision: GeometryFeedback.Decision) {
        guard decision != .unchanged else { return }
        let actual = window.frame
        let signature = "\(decision):\(actual)"
        guard lastGeometryObservation[window.id] != signature else { return }
        lastGeometryObservation[window.id] = signature
        func values(_ frame: CGRect) -> [Double] { [frame.minX, frame.minY, frame.width, frame.height] }
        geometryDiagnostics.append([
            "time": Date().timeIntervalSince1970, "window": window.id, "app": window.bundleID,
            "decision": String(describing: decision), "requested": values(requested), "actual": values(actual),
        ])
        if geometryDiagnostics.count > 64 { geometryDiagnostics.removeFirst(geometryDiagnostics.count - 64) }
        if let data = try? JSONSerialization.data(withJSONObject: geometryDiagnostics, options: [.sortedKeys]) {
            try? data.write(to: storage.appendingPathComponent("geometry-feedback.json"), options: .atomic)
        }
    }
    var traceURL: URL { storage.appendingPathComponent("display-trace.json") }
    /// Records a display or Space event (kept: the last 400, written within a second).
    func record(_ event: String, _ detail: [String: Any] = [:]) {
        var entry = detail
        entry["t"] = (Date().timeIntervalSince1970 * 1000).rounded() / 1000
        entry["event"] = event
        trace.append(entry)
        if trace.count > 400 { trace.removeFirst(trace.count - 400) }
        if ["reconfig", "space", "screens", "staircase", "suspend", "resume"].contains(event) {
            traceDetailUntil = Date().addingTimeInterval(15)
        }
        guard traceWrite == nil else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.traceWrite = nil
            if let data = try? JSONSerialization.data(withJSONObject: self.trace, options: [.sortedKeys]) {
                try? data.write(to: self.traceURL, options: .atomic)
            }
        }
        traceWrite = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: task)
    }
    func recordReconfiguration(_ display: CGDirectDisplayID, _ flags: UInt32) {
        let names: [(UInt32, String)] = [
            (1 << 0, "begin"), (1 << 1, "moved"), (1 << 2, "main"), (1 << 3, "mode"), (1 << 4, "added"),
            (1 << 5, "removed"), (1 << 8, "enabled"), (1 << 9, "disabled"), (1 << 10, "mirror"),
            (1 << 11, "unmirror"), (1 << 12, "shape"),
        ]
        record(
            "reconfig",
            ["display": Int(display), "flags": names.filter { flags & $0.0 != 0 }.map(\.1).joined(separator: ",")])
    }
}
