## 0.2.0 — 2026-10-26

- Renamed Ribbon → Kolom (bundle id `io.github.ckluis.kolom`; storage `~/Library/Application Support/Kolom`). Settings and layout migrate once from Ribbon, which must be quit first.
- Open-sourced under MIT.
- Repository restructured: Swift package at the root, website in `site/`, documentation in `docs/`.
- The CLI is `kolomctl` and the MCP server is `kolom`; tools renamed `ribbon_*` → `kolom_*`.
- Removed the commercial and remote-access plans.
- Ask Kolom (⌥K): type a request such as "3×2 terminals on screen 2"; Apple's on-device model (macOS 26, Apple Intelligence) turns it into one action, which is checked before it runs. Grids, desktop, columns, focus an app, move the focused window, theme, undo the last grid, pause, guide, performance. Screens are numbered left to right on the desk. FoundationModels is weak-linked, so older macOS still runs Kolom without it.
- Built-in guide: the ? button in each rail (above the readings) opens a setup and usage guide beside the rail, like Performance; it also opens on first launch and from the menu bar icon and Help → Kolom Guide. It shows live setup status and the MCP command to copy.
- Performance and the guide stay open through display changes that keep their display (the staircase reports one).
- `scripts/install.sh` builds, installs to /Applications and links `kolomctl`; it offers to register the MCP server with Claude Code for all projects (`--mcp` to do so without asking).
- Ask Kolom results now wait for the grid to be verified; Escape cancels a pending request; build-app.sh weak-links FoundationModels only when the SDK has it, so macOS 13–15 builds work.
- The website is a new interactive multi-monitor playground, deployed from `site/` to GitHub Pages.

## 0.1.24 (hardening; built and unit-checked, not yet live-tested)

