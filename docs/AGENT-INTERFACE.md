# Kolom guidance, voice and layouts

This page covers the CLI/MCP channel. Natural language in the app is separate: Ask Kolom (Option K) uses Apple's on-device model in-process and does not go through `kolomctl`, the MCP server or the file channel (see [GUIDE.md](GUIDE.md#ask-kolom)).

The interface follows the contextual discovery idea in [Chris Kluis's /help article](https://medium.com/ckluis/your-swagger-endpoint-is-more-dangerous-than-help-ever-will-be-fa22cdb544bb): explain the capabilities the caller actually has, provide examples, and return recovery hints. `KolomGuidance` is the common source for CLI help, validation and MCP tool metadata. External app/window text is never used as instructions.

## Commands (introduced in 0.1.16; current as of 0.1.24)

The bundled `Kolom.app/Contents/MacOS/kolomctl` provides:

- `help [overview|layout|voice|privacy] --json` and `state` for contextual discovery and observed native geometry without document titles or contents.
- `plan-grid --columns 6 --rows 3 --display 3` validates a proposed grid without opening windows.
- `create-grid --columns 6 --rows 3 --display 3 --name "Build terminals"` creates distinct Apple Terminal windows, then verifies actual bounds. The response initially acknowledges an operation; poll `operation <UUID>` until `applied` or a reported failure. Retry uncertain requests with the same `--request-id <UUID>` to avoid duplicates.
- `undo <UUID>` undoes that operation's grid only: its linked columns become ordinary single-window columns in place, and other columns, displays and later grids are untouched. Check `undoAvailable` in `operation <UUID>` first; a partial undo can be retried. It never closes sessions. `cancel <UUID>` stops further creation and keeps any already created windows. `redo <UUID>` reapplies the grid using the same still-open Terminal windows; it opens no replacements and refuses up front, changing nothing, if the grid no longer fits.
- `navigate --display 1 --action desktop|next|previous` animates a specified display. Read state afterward to verify the offset.
- `trace-scroll` samples numeric WindowServer overlaps and strip offsets for five seconds. It records no pixels or keystrokes.
- `mcp` exposes the same typed operations over newline-delimited JSON-RPC stdio, with no network listener. Mutation tools appear only while native local control is enabled. No MCP client settings are installed automatically.

Local commands are explicitly enabled with **Allow local agent commands…** in the menu-bar icon's menu and expire when disabled or Kolom quits. The private same-user file channel uses a per-session token. Programs running as that user can request these documented operations; this is not a security boundary against another process already running as the same user. No command accepts shell text. Terminal's native Apple event creates new windows independently of tab preferences; macOS may request Automation consent.

Grid groups retain linked column widths and row proportions. Ordinary stacks remain limited to three windows; intentional grids support up to 60 cells, subject to a minimum planned cell size of 260×120 points and actual app size constraints. Closing or refusing a native window is reported, never substituted with a fake cell.

Live 18-window creation verified on display 3. Primary-display desktop navigation traversed offsets 295–3467.6 with 95 numeric WindowServer samples and zero foreign-display overlaps. A real primary-column drag verified 640→760→640. Parking uses a safe edge beside each display in its own vertical lane, with a native boundary handoff when a window would cross a foreign monitor. A display with neighbours on both sides parks on its bottom edge (0.1.24). This is not compositor clipping; if no edge is clear, Kolom pauses and restores instead of silently minimizing windows.

## Channel guarantees (0.1.24)

- Requests are handled in the order clients created them. Kolom claims each request by atomic rename before reading it. If `kolomctl` gets no answer within 5 s, it withdraws the request and reports that it was not run, so a retry cannot run it twice. If the withdrawal loses the race, the reply says to inspect the operation instead.
- `create-grid --wait` also waits when a retry with the same `--request-id` returns an operation that is still creating or verifying.
- Agent files must be small regular files. Symlinks, FIFOs, devices and oversized files are refused and removed. Operation files are bounds-checked and must match their file name, and only the newest 50 are kept.
- The session token switches the channel on; it does not authenticate. Any process running as the same user can read it.

## Route to voice control

1. Speech transcription produces text; an interpreter produces a typed intent.
2. The planner resolves display identities and app/window targets, validates geometry and shows a concrete preview. Ambiguity such as “6×5” means six columns and five rows in the explicit preview.
3. An opt-in native control channel applies the same operations as the UI. Its authority is limited to documented Kolom actions. It cannot run arbitrary terminal commands.
4. App adapters distinguish a new native window from a tab, wait for each created window, and report partial failures. Launching an app once is not equivalent to creating thirty windows.
5. Read back actual native bounds. Keep a reversible layout transaction and expose undo. Never report success based only on planned coordinates.

The CLI/MCP channel provides typed execution and layout undo. It does not record speech or interpret natural language itself; an external assistant can discover and execute its operations after opt-in. The in-app path is Ask Kolom (Option K): Apple's Foundation Models (macOS 26) map a typed request to one structured command, which `resolveAsk` checks before Kolom runs it in-process. Grids it creates are recorded in `agent/operations` like agent grids, so an enabled agent session could undo or redo them. Core geometry and app execution work without a model. Speech recording does not exist.

## Closing Terminal windows (0.1.17)

`kolomctl close-terminals --confirm` / MCP `kolom_close_terminals({"confirm":true})` closes all current Apple Terminal windows using their native close buttons, including minimized windows. Requires session-only local control and explicit user intent to end the sessions. Returns observed counts after verification; busy-process warnings stay visible and produce `needs_attention` rather than a false success. It never force-quits, sends shell text, dismisses warnings, or targets windows created after the request. Closing sessions cannot be undone; MCP marks this tool destructive.
