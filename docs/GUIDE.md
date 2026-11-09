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

## Versions and updates (0.2.2; Update now 0.2.4)

Every build shows its version and commit in the menu bar menu (`Kolom · 0.2.2 (abc1234)`, `-dirty` when built with uncommitted changes); `VERSION` holds the release and every pull request raises it. Each version merged to `main` is published as a GitHub release with its changelog section as notes.

Once a day (first a minute after launch) Kolom asks `api.github.com` for the latest release. When it is newer, the menu bar icon gets a dot and the menu shows **Kolom x.y.z is available · What's new…**, **Update now…** and **Copy update command**. **Update now…** writes the update command to `~/Library/Application Support/Kolom/update.command` and opens it in Terminal, so you see it run; if it stops partway, it reopens the installed Kolom. **Copy update command** copies `cd <your checkout> && git pull --ff-only && ./scripts/install.sh --quit-running`. The installer quits Kolom as its Quit item does (windows are restored), builds, installs and opens the new copy. `kolom_state` reports the same under `update`. **Check for updates now** checks at once and answers in a dialog (with **Update Now** when there is one); **Check for updates automatically** turns the daily check off. Kolom never downloads or installs anything by itself.

## Width and resource rail (0.1.20)

The command shelf width slider follows the assigned display’s usable width, instead of stopping at 1,200 points. Rail context menus include **Column width → Fill display**. Edge dragging changes the whole shared column (and linked grid columns) with a 10,000-point safety bound instead of the old 1,600-point cap. Native apps can still enforce their own size constraints.

The bottom rail shows CPU, MEM, NET, and GPU. CPU is system utilization across cores, sampled from Mach tick deltas. MEM is an approximation using active + wired + compressed physical pages, excluding inactive cached pages; it is not memory pressure or an exact Activity Monitor match. NET is received + sent bytes per second across active `en` interfaces, displayed as K/M decimal bytes per second. VPN/tunnel interfaces are excluded to avoid double-counting. All rails share one two-second utility-queue sampler. No telemetry is uploaded. Click for definitions. GPU (since 0.2.3) is the busiest GPU's utilization as the IOKit registry reports it; a Mac that reports none shows a dash.

## Display staircase (0.1.24)