- Fix the crash seen twice on 0.1.23 (Dictionary(uniqueKeysWithValues:) trap in refresh): discovery could give two windows the same ID. Retained windows now claim their IDs and WindowServer rows first; IDs are always unique.
- Keep windows of a busy or hung app in their columns instead of dropping and re-appending them; skip AX calls into such apps. Bound every AX call with a 0.5 s timeout.
- Park on the bottom edge when a display has neighbours on both sides, instead of pausing the whole session.
- Pause and restore from memory when the recovery record cannot be written.
- Single owner for the windows: an instance lock keeps a second copy, or a recovering watchdog, from fighting the running app. The watchdog yields to a relaunched Kolom, restores a themed wallpaper after a crash, and stops after ten minutes, leaving records for the next launch.
- Quit is never refused silently: logout, shutdown and missing permission always quit; otherwise the user chooses.
- A quit request that reaches the recovery watchdog (it shares Kolom's bundle identifier) is passed on to the app; before, it stopped the watchdog and Kolom kept running.
- Wallpaper records are keyed by display UUID, and Kolom's own theme image is never recorded as an original (it had been on 6 of 7 records on the development Mac).
- Clear stale drag state on pause; dismiss the palette on pause; remove force-unwraps in the height slider; tolerate NULL display UUIDs.
- Agent channel: refuse FIFOs, symlinks and oversized files; bounds-check operation files; scope undo to its own grid; plan redo before changing anything; claim requests atomically and withdraw timed-out ones; handle requests in creation order.
- Captured edges: drop pending handoff state for windows that close mid-handoff.
- Build: sign with a stable local identity when present (scripts/make-signing-identity.sh) so window-control permission survives rebuilds.
- Sources are formatted with swift-format (.swift-format).
- Sleep, display sleep, screen lock and user switching suspend management instead of pausing: the layout and records are kept, rails hide, nothing moves, and Kolom resumes afterwards. A Space switch still pauses and restores, now with the reason shown. A Space change that lands just after Kolom's own transfer or a display change is re-checked instead of ignored. While paused, windows whose records were dropped because they were on another Space are rescued when that Space is shown. Session suspension re-derives its state from the session dictionary, so a missed wake or unlock cannot leave it stuck. Windows missing from one discovery pass keep their column for 10 s, or for as long as they are in native full screen. (Ideas taken from Defi; see the spec's references.)
- Theme wallpapers: only the Space whose original was recorded is themed, and only screens showing Kolom's theme image are restored, so a Space switch can no longer write one Space's wallpaper onto another.
- Connecting displays no longer pauses Kolom. Displays (DisplayLink adapters especially) come up in stages, each with its own Space; every stage now extends the window in which Space changes are not taken as the user's, and the re-check waits until the displays settle. A Space switch by the user still pauses, about half a second later; until it is judged, shortcuts, strip scrolling, the palette and agent commands wait. A Space switch just before sleep or lock is judged on wake. Displays that keep changing for 15 s pause.
- A window moved to another display returns to its place on its former display when that display disconnects, instead of joining the end of the primary strip.
- Removed the extended secondary strip (Combine Aligned Secondary Displays) and the captured-edge experiment, about 600 lines and their pause, split and handoff paths. The display staircase solves edge disappearance with native windows; the shared strip needed separate Spaces off and a logout and never passed live. A window can no longer span two displays.
- Displays side by side no longer make columns disappear early at their shared edge. While Kolom manages windows, displays whose heights overlap are moved corner to corner (the display staircase, adapted from Defi, MIT); a column now slides off any edge without reaching a neighbor. A pointer router on its own thread warps the pointer across the user's real arrangement, so crossings feel unchanged. The arrangement is applied with `.forAppOnly` and returns on pause, quit, the Keep Displays Apart menu toggle, or a crash (macOS reverts it). Recovery records are kept in real-arrangement coordinates. live-check.py reports the arrangement and routed crossings.
- Saved windows keep their place and stacks when Kolom starts, is enabled or resumes after sleep or lock, even if the first passes miss them (seen after an update: the whole strip came back in discovery order, stacks split). A saved window of a running app is held for 15 s, or while its app does not answer; startup-hold.json records how many the first pass missed, and live-check.py reports it.
- Every pause is logged with its reason (pause-log.json, last 30) and live-check.py reports pauses from the last hour; a pause restores every window and hides the rails, which looks like a crash. Pause reasons from parking, captured edges and lost permission now survive into the final status.
- Crash recovery never swaps a record of a window on another Space for a different window of the same app; the watchdog keeps such records and retries on Space changes, with one pending retry and a one-hour cap.

## 0.1.23

- Replace the resource popover with a themed performance sidebar: four system widgets above a sortable app/process offenders table.
- Add live CPU and physical-memory footprint per readable process, grouping helpers inside identified app bundles, expandable children, filtering, and a flat process view.
- Add bounded two-minute real-sample sparklines. Preserve missing samples as gaps; handle PID reuse with process start identity. Convert libproc CPU hardware ticks using Mach timebase before normalizing across cores.
- Keep GPU and per-process network explicitly unavailable; retain measured system-wide network throughput. Show protected/unreadable process coverage.
- Poll process details only while the sidebar is open. Add a read-only Performance entry to the menu and access prompt; it works with tiling paused.

## 0.1.22

- Retain still-live, deliberately parked native windows through temporary AX discovery gaps so scrolling does not remove and reappend their columns.
- Trace against the full combined display rectangle; show an accurate Combine/Separate menu label.
- Expose the effective GUI-session Spaces flag in live state for diagnosis.
- Physical testing confirmed macOS clips seam-spanning windows with Displays have separate Spaces enabled. The setting must be tested off after a user-controlled logout/login; this is not a proven smooth-spanning release yet.

## 0.1.21

- Add session-only extended-strip mode for two aligned secondary displays; keep the primary independent.
- Merge secondary workspaces into one continuous native viewport with one left rail and no parking at their shared edge.
- Preserve physical window homes when separating, saving, quitting, or disconnecting displays. Newly created windows return to the left member.
- Add geometry checks for compatible displays, seam-spanning columns, primary independence, and splitting with new/closed windows.
- Live build starts successfully. Physical cross-seam rendering is pending while the two LG displays are disconnected.

## 0.1.20

