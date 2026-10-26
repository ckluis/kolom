# Security

Kolom controls other apps' windows through the macOS Accessibility permission, and can temporarily change your display arrangement. Please report anything that lets another process, website or user abuse that.

## Reporting

Use [GitHub private vulnerability reporting](https://github.com/ckluis/kolom/security/advisories/new). Please do not open a public issue for a vulnerability.

## What Kolom does and does not do

- Moves and resizes windows with the public Accessibility API. Reads window lists; never captures screen contents.
- Asks for Automation (Apple Events) only to open Terminal windows for grids you request. It never sends shell command text.
- Has no telemetry and opens no network connections or listening sockets.
- Stores layout, recovery records and settings in `~/Library/Application Support/Kolom` (mode 0700).

## The local agent channel

`kolomctl` and its MCP server talk to Kolom through files in that folder. Read-only commands always work. Commands that move or create windows work only after you choose **Allow local agent commands…** in the menu bar icon's menu, and stop when you turn them off or quit. The session token only switches the channel on; it is not authentication, because any process running as your user can read it. Treat enabling agent commands as trusting every process in your user session. Requests are refused if they are FIFOs, symlinks, devices or oversized, and each one expires after 30 seconds.

## Ask Kolom

Ask Kolom (⌥K) takes a request you type and has Apple's on-device model (FoundationModels, macOS 26) turn it into one typed action. `resolveAsk` checks that action (sizes, a 60-window maximum, known commands only; unknown requests are explained, not run) and Kolom runs it in-process through its existing code. It performs typed actions only, never shell text, and starts no agent session or file-channel request, so it works without the local agent opt-in because it is your own request. Nothing leaves the Mac. Grids it creates are recorded in `agent/operations` like agent grids, so an agent session you have enabled could undo or redo them.