Side-by-side displays share an edge, so a column scrolled past it would appear on the neighbor and had to be parked early: windows vanished before reaching the edge. While Kolom manages windows, displays whose heights overlap are moved corner to corner (adapted from [Defi](https://github.com/qeude/Defi), MIT; see [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md)). Columns slide off any edge without reaching another display. A pointer router on its own event-tap thread warps the pointer across your real arrangement, so crossings feel unchanged. The arrangement is applied with `.forAppOnly`: pause, quit and **Keep displays apart while managing** put it back, and macOS reverts it if Kolom crashes. Recovery records use your real arrangement's coordinates. While it is applied, System Settings › Displays shows the staircase; rearranging there makes the new arrangement yours.

## Removed in 0.1.24

The combined secondary strip (two aligned displays as one strip) and the ScreenCaptureKit captured-edge previews were removed on 2026-10-26. The strip needed **Displays have separate Spaces** off and a logout before macOS would draw a window across the seam, and never passed on the test Mac; edge handoff previews were never reliable. The display staircase replaces both. A window cannot span two displays.

## Performance sidebar (0.1.23; grouping and GPU 0.2.3; network, stopping and smarter rows 0.2.6)

Click the rail’s resource readings or choose **Kolom → Performance…**. The single dashboard has CPU, GPU, memory, and network widgets above **App / CPU / GPU / Memory / Network** rows. Click a column to sort descending, filter by app, process, folder or PID, unfold rows, or turn **Group by app** off for a flat process list (each process still names its app).

Rows unfold in up to three levels:

- **Apps.** Every process sits under the app macOS holds responsible for it, the record Activity Monitor groups by. A terminal such as cmux owns its shells and everything they run; Safari owns its web content even though launchd starts it from WebKit.framework. Only real apps head rows: apps in the Dock, and menu bar apps that are not part of macOS. macOS also registers XPC services, widgets and its own agents as "apps" (AutoFill, Safari Networking, Wallpaper); they belong to whoever is responsible for them, which is checked first. Background services of macOS (system accounts, or executables in `/System`, `/usr/libexec`, `/usr/sbin`, `/sbin`, `/Library/Apple`) share one **macOS** row, except the usual reasons a Mac feels slow, which get rows of their own with a line on what they do: **WindowServer** (draws every display; DisplayLink and AirPlay screens add work here, not only in their own app), **Spotlight indexing**, **Time Machine** and **Photo & media analysis**. Widgets and app extensions (Quick Look thumbnails, System Settings search), which macOS keeps loaded even while their apps are closed, share **Widgets & extensions**, split into Widgets and Other extensions. Processes no app owns head their own row, with the workers responsible to them (a database and its workers).
- **Left running.** Inside an app, programs it started whose terminal session has since closed (now parented by launchd), such as a dev server left behind, are gathered under **Left running**.
- **Sessions.** Inside an app: its main process, then each process tree it started, named by the shell and the folder it runs in (`zsh · kolom`, `~/Desktop/projects/kolom · 8 processes · claude, node`); terminal `login` wrappers are skipped in the name. Single processes with the same name are gathered (**Web Content · 10 processes**).
- **Processes.** A session unfolds to its process tree, indented by parent, with PID and working directory.

Safari and other WebKit browsers keep tabs, frames and extensions in separate Web Content processes; macOS does not say which tab each one is, so they are counted together rather than labeled by guess. Tools installed as one executable per version (Claude Code's `…/claude/versions/2.1.316`) are named after the tool. Escape or the header’s collapse button closes it. It reserves a 640-point shelf beside the rail while tiling runs, without changing saved column widths. It is also available with window management paused and does not require Accessibility access.

System sampling runs every two seconds. Process enumeration runs only while the dashboard is open. CPU uses `proc_pid_rusage` counters converted from absolute hardware ticks using Mach timebase, normalized so 100% means the whole Mac. Memory is each process’s physical footprint. Process identity includes start time to avoid PID reuse spikes; only known live process/app histories are retained. Sparklines hold at most 60 samples, missing readings remain gaps, and row charts scale independently for trends. Ownership comes from macOS's responsibility record (`responsibility_get_pid_responsible_for_pid`, looked up at run time because it is not in a public header), then executables inside an app bundle, then the parent chain; without the record, the last two still group bundle helpers and child processes. Totals add what was measured, so a process that just started (no CPU reading yet) does not blank its app. Physical footprints can overlap because of shared allocations. Protected or exited processes are counted as unavailable; the table is not guaranteed to account for all system utilization.

GPU readings come from the IOKit registry, which publishes them to every user: the accelerator's **Device Utilization %** for the widget and rail, and each GPU client's accumulated GPU time for the rows, as a share of wall-clock time between samples. GPU engines run side by side, so app shares can add up past the widget. Macs whose GPU does not report per-app time (Intel, virtual machines) show dashes. Network per process comes from Apple's `nettop`, which reports byte counts (never contents) of every process with network activity to a normal user: while the dashboard is open, a one-second `nettop -P -d` run every two seconds measures traffic and exits (its output only arrives when it exits, and nothing is left running). Processes without network activity show 0. Processes of other users (WindowServer, root daemons) are closed to `proc_pid_rusage`; Kolom reads them through Apple's `ps`, also only while the dashboard is open: CPU is ps's recent average and memory resident size. The kernel (`kernel_task`, which also runs drivers such as USB and DisplayLink's) cannot be read without administrator access.

CPU is a share of the whole Mac. Activity Monitor shows a share of one core, so its numbers are the core count times Kolom's (a process at 2% of one core is 0.2% on a 10-core Mac); the CPU column's tooltip says so.

**Quitting and stopping.** Right-click a row. An app can be quit (as from its own menu; it may ask to save) or force quit, as in the Dock, Safari and Finder included. A session, a group, **Left running** or a single process can be stopped (SIGTERM, as closing its terminal would) or force stopped (SIGKILL); only your own processes outside macOS's folders are signalled, so a terminal's root-owned `login` wrapper is left to end with its shell. Every action is confirmed with the processes it will stop, and the result is reported (for example, an interactive shell may ignore SIGTERM; Force Stop ends it). macOS's processes and Kolom's own are never offered. **Copy PID** copies a row's PID.

The top network widget is measured aggregate traffic across active physical `en` interfaces. No packets or content are captured, no privileged helper is added, and no resource data is transmitted.

### Help panel and storage (0.2.7)

The notes that sat under the table now open from the **?** beside the Performance title, in a panel that slides over the dashboard (sections: Rows, Numbers, Quitting and stopping, Storage, Where the numbers come from). ×, a click outside or Escape closes it; Escape closes the dashboard only when the panel is shut.

The fifth panel, **Storage**, shows the startup disk's free space (as Finder counts it, purgeable space included) and how many more disks are mounted, read every ten seconds. Click it for the storage view, which pauses process sampling (`ps`, `nettop`) while it is shown:

- **Disks.** Every mounted disk with its kind (startup disk, internal, external and its connection, disk image, network), a usage bar, used and available space. The list follows mounts and ejects.
- **Disk Map (0.2.8).** Opening a disk, or **Choose a folder…**, opens the Disk Map window; see below.

### Disk Map (0.2.8)

A treemap of a disk or folder, adopting DiskTree's design and folder rules (MIT; see THIRD-PARTY-NOTICES.md). Since 0.2.9 it is a wide panel beside Performance, part of Kolom like Performance and the guide: the strip makes room for it (520–1200 points, leaving at least a column beside it), and it opens from the Storage list, **Choose a folder…**, or **Disk Map…** in the menu bar icon's menu and the Kolom menu (Performance opens with it). × or Escape at the top closes it; closing Performance closes both and frees the scan.

- **Scan.** Worker threads (cores − 2) list folders in parallel with `fstatat`: allocated sizes, hard links once, symlinks not followed, one disk, cloud-only (dataless) folders never opened. The startup disk is scanned from `/` without `/System/Volumes`, `/Volumes`, `/dev`, `/net` and `/home`. Files of 1 MB or more are their own tiles; smaller files are one entry per folder; folders under 1 MB keep their totals but not their contents. Measured on the test Mac: 2.37 million files in 17–39 s depending on load, about 110 MB while the window is open, released when it closes. While scanning, the top-level folders measured so far are drawn behind a progress card (files, folders, measured, unreadable, elapsed, current path); Escape or **Stop** cancels.
- **Map.** Squarified tiles, three levels nested, top-level folders with a name band and a strip of their kind's colour. Colour is the kind of data (code, agent scratch, toolchains, synced, git, media, documents, cache, apps, macOS), lighter with depth; a diagonal amber hatch is space that can be had back (regenerable caches, build output beside its manifest, reinstallable `node_modules` beside `package.json`, logs, trash, temporary), independent of colour. Amber also marks the selection.
- **Moving.** Click selects; double-click, Enter or **Open** goes in, the tile growing to fill the view; Backspace or Escape goes up, the view shrinking back into place. Arrows move between tiles at the selection's level, Tab to the next largest; ⌘[ ⌘] (and the arrows in the bar) go back and forward; ⌘R rescans; `o` or right-click reveals in Finder. Each breadcrumb's ▾ lists the folders beside it, largest first, with their share.
- **Panel.** The selection (size, share of its folder and of the scan, files, kind, last change, why it can be had back, path, Open and Reveal); **Worth a look**, the largest reclaimable folders anywhere in the scan (click one to go to it); the disk's free space and, on the startup disk, the space no folder accounts for.
- **Marking and removing (0.2.9).** Space or X marks the tile under the pointer (or the keyboard's selection after an arrow key); ⌘-click marks without moving the selection; right-click has Mark for Removal / Unmark. A marked tile and everything inside it turn red. Marking a folder absorbs marks inside it and nothing inside a marked folder can be marked on its own, so the space is never counted twice. The panel lists what is marked, its total and the free space after removing it; **Review…** (or C) lists every mark with its path, why it can be had back and anything worth knowing (synced folders disappear from other devices too, code may hold unpushed work, an app is uninstalled). **Move to Trash** is the default (recoverable until the Trash is emptied); **Delete Permanently…** asks again, naming what goes. Each path is checked just before removal (still there, not a symlink, not moved); the map updates at once and the line under it says how much free space came back (Trash keeps it until emptied).
- **Never removable:** the whole disk, the mapped folder itself, your home and everything above it, macOS (`/System`, `/usr`, `/bin`, `/sbin`, `/private/var/db`, `/private/etc`, `/Library/Apple`), top-level folders macOS expects (`/Applications`, `/Library`, `/Users`, `/opt`, …), and the folders macOS expects in a home (Library, Desktop, Documents, Downloads, Pictures, Movies, Music, Public, Application Support, Containers, Group Containers, Preferences, iCloud Drive, CloudStorage); their contents can be marked. Caches and Logs can go: apps recreate them.
