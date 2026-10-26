# Kolom technical guide

This is the technical guide: setup, behavior and implementation notes. Current scope and verification status are in [SPEC.md](SPEC.md). Versioned sections below preserve implementation history and may describe superseded behavior.

Kolom is a native AppKit / SwiftUI window manager for macOS. The website source is in `site/`.

## Set up

```sh
./scripts/install.sh
```

This builds Kolom from source, creates a local self-signed "Kolom Local Signing" identity (so Accessibility permission survives rebuilds), and installs the app to /Applications. Other scripts, run from the repository root:

```sh
./scripts/test.sh                      # dependency-free core checks
./scripts/build-app.sh                 # build build/Kolom.app only
python3 -I scripts/live-check.py       # read-only health check of a running session
```

## Run

`./scripts/install.sh` installs Kolom to /Applications (or ~/Applications if /Applications is not writable) and opens it; to run a fresh build instead, open `build/Kolom.app`. Kolom runs from its menu-bar icon and does not open a settings or demo window. On first launch it opens its built-in guide. The menu contains appearance, enable/pause, session restoration, display placement and permission setup. If access is already valid and there is no interrupted session to recover, management starts automatically.

To build again:

```sh
./scripts/build-app.sh
open build/Kolom.app
```

Requires macOS 13 or newer and Apple's Swift command-line tools. There are no third-party package dependencies. The produced binary targets the build machine's architecture. Builds are not notarized or signed for distribution. `./scripts/install.sh` runs `./scripts/make-signing-identity.sh` once to create the local "Kolom Local Signing" identity; `build-app.sh` then signs with it, and window-control permission survives rebuilds after one grant. Without it, builds are ad-hoc signed and each rebuild needs the permission granted again. Set `KOLOM_APP_DIR` to build somewhere other than the active bundle. Only one Kolom process (app or recovery watchdog) manages windows at a time; a second copy reports that Kolom is already running.

## Local CLI and LLM guidance

