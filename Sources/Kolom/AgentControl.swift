import AppKit
import ApplicationServices
import KolomCore

/// Explicitly enabled, same-user file IPC. No network listener or arbitrary code.
/// Terminal creation uses a fixed native Apple event without shell text.
final class AgentControl {
    let model: KolomController
    let root: URL
    var session: AgentSession?
    var timer: Timer?
    var active: GridTransaction?
    var cancelled = Set<UUID>()
    var traceTimer: Timer?
    var trace: [[String: Any]] = []
    /// Requests the user typed into Kolom itself (Ask Kolom). They need no agent
    /// session, and their replies come back to the caller instead of a file.
    var userRequests = Set<UUID>()
    var userReplies: [UUID: [String: Any]] = [:]
    /// Called when a user's grid finishes: whether it was applied, and the detail.
    var userCompletions: [UUID: (Bool, String) -> Void] = [:]
    /// Grids made through Ask Kolom this session, oldest first; only these are undone by it.
    var userGrids: [UUID] = []
    init(model: KolomController) {
        self.model = model
        root = model.storage.appendingPathComponent("agent", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: root.appendingPathComponent("requests"), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? FileManager.default.createDirectory(
            at: root.appendingPathComponent("responses"), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? FileManager.default.createDirectory(
            at: root.appendingPathComponent("operations"), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root.appendingPathComponent("session.json"))
        // Requests and unread responses from an earlier run belong to a revoked session.
        for folder in ["requests", "responses"] {
            for file
                in (try? FileManager.default.contentsOfDirectory(
                    at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)) ?? []
            {
                try? FileManager.default.removeItem(at: file)
            }
        }
        // Keep the newest 50 well-formed operations; anything else is removed.
        var operations: [GridTransaction] = []
        for file
            in (try? FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("operations"), includingPropertiesForKeys: nil)) ?? []
        {
            if let op = load(file) { operations.append(op) } else { try? FileManager.default.removeItem(at: file) }
        }
        operations.sort { $0.updated > $1.updated }
        for op in operations.dropFirst(50) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("operations/\(op.id.uuidString).json"))
        }
        for var op in operations.prefix(50) where ["creating", "verifying", "undoing"].contains(op.phase) {
            op.phase = "interrupted"
            op.detail = "Kolom stopped during this operation. Created windows are retained; check undoAvailable."
            save(op)
        }
    }
    var enabled: Bool { session != nil }
    func setEnabled(_ enabled: Bool) {
        if !enabled {
            session = nil
            timer?.invalidate()
            timer = nil
            try? FileManager.default.removeItem(at: root.appendingPathComponent("session.json"))
            if let active { cancelled.insert(active.id) }
            return
        }
        guard !self.enabled else { return }
        let value = AgentSession(pid: getpid())
        session = value
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: root.appendingPathComponent("session.json"), options: .atomic)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.poll() }
    }
    func stop() {
        setEnabled(false)
        traceTimer?.invalidate()
        traceTimer = nil
    }
    func load(_ file: URL) -> GridTransaction? {
        guard file.pathExtension == "json",
            let fileID = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
            let data = readSmallRegularFile(file, limit: agentOperationLimit),
            let op = try? JSONDecoder().decode(GridTransaction.self, from: data), op.isWellFormed(fileID: fileID)
        else { return nil }
        return op
    }
    func save(_ op: GridTransaction) {
        if let data = try? JSONEncoder().encode(op) {
            try? data.write(to: root.appendingPathComponent("operations/\(op.id.uuidString).json"), options: .atomic)
        }
    }
    func summary(_ op: GridTransaction) -> [String: Any] {
        [
            "ok": !["failed", "partial", "undo_partial", "cancelled", "interrupted"].contains(op.phase),
            "operation": op.id.uuidString, "phase": op.phase, "detail": op.detail,
            "createdWindows": op.createdIDs.count, "requestedWindows": op.columns * op.rows,
            "verifiedWindows": op.verified, "displayID": op.displayID, "groupID": op.groupID?.uuidString ?? "",
            "undoAvailable": op.undoAvailable, "undoKeepsWindowsOpen": true,
        ]
    }
    func reply(_ id: UUID, _ result: [String: Any]) {
        if userRequests.contains(id) {
            userReplies[id] = result
            return
        }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("responses/\(id.uuidString).json"), options: .atomic)
        }
    }
    func failure(_ text: String) -> [String: Any] {
        KolomGuidance.failure(
            text, hint: "Inspect kolomctl state or operation status; no arbitrary shell execution is available.")
    }
    func poll() {
        guard let session else { return }
        let files =
            ((try? FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("requests"), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        // Read every pending request, discard unusable files so they cannot block
        // the queue, and handle requests in the order clients created them.
        var pending: [(id: UUID, created: Double, data: Data)] = []
        for file in files.prefix(64) {
            // Claim by atomic rename first: a client that withdraws a timed-out
            // request either wins (never run) or finds it already claimed.
            let claimed = file.deletingPathExtension().appendingPathExtension("claimed")
            guard rename(file.path, claimed.path) == 0 else { continue }
            defer { try? FileManager.default.removeItem(at: claimed) }
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                let data = readSmallRegularFile(claimed, limit: agentRequestLimit)
            else { continue }
            let created = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["created"] as? Double
            pending.append((id, created ?? 0, data))
        }
        pending.sort { ($0.created, $0.id.uuidString) < ($1.created, $1.id.uuidString) }
        for (id, _, data) in pending {
            guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                Set(raw.keys).isSubset(of: [
                    "id", "session", "created", "action", "columns", "rows", "displayID", "name", "operation",
                ]), let request = try? JSONDecoder().decode(AgentRequest.self, from: data), request.id == id,
                request.session == session.token, abs(Date().timeIntervalSince1970 - request.created) < 30
            else {
                reply(id, failure("Invalid, expired or unauthorized request"))
                continue
            }
            switch request.action {
            case "close-terminals": closeTerminals(request)
            case "create-grid": create(request)
            case "operation":
                if let op = request.operation,
                    let value = load(root.appendingPathComponent("operations/\(op.uuidString).json"))
                {
                    reply(id, summary(value))
                } else {
                    reply(id, failure("Unknown operation"))
                }
            case "undo": undo(request)
            case "redo": redo(request)
            case "cancel":
                if let op = request.operation, active?.id == op {
                    cancelled.insert(op)
                    reply(id, ["ok": true, "phase": "cancellation_requested", "operation": op.uuidString])
                } else {
                    reply(id, failure("No matching active operation"))
                }
            case "navigate":
                guard self.model.acting, !self.model.agentBusy, let display = request.displayID,
                    self.model.displays.contains(where: { $0.id == display }), let action = request.name,
                    ["desktop", "next", "previous"].contains(action)
                else {
                    reply(id, failure("Expected an idle enabled display and desktop, next, or previous"))
                    continue
                }
                self.model.activeDisplay = display
                self.model.displayIntentUntil = max(self.model.displayIntentUntil, Date().addingTimeInterval(1))
                if action == "desktop" {
                    self.model.showDesktop()
                } else {
                    self.model.navigate(action == "next" ? 1 : -1)
                }
                reply(
                    id,
                    [
                        "ok": true, "phase": "animating", "displayID": display,
                        "note": "Read state after animation to verify the resulting offset.",
                    ])
            case "trace-scroll":
                startTrace()
                reply(
                    id,
                    [
                        "ok": true, "phase": "recording", "seconds": 5, "file": "scroll-trace.json",
                        "note":
                            "Scroll normally now. This records numeric rendered bounds, not screen pixels or input.",
                    ])
            default: reply(id, failure("Unknown action"))
            }
        }
    }
    /// Create a Terminal grid the user asked for. Returns the immediate reply:
    /// accepted (windows then open one by one) or why it cannot run.
    func createForUser(
        columns: Int, rows: Int, displayID: String, done: @escaping (Bool, String) -> Void
    ) -> [String: Any] {
        let request = AgentRequest(session: "", action: "create-grid", columns: columns, rows: rows, displayID: displayID)
        let reply = runForUser(request) { self.create($0) }
        if reply["ok"] as? Bool == true {
            userCompletions[request.id] = done
            userGrids.append(request.id)
        } else {
            userRequests.remove(request.id)
        }
        return reply
    }
    /// Undo the most recent Ask Kolom grid that can still be undone.
    func undoLatestForUser() -> [String: Any] {
        let latest = userGrids.reversed().lazy.compactMap {
            self.load(self.root.appendingPathComponent("operations/\($0.uuidString).json"))
        }.first { $0.undoAvailable }
        guard let latest else { return failure("There is no Ask Kolom grid to undo") }
        let request = AgentRequest(session: "", action: "undo", operation: latest.id)
        defer { userRequests.remove(request.id) }
        return runForUser(request) { self.undo($0) }
    }
    private func runForUser(_ request: AgentRequest, _ run: (AgentRequest) -> Void) -> [String: Any] {
        userRequests.insert(request.id)
        run(request)
        return userReplies.removeValue(forKey: request.id) ?? ["ok": true]
    }
    func closeTerminals(_ request: AgentRequest) {
        guard request.name == "confirmed", active == nil, !model.agentBusy, !model.restoring, model.bridge.trusted
        else {
            reply(request.id, failure("Explicit confirmation, idle Kolom and window-control permission are required"))
            return
        }
        // Only Apple Terminal windows present at the time of this request.
        // Native close buttons retain busy-session warnings; never force-quit.
        let targets = model.bridge.terminalWindowElements()
        model.agentBusy = true
        let requested = targets.filter { model.bridge.requestClose($0) }.count
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            let remaining = self.model.bridge.terminalWindowElements()
            let stillOpen = targets.filter { target in remaining.contains { CFEqual(target, $0) } }.count
            self.model.agentBusy = false
            if self.model.enabled { self.model.refresh(force: true) }
            self.reply(
                request.id,
                [
                    "ok": stillOpen == 0, "phase": stillOpen == 0 ? "closed" : "needs_attention",
                    "targeted": targets.count, "closeRequestsAccepted": requested, "closed": targets.count - stillOpen,
                    "remaining": stillOpen, "currentTerminalWindows": remaining.count,
                    "note":
                        "Normal native close only. Busy-session warnings are not dismissed. Newly opened windows are not closed.",
                ])
        }
    }
    func create(_ request: AgentRequest) {
        if let old = load(root.appendingPathComponent("operations/\(request.id.uuidString).json")) {
            guard old.columns == request.columns, old.rows == request.rows, old.displayID == request.displayID else {
                reply(request.id, failure("Idempotency key belongs to a different request"))
                return
            }
            reply(request.id, summary(old))
            return
        }
        guard active == nil, !model.agentBusy, model.acting, !model.restoring, model.bridge.trusted,
            let columns = request.columns, let rows = request.rows, columns > 0, rows > 0, columns <= 30, rows <= 30,
            columns * rows <= 60, (request.name?.count ?? 0) <= 80, let display = request.displayID,
            let target = model.displays.first(where: { $0.id == display })
        else {
            reply(request.id, failure("Kolom must be enabled, idle, authorized and connected to the target display"))
            return
        }
        var test = Workspace()
        guard
            test.appendGrid(
                (0..<(columns * rows)).map { String($0) }, columns: columns, rows: rows,
                name: request.name ?? "Terminals", viewport: model.viewport(target).size) != nil
        else {
            reply(
                request.id,
                failure("Grid cells would be smaller than 260×120 points; use fewer rows/columns or a larger display"))
            return
        }
        model.animation?.invalidate()
        model.animation = nil
        let op = GridTransaction(
            id: request.id, displayID: display, columns: columns, rows: rows, name: request.name ?? "Terminals",
            before: model.workspaces)
        active = op
        save(op)
        model.agentBusy = true
        reply(
            request.id,
            [
                "ok": true, "phase": "accepted", "operation": op.id.uuidString, "requestedWindows": columns * rows,
                "note": "Accepted is not applied. Poll operation until verified.",
            ])
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        guard let url else {
            finish("failed", "Apple Terminal is not installed")
            return
        }
        let already = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first != nil
        let baseline = Set(
            model.bridge.discover(includeMinimized: true).filter { $0.bundleID == "com.apple.Terminal" }.map(\.id))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] app, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard error == nil, app != nil else {
                    self.finish("failed", "Terminal could not launch")
                    return
                }
                if !already { self.waitForNewWindow(baseline: baseline, remaining: 16) } else { self.createNext() }
            }
        }
    }
    func canContinue() -> Bool {
        guard let op = active else { return false }
        if cancelled.contains(op.id) || (!enabled && !userRequests.contains(op.id)) || !model.managing || !model.bridge.trusted
            || !model.displays.contains(where: { $0.id == op.displayID })
        {
            finish("cancelled", "Stopped. Already-created windows remain open; check undoAvailable.")
            return false
        }
        return true
    }
    func createNext() {
        guard canContinue(), let op = active else { return }
        if op.createdIDs.count == op.columns * op.rows {
            applyGrid()
            return
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first != nil else {
            finish("failed", "Terminal quit during creation")
            return
        }
        let baseline = Set(
            model.bridge.discover(includeMinimized: true).filter { $0.bundleID == "com.apple.Terminal" }.map(\.id))
        // Terminal's published scripting dictionary defines core/dosc with an
        // optional command. Omit both command and target: create a distinct
        // Terminal window without supplying shell text or relying on tab prefs.
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Terminal")
        let event = NSAppleEventDescriptor(
            eventClass: 0x636f7265, eventID: 0x646f7363, targetDescriptor: target, returnID: -1, transactionID: 0)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                _ = try event.sendEvent(options: [.waitForReply], timeout: 30)
                DispatchQueue.main.async { self?.waitForNewWindow(baseline: baseline, remaining: 16) }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    self?.finish(
                        "failed",
                        "Terminal's native window-creation request was declined: \(message). macOS Automation permission may need approval."
                    )
                }
            }
        }
    }
    func waitForNewWindow(baseline: Set<String>, remaining: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, var op = self.active else { return }
            let found = self.model.bridge.discover(includeMinimized: true).filter {
                $0.bundleID == "com.apple.Terminal" && !baseline.contains($0.id) && !op.createdIDs.contains($0.id)
            }
            let focused = self.model.bridge.focusedWindowID(
                in: uniqueByID(found, id: \.id))
            if let window = found.count == 1 ? found.first : found.first(where: { $0.id == focused }) {
                op.createdIDs.append(window.id)
                op.updated = Date().timeIntervalSince1970
                op.detail = "Created \(op.createdIDs.count) of \(op.columns*op.rows) distinct windows"
                self.active = op
                self.save(op)
                self.model.windows[window.id] = window
                let allowed =
                    self.model.managing && (self.enabled || self.userRequests.contains(op.id))
                    && !self.cancelled.contains(op.id)
                if allowed {
                    self.model.originals[window.id] = OriginalWindow(
                        id: window.id, pid: window.pid, frame: self.model.deskFrame(window.frame),
                        minimized: window.minimized,
                        bundleID: window.bundleID, title: window.title)
                    guard self.model.saveRecovery() else {
                        self.finish("failed", "Recovery checkpoint could not be saved")
                        return
                    }
                    if let target = self.model.displays.first(where: { $0.id == op.displayID }) {
                        let area = self.model.viewport(target)
                        let index = op.createdIDs.count - 1
                        let width = (area.width - Double(op.columns - 1) * 16) / Double(op.columns)
                        let height = (area.height - Double(op.rows - 1) * 16) / Double(op.rows)
                        let provisional = CGRect(
                            x: area.minX + Double(index / op.rows) * (width + 16),
                            y: area.minY + Double(index % op.rows) * (height + 16), width: width, height: height)
                        _ = self.model.bridge.setFrame(window, provisional)
                    }
                }
                if self.canContinue() { self.createNext() }
            } else if !self.canContinue() {
                return
            } else if remaining > 0 {
                self.waitForNewWindow(baseline: baseline, remaining: remaining - 1)
            } else {
                self.finish(
                    "failed",
                    "No distinct new Terminal window appeared. Existing tabs and unrelated windows were not substituted."
                )
            }
        }
    }
    func applyGrid() {
        guard canContinue(), var op = active, let display = model.displays.first(where: { $0.id == op.displayID })
        else { return }
        let found = model.bridge.discover(includeMinimized: true)
        for window in found { model.windows[window.id] = window }
        // Created windows are admitted as a single group, never reconciled into
        // ordinary columns midway through creation.
        // Plan on a copy so a grid that no longer fits leaves the layout untouched.
        guard let (spaces, group) = plannedGrid(op, on: display) else {
            finish("failed", "The target grid no longer fits")
            return
        }
        model.workspaces = spaces
        op.groupID = group
        op.phase = "verifying"
        op.detail = "Checking actual native bounds and overlap"
        active = op
        save(op)
        if let first = op.createdIDs.first {
            model.workspaces[display.id]?.reveal(first, viewportWidth: model.viewport(display).width)
        }
        model.activeDisplay = display.id
        model.expected = [:]
        model.apply()
        model.saveLayout()
        verify(remaining: 12)
    }
    func plannedGrid(_ op: GridTransaction, on display: DisplayModel) -> ([String: Workspace], UUID)? {
        var spaces = model.workspaces
        for id in op.createdIDs { for key in Array(spaces.keys) { _ = spaces[key]?.remove(id) } }
        guard
            let group = spaces[display.id, default: Workspace()].appendGrid(
                op.createdIDs, columns: op.columns, rows: op.rows, name: op.name, viewport: model.viewport(display).size
            )
        else { return nil }
        return (spaces, group)
    }
    func verify(remaining: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.canContinue(), var op = self.active,
                let display = self.model.displays.first(where: { $0.id == op.displayID })
            else { return }
            let area = self.model.viewport(display)
            let expected = self.model.workspaces[display.id]?.frames(in: area) ?? [:]
            var actual: [String: CGRect] = [:]
            for id in op.createdIDs {
                if let w = self.model.windows[id], let r = self.model.bridge.frame(w.element) { actual[id] = r }
            }
            let good = op.createdIDs.filter { id in
                guard let a = actual[id], let target = expected[id], area.insetBy(dx: -1, dy: -1).contains(a),
                    abs(a.minX - target.minX) < 4, abs(a.minY - target.minY) < 4, abs(a.width - target.width) < 16,
                    abs(a.height - target.height) < 16
                else { return false }
                return actual.allSatisfy { other, r in
                    if other == id { return true }
                    let i = r.intersection(a)
                    return i.isNull || i.width <= 1 || i.height <= 1
                }
            }
            op.verified = good.count
            self.active = op
            self.save(op)
            if good.count == op.createdIDs.count {
                self.finish(
                    "applied", "Verified \(good.count) Terminal windows in \(op.columns)×\(op.rows) on \(display.name)")
            } else if remaining > 0 {
                self.verify(remaining: remaining - 1)
            } else {
                self.finish(
                    "partial",
                    "Some native windows refused the planned bounds. \(good.count) of \(op.createdIDs.count) verified. Undo layout is available; windows remain open."
                )
            }
        }
    }
    func finish(_ phase: String, _ detail: String) {
        guard var op = active else { return }
        op.phase = phase
        op.detail = detail
        op.updated = Date().timeIntervalSince1970
        save(op)
        active = nil
        cancelled.remove(op.id)
        userRequests.remove(op.id)
        let done = userCompletions.removeValue(forKey: op.id)
        model.agentBusy = false
        if model.enabled { model.refresh(force: true) }
        model.status = detail
        model.writeLiveState()
        done?(phase == "applied", detail)
    }
    func undo(_ request: AgentRequest) {
        guard active == nil, !model.agentBusy, model.acting, let id = request.operation,
            var op = load(root.appendingPathComponent("operations/\(id.uuidString).json")), op.phase != "undone"
        else {
            reply(request.id, failure("No completed operation to undo, or another operation is running"))
            return
        }
        model.refresh(force: true)
        // Undo only this operation's grid. A whole-layout snapshot would also
        // revert later grids, the user's own changes and display-mode switches.
        // A partial undo already flattened the grid; a retry re-applies and verifies.
        let undone = op.groupID.flatMap { undoGrid($0, in: model.workspaces) }
        guard op.undoAvailable, undone != nil || op.phase == "undo_partial" else {
            reply(request.id, failure("This operation's grid is no longer in the layout; nothing was changed"))
            return
        }
        model.agentBusy = true
        if let undone { model.workspaces = undone }
        for d in model.displays {
            model.workspaces[d.id]?.clampOffset(viewportWidth: model.viewport(d).width, desktopTail: true)
        }
        model.expected = [:]
        model.apply()
        model.saveLayout()
        op.phase = "undoing"
        op.detail = "Verifying the previous arrangement. Created Terminal sessions remain open."
        op.updated = Date().timeIntervalSince1970
        save(op)
        reply(request.id, summary(op))
        let originalIDs = Set(op.before.values.flatMap(\.windowIDs))
        func verifyUndo(_ remaining: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                guard self.model.managing else {
                    op.phase = "interrupted"
                    op.detail = "Kolom paused during undo; restoration was not claimed as verified."
                    self.save(op)
                    self.model.agentBusy = false
                    return
                }
                let expected = self.model.expected
                // A live window that never accepted a move is missing from expected; count it.
                let checked = Set(expected.keys).union(op.createdIDs.filter { self.model.windows[$0] != nil })
                let mismatches = checked.filter { id in
                    guard let w = self.model.windows[id], let a = self.model.bridge.frame(w.element),
                        let b = expected[id]
                    else { return true }
                    let requiresSize = originalIDs.contains(id) || !self.model.offStrip.contains(id)
                    return abs(a.minX - b.minX) > 4 || abs(a.minY - b.minY) > 4
                        || (requiresSize && (abs(a.width - b.width) > 16 || abs(a.height - b.height) > 16))
                }
                if !mismatches.isEmpty, remaining > 0 {
                    verifyUndo(remaining - 1)
                    return
                }
                op.phase = mismatches.isEmpty ? "undone" : "undo_partial"
                op.verified = op.createdIDs.filter { expected[$0] != nil && !mismatches.contains($0) }.count
                op.detail =
                    mismatches.isEmpty
                    ? "Previous arrangement and all window positions verified. New Terminal sessions remain open; parked sessions retain planned sizes and resize when revealed."
                    : "Previous arrangement requested; \(mismatches.count) native windows still differ. All Terminal sessions remain open."
                op.updated = Date().timeIntervalSince1970
                self.save(op)
                self.model.agentBusy = false
                self.model.status = op.detail
                if self.model.enabled { self.model.refresh(force: true) }
            }
        }
        verifyUndo(12)
    }
    func redo(_ request: AgentRequest) {
        guard active == nil, !model.agentBusy, model.acting, let id = request.operation,
            var op = load(root.appendingPathComponent("operations/\(id.uuidString).json")),
            model.displays.contains(where: { $0.id == op.displayID })
        else {
            reply(request.id, failure("An idle enabled target display and saved operation are required"))
            return
        }
        model.refresh(force: true)
        guard op.createdIDs.count == op.columns * op.rows,
            op.createdIDs.allSatisfy({ model.windows[$0]?.bundleID == "com.apple.Terminal" })
        else {
            reply(request.id, failure("Some original grid windows have closed; no replacements were opened"))
            return
        }
        guard let display = model.displays.first(where: { $0.id == op.displayID }), plannedGrid(op, on: display) != nil
        else {
            reply(request.id, failure("The grid no longer fits on its display; nothing was changed"))
            return
        }
        op.verified = 0
        op.phase = "verifying"
        active = op
        model.agentBusy = true
        save(op)
        reply(
            request.id,
            [
                "ok": true, "phase": "accepted", "operation": id.uuidString,
                "note": "Reusing existing windows; poll operation for verified results.",
            ])
        applyGrid()
    }
    func startTrace() {
        traceTimer?.invalidate()
        trace = []
        let start = Date()
        traceTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let screens = self.model.displays.map(\.fullFrame)
            let cg =
                (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                    as? [[String: Any]]) ?? []
            var overlaps: [[String: Any]] = []
            for (owner, d) in self.model.displays.enumerated() {
                for id in self.model.workspaces[d.id]?.windowIDs ?? [] {
                    guard let w = self.model.windows[id], let number = UInt32(id.split(separator: ":").last ?? ""),
                        let row = cg.first(where: {
                            ($0[kCGWindowNumber as String] as? UInt32) == number
                                && ($0[kCGWindowOwnerPID as String] as? Int32) == w.pid
                        }), let b = row[kCGWindowBounds as String] as? [String: Any],
                        let frame = CGRect(dictionaryRepresentation: b as CFDictionary)
                    else { continue }
                    for other in screens.indices where other != owner {
                        let i = frame.intersection(screens[other])
                        if !i.isNull, i.width > 0, i.height > 0 {
                            overlaps.append([
                                "window": id, "owner": d.id, "foreign": self.model.displays[other].id, "width": i.width,
                                "height": i.height,
                            ])
                        }
                    }
                }
            }
            self.trace.append([
                "time": Date().timeIntervalSince1970, "overlaps": overlaps,
                "offsets": self.model.displays.map {
                    ["display": $0.id, "offset": self.model.workspaces[$0.id]?.offset ?? 0] as [String: Any]
                },
            ])
            if Date().timeIntervalSince(start) >= 5 {
                timer.invalidate()
                self.traceTimer = nil
                if let data = try? JSONSerialization.data(withJSONObject: self.trace, options: [.sortedKeys]) {
                    try? data.write(
                        to: self.model.storage.appendingPathComponent("scroll-trace.json"), options: .atomic)
                }
            }
        }
        RunLoop.main.add(traceTimer!, forMode: .common)
    }
}