- Remove the 1,200-point command-slider and 1,600-point drag limits. The slider follows the available display width; dragging supports larger logical columns, with a 10,000-point safety bound. Add a Fill display context action.
- Add compact CPU, memory, and aggregate physical-interface network readings at the bottom of each rail. One shared utility-queue sampler updates every two seconds. GPU is explicitly unavailable, not estimated.
- Retain native app titlebars and controls. Captured edges remains session-only and experimental; it has not passed live handoff validation.

## 0.1.19 (experimental)

- Replace the minimizing capture handoff with staged native parking behind an in-memory scene shield. Keep window ownership through discovery gaps and restore the pre-experiment layout on pause.
- The capture experiment remains unvalidated for production. Failure pauses and restores native windows.

## 0.1.18 (experimental)

- Added session-only captured-edge preview mode using public ScreenCaptureKit and bounded memory-only frames.
- Window surfaces clip to their owning display viewport, including negative coordinates and both shared edges.
- Temporarily minimize off-edge native windows; verify native position before restoring, and click a partial preview to reveal its real window.
- Existing native-only mode remains the default. Capture/handoff failure restores windows and pauses.

## 0.1.17

- Launch and reopen recover stranded windows first, then automatically enable management when recovery succeeds. Failed recovery stays paused.
- Added explicit close-all Apple Terminal windows through CLI/MCP with native process warnings preserved and observed closure counts.
- Consolidated source, website, and original designs under `projects/kolom`. The native app was in `native/` and the website at the root; both moved in 0.2.0.

# 0.1.16 — native agent grids and per-display boundary handling

- Add session-only opt-in local CLI/MCP window-layout control, with no shell command parameter or network listener.
- Create and verify distinct Terminal windows in named grids; link widths and row proportions, and expose progress, cancellation and non-destructive undo.
- Live creation verified 18 windows in a 6×3 grid on display 3. Desktop reveal on that display produced 94 sampled native frames with zero foreign-display overlap. Main-display animation traversed offsets 295–3467.6 with 95 samples and zero foreign-display overlaps.
- Keep parked windows beside their assigned display instead of using the vertical lane of a different monitor. This is native boundary handoff, not compositor clipping; unsupported parking topology pauses and restores.
- Add a visible recovery/access prompt, preserve pending records, and refuse builds that overwrite a running bundle.
- Live quit restored all 26 managed windows with zero pending records.
- Defer size growth until a staging move has been processed; live parked Terminal heights returned to full height. Keep logical size intent for parked new sessions and verify it upon reveal.
- Live width drag passed 640→760→640.
- Add explicit per-display local navigation and same-window grid redo; undo verification waits for native settling and distinguishes parked size intent from visible geometry.

# 0.1.15 — screen-edge resize live check passed

- Keep resize hit areas reachable at the viewport edge and retain a tracking handle until mouse-up when a drag carries the column past the edge.
- Boundary regression checks pass. Live Finder drag at the flush edge changed 640 to 652 with full height, delivered mouse-up past the viewport, and allowed subsequent navigation.
- Final normal quit restored all nine remaining windows with no pending recovery records. Cross-monitor peeking remains unresolved.

# 0.1.14 — live drag tests and display buffer findings

- Preserve resize views across updates; use mouse-event coordinates; commit the last drag delta once on release.
- Live two-window stack: exact +120/-120 shared-width drags and +80/-80 height-divider drags passed.
- Add WindowServer bounds to local diagnostics. Cross-display rendering reproduced at 6 pixels with ordinary parking.
- Add 110% virtual desktop destination. Physical buffered parking failed for several apps: macOS relocated them onto a foreign display by 40 pixels. The experiment remains off by default.
- Add local kolomctl help/state/grid previews and an on-demand read-only MCP stdio adapter, with shared definitions and validation. Voice, agent execution and first-class grid groups remain design work.
- Give app and CLI distinct executable names on case-insensitive macOS filesystems.

# 0.1.12 — live resize improvement, partial acceptance

