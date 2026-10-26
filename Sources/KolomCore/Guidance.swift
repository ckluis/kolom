import Foundation

/// One registry supplies human help, machine help and MCP tool schemas.
/// Window titles and document contents never become instructions in this registry.
public enum KolomGuidance {
    public static let protocolVersion = "2025-11-25"
    public static let commands: [[String: Any]] = [
        [
            "name": "kolom_close_terminals", "requiresControl": true,
            "description":
                "Close all current Apple Terminal windows, including minimized windows, using native close buttons. Ends sessions if Terminal permits it; requires explicit user authorization and confirm: true. Does not force quit or dismiss process warnings. Returns observed closed/remaining counts. This cannot be undone.",
            "inputSchema": [
                "type": "object", "properties": ["confirm": ["type": "boolean", "const": true]],
                "required": ["confirm"], "additionalProperties": false,
            ],
        ],
        [
            "name": "kolom_help",
            "description":
                "Discover Kolom's current capabilities, limits, shortcuts and command examples. This does not grant window-control access.",
            "inputSchema": [
                "type": "object",
                "properties": ["topic": ["type": "string", "enum": ["overview", "layout", "voice", "privacy"]]],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "kolom_state",
            "description":
                "Read Kolom's local observed layout snapshot without window titles or content. Check timestamp and enabled before relying on it. No changes are made.",
            "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false],
        ],
        [
            "name": "kolom_plan_grid",
            "description":
                "Preview a named Terminal grid without changing windows. Checks cell sizes; inspect current display state before execution.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "columns": ["type": "integer", "minimum": 1, "maximum": 30],
                    "rows": ["type": "integer", "minimum": 1, "maximum": 30],
                    "display": ["type": "integer", "minimum": 1],
                ], "required": ["columns", "rows", "display"], "additionalProperties": false,
            ],
        ],
        [
            "name": "kolom_create_grid", "requiresControl": true,
            "description":
                "Create distinct Apple Terminal windows and arrange a named grid on a connected display. Requires native session opt-in. Returns an accepted operation; poll kolom_operation to learn whether actual geometry verified. Does not type or execute shell commands.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "columns": ["type": "integer", "minimum": 1, "maximum": 30],
                    "rows": ["type": "integer", "minimum": 1, "maximum": 30],
                    "display": ["type": "integer", "minimum": 1], "name": ["type": "string", "maxLength": 80],
                    "requestID": [
                        "type": "string",
                        "description":
                            "Reuse the same UUID if retrying an unacknowledged creation request; prevents duplicate windows.",
                    ],
                ], "required": ["columns", "rows", "display"], "additionalProperties": false,
            ],
        ],
        [
            "name": "kolom_operation",
            "description":
                "Read progress and verified result of a grid operation. Accepted or creating does not mean applied.",
            "inputSchema": [
                "type": "object", "properties": ["operation": ["type": "string"]], "required": ["operation"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "kolom_undo", "requiresControl": true,
            "description":
                "Undo this operation's grid only: its linked columns become ordinary single-window columns in place. Other columns, displays and later grids are untouched. Check undoAvailable in kolom_operation first; a partial undo can be retried. Never closes sessions or destroys their commands.",
            "inputSchema": [
                "type": "object", "properties": ["operation": ["type": "string"]], "required": ["operation"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "kolom_redo", "requiresControl": true,
            "description":
                "Reapply a saved grid using its still-open windows. Opens no replacements; poll operation for verified bounds.",
            "inputSchema": [
                "type": "object", "properties": ["operation": ["type": "string"]], "required": ["operation"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "kolom_cancel", "requiresControl": true,
            "description":
                "Stop further window creation in the active operation. Already-created windows remain open; check undoAvailable in kolom_operation.",
            "inputSchema": [
                "type": "object", "properties": ["operation": ["type": "string"]], "required": ["operation"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "kolom_navigate", "requiresControl": true,
            "description":
                "Animate a connected display to its desktop, next column, or previous column. Read state afterward to verify the resulting offset.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "display": ["type": "integer", "minimum": 1],
                    "action": ["type": "string", "enum": ["desktop", "next", "previous"]],
                ], "required": ["display", "action"], "additionalProperties": false,
            ],
        ],
        [
            "name": "kolom_trace_scroll", "requiresControl": true,
            "description":
                "Record numeric WindowServer overlap samples for five seconds while the user scrolls. Does not record screen pixels, keystrokes or text.",
            "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false],
        ],
    ]
    public static func help(_ topic: String = "overview") -> [String: Any] {
        let topics = ["overview", "layout", "voice", "privacy"]
        guard topics.contains(topic) else {
            return failure("Unknown help topic", hint: "Use overview, layout, voice, or privacy.")
        }
        var result: [String: Any] = [
            "topic": topic, "commands": commands.map { $0["name"]! }, "readOnly": true,
            "_help": "kolomctl help <topic> --json",
        ]
        switch topic {
        case "layout":
            result["rules"] = [
                "Each display owns an independent horizontal strip. While managing, Kolom keeps displays apart (corner to corner) so columns slide off any edge; the pointer still crosses as in the user's arrangement. state reports displayArrangement and isolateDisplays.",
                "Ordinary columns hold up to three windows; explicit grid groups allow more rows if 260×120-point cells fit.",
                "Grid members share a group identity; width and row-height changes are linked across its columns.",
                "Option+D scrolls to a 110% viewport-wide desktop destination.",
                "Native edge handoff parks windows beside their own display before a frame would overlap another display, or on its bottom edge when both sides have neighbours. It is not compositor clipping; if no edge is clear, Kolom pauses and restores windows.",
                "Create-grid currently supports Apple Terminal only. No shell commands are typed.",
            ]
            result["examples"] = [
                "kolomctl plan-grid --columns 6 --rows 3 --display 2",
                "kolomctl plan-grid --columns 6 --rows 5 --display 2",
            ]
        case "voice":
            result["workflow"] = [
                "Interpret speech into a structured intent.", "Inspect connected display IDs and current capabilities.",
                "Preview a validated plan, including app-specific new-window versus new-tab behavior.",
                "Apply only supported typed commands through the local agent channel, after the user chooses Allow local agent commands in Kolom's menu bar menu.",
                "Report actual observed results and allow undo.",
            ]
            result["notImplemented"] = [
                "Built-in speech recognition", "Launch adapters for apps other than Apple Terminal",
            ]
            result["inApp"] =
                "Ask Kolom (Option+K) interprets typed requests with Apple's on-device model inside the app (macOS 26 with Apple Intelligence). It is the user's own request, so it needs no Local Agent Commands opt-in, and it is not exposed through kolomctl."

        case "privacy":
            result["rules"] = [
                "MCP uses local stdio; commands reach Kolom through same-user file IPC in a private directory. No network port.",
                "Mutations require explicit native opt-in, expire when Kolom quits and accept only typed actions.",
                "The session token only switches the channel on. Any process running as the same user can read it, so it is not a boundary against such processes.",
                "Agent files must be small regular files; links, pipes and oversized files are refused. A request that times out is withdrawn and reported as not run.",
                "Snapshots omit window titles, file paths, document contents and keystrokes.",
                "Native window control remains inside the app's existing macOS permission.",
                "No arbitrary shell execution. Undo keeps created sessions open.",
            ]
        default:
            result["summary"] =
                "Kolom arranges real macOS windows into scrolling columns and named grids. People and LLM clients can create Terminal grids through explicitly enabled local commands, then inspect verified results and undo the arrangement."
            result["shortcuts"] = [
                "Option+Left/Right": "Navigate columns", "Option+1…9": "Focus window", "Option+D": "Show desktop",
                "Option+M": "Toggle Kolom commands", "Control+Option+K": "Arrange focused window",
                "Option+K": "Ask Kolom (typed requests, on-device model)",
            ]
            result["limits"] = [
                "maxOrdinaryWindowsPerColumn": 3, "maxWindowsPerGrid": 60, "agentMutationsAvailable": true,
                "agentControlRequiresOptIn": true, "voiceAvailable": false,
            ]
        }
        return result
    }
    public static func failure(_ message: String, hint: String) -> [String: Any] {
        ["ok": false, "error": message, "_hint": hint, "_help": "kolomctl help layout --json"]
    }
    public static func plan(
        columns: Int, rows: Int, display: Int, viewportWidth: Double? = nil, viewportHeight: Double? = nil
    ) -> [String: Any] {
        guard (1...30).contains(columns), (1...30).contains(rows), display > 0, columns * rows <= 60 else {
            return failure(
                "Invalid grid",
                hint: "Use positive dimensions with at most 60 windows. Columns and rows must each be at most 30.")
        }
        let supported = true
        var result: [String: Any] = [
            "ok": true, "kind": "preview", "displayIndex": display, "columns": columns, "rows": rows,
            "windowCount": columns * rows, "supportedByCurrentEngine": supported, "executable": false,
            "launchesWindows": false, "_help": "kolomctl help layout --json",
        ]
        if let w = viewportWidth, let h = viewportHeight, w.isFinite, h.isFinite, w > 0, h > 0 {
            let width = (w - Double(columns - 1) * 16) / Double(columns)
            let height = (h - Double(rows - 1) * 16) / Double(rows)
            result["cellWidth"] = max(0, width)
            result["cellHeight"] = max(0, height)
            result["fitsCurrentSizingLimits"] = width >= 260 && height >= 120
            result["note"] = "App-specific minimum sizes must also be checked against actual accepted native geometry."
        } else {
            result["note"] =
                "No live viewport supplied. Inspect kolomctl state before choosing sizes or treating display 2 as a persistent identity."
        }
        return result
    }
}