The bundled `Contents/MacOS/kolomctl` explains commands, reads observed layout snapshots, previews and creates Terminal grids, navigates displays, and closes current Apple Terminal windows when explicitly requested. `kolomctl mcp` exposes the same typed commands over local stdio without a listening network port. Mutations require session-only native opt-in (**Allow local agent commands…** in the menu-bar icon's menu). Use `kolomctl close-terminals --confirm` only when you intend to end all current Apple Terminal sessions; native busy-process warnings remain. It does not type shell commands or record speech, and the CLI does not interpret natural language; Ask Kolom in the app (below) uses the on-device model, not the CLI. See [the interface and grid design](AGENT-INTERFACE.md).

## Ask Kolom

Press Option K (global while Kolom manages windows) and type a request such as "3×2 terminals on screen 2". Apple's on-device model (FoundationModels; macOS 26 with Apple Intelligence) maps it to one structured command, `resolveAsk` in `Sources/KolomCore/AskIntent.swift` checks it, and Kolom runs it in-process through its existing code. Written sizes like "4x3" are read from the text, bare totals get a balanced grid, at most 60 windows are made, and unknown requests are explained, not run. Screens are numbered left to right on the desk. Results wait for the grid to be verified, and Escape cancels a pending request.

It runs without the local agent opt-in because it is your own request, and it does not use the file channel. Grids it creates are recorded like agent grids, so an enabled agent session could undo or redo them; Ask Kolom's "undo that grid" only undoes grids made this session by Ask Kolom. Nothing leaves the Mac. On macOS 13–15 or without Apple Intelligence the bar explains why it is unavailable.

## Built-in guide

The **?** button above the readings at the bottom of each rail toggles a guide beside the rail (sections Start, Ask, Moves, Displays, Agents, Help). It opens on first launch, from the menu-bar icon (**Kolom Guide…**) and from Help → Kolom Guide.

## Enable real window management

1. Open Kolom’s menu-bar menu.
2. Choose **Open window-control permission settings…**. Enable Kolom in **System Settings → Privacy & Security → Device Control and Data Access** (called **Accessibility** on older macOS versions).
3. Return to Kolom, click **Check window-control access**, then **Enable window management**.
4. Use **Pause and restore** or quit Kolom to restore the window positions recorded when management began.

Keep another tiling manager paused while trying Kolom. Native app menus and the system Dock stay in place. Kolom uses the screen's usable area below the menu bar and outside the native Dock. No screen-recording permission is needed.

If an older Kolom entry is already enabled but this copy reports no access, remove the old entry in that pane, use **+** to add the exact app shown under the current app bundle, and enable it. The **Reveal this Kolom app** menu item locates the correct bundle. Ad-hoc rebuilds change the signature, so an old enabled entry may no longer authorize the current build. Builds signed with the local identity keep their entry.

Kolom checks the system trust result and, when necessary, performs a read-only cross-application window-capability probe. Every real move still goes through the macOS permission-enforced Accessibility API. The Enable button remains clickable so it can report an access error rather than trapping you behind a grey button.

## Implemented

- Independent horizontal window strips and slim left rails on each connected display.
- One entry per standard, resizable window, including minimized windows restored into the strip. Multiple browser windows remain separate.
- Native app icons and numbered focus shortcuts. Option D animates the strip to uncover the real desktop; Finder and Trash remain in the native Dock.
- Shared-width vertical stacks of up to three windows.
- Drag an icon onto another to stack; its upper or lower edge inserts before or after. Drop indicators identify the destination.
- Drag native rail icons to arrange windows. Kolom also adopts real window edge resizing and title-bar movement after you release the mouse.
- Drag the column’s right-edge handle or resize a real window horizontally to update its entire column. The command shelf includes shared-width and stack-height sliders.
- A desktop destination spans 110% of the usable viewport. An experimental physical buffer is off by default: live tests showed macOS pulls several apps back onto another monitor, increasing the visible sliver from 6 to 40 points. This is not a clipping solution.
- Continuous horizontal scrolling; Option or Shift plus vertical scrolling also moves the strip. Ordinary vertical scrolling stays inside applications.
- Move windows between displays using the context menu or placement palette.
- Optional Kolom command sidebar. It contains Kolom's commands; original app menus stay native.
- Searchable placement palette with before / after / above / below destinations and keyboard selection.
- Native AX notifications plus periodic reconciliation for new, closed, focused and resized windows.
- App exclusions, pause / restore, and on-disk interrupted-session recovery.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| Option 1–9 | Focus a window on the display under the pointer |
| Option Left / Right | Previous / next column |
| Option D | Animate to the uncovered desktop |
| Option M | Toggle Kolom command sidebar |
| Option K | Ask Kolom |
| Control Option K | Open placement palette globally |
| Command K | Open placement palette while Kolom is active |
| Escape | Close placement palette |

Global shortcuts are registered only while management is enabled. Registration conflicts appear in Kolom's status message. The palette deliberately uses Control Option K globally so it does not steal Command K from other applications.

## Important alpha boundaries

This is the first native implementation, not a production-tested replacement desktop.

- macOS's public window API cannot clip other applications to a private scrolling viewport. Completely off-strip windows are moved to a small sliver at an outer desktop edge rather than minimized, avoiding hidden window bodies covering adjacent monitors. Partly visible windows keep native window boundaries; adjacent displays may expose overflow. No screenshot overlay or private WindowServer APIs are used.
- App-imposed minimum sizes can constrain stacking. Some applications decline AX moves / resizes; Kolom surfaces the failure rather than claiming it succeeded.
- The native window title bars and traffic-light controls remain. Kolom cannot remove another application's chrome through the public Accessibility API.
- A Space switch pauses and restores the session. Monitor disconnects move surviving columns to the primary display and reconnects return remembered windows. Full-screen windows, dialogs, nonresizable windows and hidden apps are excluded.
- Layouts persist for the same still-running windows using process / WindowServer IDs. Relaunched apps receive new window identities and are appended, not guessed from document titles.
- Recovery can restore still-existing windows in still-running apps. It cannot reopen closed documents. Recovery records are kept when an app declines restoration.
- Voice input and thumbnails are not included in this V1 alpha. Typed requests via Ask Kolom use Foundation Models on macOS 26.

## Validation

```sh
./scripts/test.sh
```

The dependency-free runner (`Tests/KolomCoreTests/main.swift`) prints one PASS line per group (25 groups): layout scenarios, stacks, parking, display memory, recovery geometry, grids, startup, display staircase and pointer crossings, resource counters, window identities, agent-file safety, and 36,000 seeded randomized layout steps that check every live window stays in exactly one workspace. It works with Apple's command-line tools without a full Xcode installation. `python3 -I scripts/test-guidance.py` exercises the installed CLI/MCP adapter and refuses to run while local agent commands are on (it sends requests that must be refused), and `python3 -I scripts/live-check.py` checks a running session's invariants without changing anything.

Native integration needs Accessibility permission and manual testing with real applications. Suggested checks: two Safari windows with distinct tab sets; Notes above Terminal; a shared-width resize; icon stacking / insertion; focus via rail and shortcuts; display transfer; closing a managed window; pause and quit restoration; interrupted-session recovery; Space / display-change pause. Do not interpret passing geometry checks as evidence that every application's AX implementation behaves identically.

## Source map

- `Sources/KolomCore/Workspace.swift`: pure layout, grouping and viewport model.
- `Sources/KolomCore/DisplayMemory.swift`: disconnected-display history and animation interpolation.
- `Sources/Kolom/Accessibility.swift`: public AX / WindowServer discovery and move / resize / focus operations.
- `Sources/Kolom/Controller.swift`: lifecycle, display ownership, persistence, reconciliation and restoration.
- `Sources/Kolom/Views.swift`: rail, optional command shelf, and settings.
- `Sources/Kolom/Palette.swift`: keyboard placement interface.
- `Sources/KolomCore/AskIntent.swift`: `resolveAsk`, the check between the model's structured command and execution.
- `Sources/Kolom/Hotkeys.swift`: Carbon hotkey registration and conflict handling.
- `Sources/Kolom/StripInput.swift`: scroll input and native column resize handles.
- `Sources/Kolom/main.swift`: app lifecycle, menu-bar item and display panels.

See [PROVENANCE.md](PROVENANCE.md) for implementation provenance. No Paneru source or dependencies are incorporated.

## Appearance

Choose Light, Dark or Wallpaper in Kolom settings. The rail, command shelf and settings use matching surfaces and explicit light/dark text contrast. Light and Dark replace the real desktop wallpaper with the matching solid color while Kolom manages windows. Original wallpapers and scaling options are saved before changes and restored on pause, quit, Wallpaper mode, or next launch after interruption. Wallpaper mode leaves the rail transparent over the real desktop.

Version 0.1.3 adds three-window stacking, proportional height adjustment and a divider handle for each gap. Applications still enforce their own minimum window heights.

## Desktop and multiple displays (0.1.4)

Scroll past the final column to uncover the desktop; Option Right at the final column also moves toward it. Option Left returns to the last column when fully uncovered. Window focus shortcuts reveal the chosen window again. Public macOS positioning may leave tiny window slivers at the display edge.

The rail now contains app entries and navigation arrows. Desktop files remain available with Option D and from Kolom’s menu-bar icon. Finder and Trash remain in the native Dock.

Use Kolom’s menu-bar icon → Move focused window to display, or the placement palette, to move the current window. Drag an icon onto an empty destination rail to transfer it. Real window title-bar transfers are recognized even when macOS also resizes the window on the destination display. Kolom remembers the last focused window when the pointer is over an empty display.

Use the menu-bar icon → Open app on display, or Open app… next to a display in settings, to choose an application. Existing applications may reuse an existing window; Kolom moves that window to the selected display. Newly discovered windows normally join the display under the pointer, unless an explicit launch destination was chosen. Initial adoption retains existing screen placement.

## Menu-only controls (0.1.5)

The floating Open Kolom/settings window and Desktop file browser are removed. Option D was unregistered in this release (it is registered again today and scrolls to the desktop). Access the real desktop by scrolling beyond the final window or with Option D. Appearance, enable/pause, session recovery, app launching, display moves and permission setup live in Kolom’s menu-bar menu. Command Comma opens that same menu when Kolom is active.

Cross-display edges are handled by the display staircase (see below); without it, off-strip windows are parked rather than minimized.  Paneru’s documentation also describes visible-sliver and adjacent-monitor limitations. No Paneru source was incorporated.

## Animated navigation and display memory (0.1.6)

Clicking a window icon animates the native strip to that window, then focuses it. Option D animates to the uncovered real desktop on the display under the pointer; it does not open a file browser. A new navigation command or manual scroll cancels the previous animation. Window widths and vertical groups remain unchanged during scrolling. Position-only animation frames avoid unnecessary native resize calls, and layout writes are debounced rather than saved every frame.

Unplugging a display appends its columns to the current primary display. A small persisted history records the disconnected display’s surviving window order, widths and stack weights. Reconnecting it returns those same still-open windows. Closing a window or quitting its app removes its history during reconciliation. Explicitly moving a window overrides its remembered home. Display identities use the macOS display UUID rather than temporary display numbers. The history does not reopen closed windows or relaunch apps.

These behaviours have geometry/history tests; native animation smoothness and physical DisplayLink reconnect behaviour still need live validation. Cross-screen clipping remains a separate unresolved rendering limitation.

## Window recovery (0.1.7)

Pause and Quit now restore windows to usable frames on currently connected displays, even if saved coordinates were already off-screen or a monitor has disappeared. Kolom verifies the actual Accessibility frame after the move, retries delayed moves, and retains failed recovery records. Normal Quit waits for verification and is cancelled if windows still need recovery.

Recover windows also scans for unreachable native windows when no old recovery file exists. Startup performs recovery first and stays paused if it detects a stranded session. Saved titles help match surviving windows when WindowServer identities change; ambiguous stale records trigger reachability rescue rather than guessing document positions.

While management runs, a second instance of the same signed executable watches the parent process. If the parent exits unexpectedly, that helper attempts recorded restoration using the same app’s existing Accessibility access. It does not request access itself. The helper’s live permission and crash-recovery path still need integration testing; no process can move other apps after its window-control access is revoked.

## Automatic startup (0.1.17)

Opening or reopening Kolom starts window management automatically once this build has window-control access. If an interrupted session or unreachable windows are detected, recovery runs first and management starts after verified recovery. Failed recovery stays paused with its records intact. Explicit Pause keeps the current session paused until you enable it or open Kolom again. No login-item registration is implied.

## Width and resource rail (0.1.20)

The command shelf width slider follows the assigned display’s usable width, instead of stopping at 1,200 points. Rail context menus include **Column width → Fill display**. Edge dragging changes the whole shared column (and linked grid columns) with a 10,000-point safety bound instead of the old 1,600-point cap. Native apps can still enforce their own size constraints.

The bottom rail shows CPU, MEM, NET, and GPU. CPU is system utilization across cores, sampled from Mach tick deltas. MEM is an approximation using active + wired + compressed physical pages, excluding inactive cached pages; it is not memory pressure or an exact Activity Monitor match. NET is received + sent bytes per second across active `en` interfaces, displayed as K/M decimal bytes per second. VPN/tunnel interfaces are excluded to avoid double-counting. All rails share one two-second utility-queue sampler. No telemetry is uploaded. Click for definitions. GPU is unavailable through the public APIs used here and is never fabricated.

## Display staircase (0.1.24)

Side-by-side displays share an edge, so a column scrolled past it would appear on the neighbor and had to be parked early: windows vanished before reaching the edge. While Kolom manages windows, displays whose heights overlap are moved corner to corner (adapted from [Defi](https://github.com/qeude/Defi), MIT; see [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md)). Columns slide off any edge without reaching another display. A pointer router on its own event-tap thread warps the pointer across your real arrangement, so crossings feel unchanged. The arrangement is applied with `.forAppOnly`: pause, quit and **Keep displays apart while managing** put it back, and macOS reverts it if Kolom crashes. Recovery records use your real arrangement's coordinates. While it is applied, System Settings › Displays shows the staircase; rearranging there makes the new arrangement yours.

## Removed in 0.1.24

The combined secondary strip (two aligned displays as one strip) and the ScreenCaptureKit captured-edge previews were removed on 2026-10-26. The strip needed **Displays have separate Spaces** off and a logout before macOS would draw a window across the seam, and never passed on the test Mac; edge handoff previews were never reliable. The display staircase replaces both. A window cannot span two displays.

## Performance sidebar (0.1.23)

Click the rail’s resource readings or choose **Kolom → Performance…**. The single dashboard has CPU, memory, network, and GPU widgets above **App / CPU / GPU / Memory / Network** rows. Click CPU or Memory to sort descending, filter by app/process, expand an app to its process children, or turn Group apps off. Escape or the header’s collapse button closes it. It reserves a 640-point shelf beside the rail while tiling runs, without changing saved column widths. It is also available with window management paused and does not require Accessibility access.

System sampling runs every two seconds. Process enumeration runs only while the dashboard is open. CPU uses `proc_pid_rusage` counters converted from absolute hardware ticks using Mach timebase, normalized so 100% means the whole Mac. Memory is each process’s physical footprint. Process identity includes start time to avoid PID reuse spikes; only known live process/app histories are retained. Sparklines hold at most 60 samples, missing readings remain gaps, and row charts scale independently for trends. App grouping uses main process identities and executable paths inside their identified app bundles; shared services remain separate. Physical footprints can overlap because of shared allocations. Protected or exited processes are counted as unavailable; the table is not guaranteed to account for all system utilization.

GPU utilization and per-process network throughput remain unavailable through the supported APIs currently used. Those cells show a dash rather than zero or fabricated history. The top network widget is measured aggregate traffic across active physical `en` interfaces. No packets or content are captured, no privileged helper is added, and no resource data is transmitted.