- Allow native resizing to settle before correcting position, with cancellation when superseded by newer requests.
- Live Finder testing accepted 640-point width and eventually full requested height; a three-app shared-width stack also resized to its short height.
- Two live quit cycles restored all nine remaining windows with no pending recovery records.
- Drag resizing is still unverified; display peeking and the proposed desktop parking buffer remain unresolved.

# 0.1.11 — live geometry test failed

- Moving before growth when the current origin leaves insufficient room did not fix Finder's half-height behavior on either tested display.

# 0.1.10 — shared-width accommodation passed, height failed

- When a native app retains a width larger than requested after bounded retries, expand its entire shared column to that accepted width and shift following columns.
- Retrying full-height sizing with the expanded width still left Finder half height in the live test.
- Add regression checks for a 920-point native window in a 640-point stack and for widths beyond the normal 1600-point user resize limit.
- Cross-display clipping remains unresolved.

# 0.1.9 — live geometry test failed

- Treat unsolicited app size/position changes as observations, not user drag instructions.
- Retry a rejected geometry request only once after settling, then stop repeating it.
- Accept native move/resize gestures only after a tracked title-bar/border interaction.
- Avoid moving an already-local window both before and after resizing it.
- Add a bounded local geometry feedback log without document titles or contents.
- Regression checks cover 250 alternating half-height/top-bottom observations.
- This does not solve cross-display clipping or establish that launch-time bouncing is fixed.

# 0.1.8

- Place new windows on the active display and reveal/focus them.
- Live checks verified command sidebar, move palette, width slider and pause restoration of nine windows.
- Live new-Finder-window testing exposed unstable focus/placement; drag resizing and shortcut dispatch were not conclusively verified.

# 0.1.7

- Restore windows to usable connected-display bounds and verify actual positions before deleting recovery records.
- Retry delayed moves; wait for verified recovery before normal quit.
- Rescue unreachable windows even when an older version left no recovery file.
- Add a same-executable parent-exit recovery helper; live integration testing pending.
- Keep only the active distributable build and remove older release archives/backups.

# 0.1.6

- Animate icon focus and Option D to the uncovered desktop; keep real apps open and maintain their column sizes.
- Use position-only native writes during animation and debounce persistence.
- Move disconnected display columns to the primary display and restore surviving windows on reconnect using stable display UUIDs.
- Prune remembered positions for closed windows and override them on explicit transfers.
- Retain menu-only controls. Cross-display clipping is still unresolved and no minimization fallback was introduced.

# 0.1.5

- Remove the floating settings/demo window; move controls and permission setup to the menu-bar menu.
- Remove the Desktop file menu, Desktop folder access code, and Option D binding. Scrolling uncovers the actual desktop.
- Start management on launch only when permission is valid and no interrupted-session recovery is pending.
- Keep current native off-strip positioning while evaluating screen-isolation tradeoffs; no automatic minimization introduced.

# 0.1.4

- Light and Dark theme the real desktop to match the inset workspace, preserving original wallpaper settings for restoration. Wallpaper mode uses a clear rail.
- Scroll beyond the final column to uncover the real desktop.
- Remove rail utility buttons; expose Desktop and display actions through the menu bar and shortcuts.
- Add empty-rail display drop targets, explicit app launch destinations and persistent source selection when targeting an empty display.
- Recognize cross-display title-bar movement when the native window is also resized.

# 0.1.3

- Three windows can share a vertical column. Newly stacked windows receive an equal share relative to existing average height; manual resizing preserves the other members’ proportions.
- Every stack gap has a resize handle. Shared column widths remain synchronized.
- Desktop is a transient menu opened with Option D or the rail’s Desktop button. It takes no strip space and closes when clicking away.
- Desktop files are grouped by file type with compact native icons and filenames; click to open, or use the context menu to reveal in Finder.
- Light, Dark and Wallpaper appearance choices persist in settings. Rail and command text use matching contrast. Wallpaper uses the existing macOS background with a readability layer, without changing the system wallpaper.

Layout checks pass. Application-enforced minimum heights can limit three-way stacking. Live integration requires the current locally signed build’s Accessibility permission.
