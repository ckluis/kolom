import Foundation
import CoreFoundation
import Darwin
import KolomCore

let agentRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Kolom/agent")
func agentSession() -> AgentSession? {
    guard let data = readSmallRegularFile(agentRoot.appendingPathComponent("session.json"), limit: 4096),
        let session = try? JSONDecoder().decode(AgentSession.self, from: data), session.pid > 0,
        kill(session.pid, 0) == 0
    else { return nil }
    return session
}
func operationStatus(_ id: UUID) -> [String: Any] {
    guard
        let data = readSmallRegularFile(
            agentRoot.appendingPathComponent("operations/\(id.uuidString).json"), limit: agentOperationLimit),
        let op = try? JSONDecoder().decode(GridTransaction.self, from: data), op.isWellFormed(fileID: id)
    else { return KolomGuidance.failure("Unknown operation", hint: "Use the operation UUID returned by create-grid.") }
    return [
        "ok": !["failed", "partial", "undo_partial", "cancelled", "interrupted"].contains(op.phase),
        "operation": op.id.uuidString, "phase": op.phase, "detail": op.detail, "createdWindows": op.createdIDs.count,
        "requestedWindows": op.columns * op.rows, "verifiedWindows": op.verified, "displayID": op.displayID,
        "groupID": op.groupID?.uuidString ?? "", "undoAvailable": op.undoAvailable,
        "undoKeepsWindowsOpen": true,
    ]
}
func sendAgent(_ request: AgentRequest) -> [String: Any] {
    guard let session = agentSession(), session.token == request.session else {
        return KolomGuidance.failure(
            "Local agent commands are disabled",
            hint:
                "In Kolom's menu choose Allow local agent commands. This grants session-only, typed window-layout control."
        )
    }
    let destination = agentRoot.appendingPathComponent("requests/\(request.id.uuidString).json")
    let response = agentRoot.appendingPathComponent("responses/\(request.id.uuidString).json")
    try? FileManager.default.removeItem(at: response)
    do { try JSONEncoder().encode(request).write(to: destination, options: .atomic) } catch {
        return KolomGuidance.failure(
            "Could not send the local request", hint: "Check that Kolom is running under the same Mac user.")
    }
    let end = Date().addingTimeInterval(5)
    while Date() < end {
        if let data = readSmallRegularFile(response, limit: agentOperationLimit),
            let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        {
            try? FileManager.default.removeItem(at: response)
            return result
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    // Withdraw the request so a retry cannot run it a second time.
    if (try? FileManager.default.removeItem(at: destination)) != nil {
        return [
            "ok": false, "error": "Kolom did not pick up this request; it was withdrawn and was not run",
            "operation": request.id.uuidString, "_hint": "It is safe to retry.",
        ]
    }
    return [
        "ok": false, "error": "Kolom has not acknowledged this request", "operation": request.id.uuidString,
        "_hint":
            "Do not retry with a new ID: inspect operation status or retry with the same --request-id to avoid duplicate windows.",
    ]
}
func createGrid(_ args: [String: Any]) -> [String: Any] {
    guard Set(args.keys).isSubset(of: ["columns", "rows", "display", "name", "requestID"]),
        let c = integer(args["columns"]), let r = integer(args["rows"]), let index = integer(args["display"]), c > 0,
        r > 0, c <= 30, r <= 30, c * r <= 60, (args["name"] == nil || args["name"] is String),
        (args["name"] as? String ?? "").count <= 80
    else {
        return KolomGuidance.failure(
            "Invalid grid request",
            hint: "Supply positive integer columns, rows, display and an optional name. At most 60 new windows.")
    }
    let snapshot = state()
    guard snapshot["stale"] as? Bool == false, let displays = snapshot["displays"] as? [[String: Any]],
        let target = displays.first(where: { integer($0["index"]) == index }), let display = target["id"] as? String,
        let session = agentSession()
    else {
        return KolomGuidance.failure(
            "Kolom is paused, state is stale, the display is missing, or local control is disabled",
            hint: "Enable Kolom and Allow local agent commands in its menu; then inspect state.")
    }
    var id = UUID()
    if let raw = args["requestID"] {
        guard let text = raw as? String, let provided = UUID(uuidString: text) else {
            return KolomGuidance.failure("Invalid requestID", hint: "Supply a UUID when retrying a request.")
        }
        id = provided
    }
    return sendAgent(
        AgentRequest(
            id: id, session: session.token, action: "create-grid", columns: c, rows: r, displayID: display,
            name: args["name"] as? String ?? "Terminals"))
}
func agentAction(_ action: String, _ args: [String: Any]) -> [String: Any] {
    guard Set(args.keys) == ["operation"], let raw = args["operation"] as? String, let operation = UUID(uuidString: raw)
    else { return KolomGuidance.failure("Expected an operation UUID", hint: "Use the ID returned by create-grid.") }
    if action == "operation" { return operationStatus(operation) }
    guard let session = agentSession() else {
        return KolomGuidance.failure(
            "Local agent commands are disabled",
            hint: "Allow local agent commands in Kolom's menu before changing layouts.")
    }
    return sendAgent(AgentRequest(session: session.token, action: action, operation: operation))
}

func navigateDisplay(_ args: [String: Any]) -> [String: Any] {
    guard Set(args.keys) == ["display", "action"], let index = integer(args["display"]),
        let action = args["action"] as? String, ["desktop", "next", "previous"].contains(action)
    else {
        return KolomGuidance.failure(
            "Invalid navigation request", hint: "Supply display and action desktop, next, or previous.")
    }
    let snapshot = state()
    guard snapshot["stale"] as? Bool == false, let displays = snapshot["displays"] as? [[String: Any]],
        let display = displays.first(where: { integer($0["index"]) == index })?["id"] as? String,
        let session = agentSession()
    else {
        return KolomGuidance.failure(
            "Connected display and enabled local control required",
            hint: "Inspect state and enable local agent commands.")
    }
    return sendAgent(AgentRequest(session: session.token, action: "navigate", displayID: display, name: action))
}

func closeTerminals(_ args: [String: Any]) -> [String: Any] {
    guard Set(args.keys) == ["confirm"], let confirmation = args["confirm"] as? NSNumber,
        CFGetTypeID(confirmation) == CFBooleanGetTypeID(), confirmation.boolValue
    else {
        return KolomGuidance.failure(
            "Closing Terminal sessions requires confirm: true",
            hint:
                "Use close-terminals --confirm only when the user requests closing all Apple Terminal windows. Native busy-session warnings remain."
        )
    }
    guard let session = agentSession() else {
        return KolomGuidance.failure(
            "Local agent commands are disabled", hint: "Enable local agent commands in Kolom's menu.")
    }
    return sendAgent(AgentRequest(session: session.token, action: "close-terminals", name: "confirmed"))
}
