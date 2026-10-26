# Kolom specification

**Updated:** 2026-10-26 · **Version:** 0.2.0 (alpha)

Kolom was called Ribbon before 0.2.0.

This is the current product specification and build-status checklist. It consolidates the conversation, implementation, and test reports. Older version notes describe history; they do not override decisions here. Update this file when scope, behavior, or verification changes.

## 1. Product

Kolom gives real Mac windows a predictable place in a horizontally scrolling workspace. Related windows can share a vertical column; deliberate grids support terminals and other repeated work. A slim rail provides navigation and a small resource readout. Local assistants can use a typed CLI/MCP interface to arrange supported layouts.

**Current state:** a working native alpha, not a finished window manager. Each display has its own strip; while managing, Kolom keeps displays apart (the display staircase) so columns slide off any edge instead of disappearing early. That still needs its hand test at the LG seam.

### Status meanings

- **Built / checked:** implemented with some live evidence. This does not mean every app, topology, or later build has been exhaustively tested.
- **Built / partial:** code exists; validation or important behavior is incomplete.
- **Experimental:** an opt-in investigation, not an accepted production solution.
- **Planned:** not implemented in the native app. Website demonstrations do not change this status.

## 2. Decisions to preserve

- Manage **actual native windows**, not simulated apps inside a Kolom window.
- Keep the native macOS menu bar and Dock. Preserve native titlebars and traffic-light buttons. The earlier idea of replacing them is not the current native direction.
- Use a slim **left rail** for the current native version. Show one entry per window, so separate browser windows remain distinct even when they belong to the same app.
- Put resource monitoring at the bottom of the rail. Keep Finder, Trash, account, Desktop, and settings shortcuts out of the rail; use the native Dock, menu bar, or keyboard instead.
- **Option D reveals the actual desktop by scrolling.** Do not bring back the fake Desktop app or Desktop file-list sidebar.
- Give **each display its own strip**. Keep normal mouse travel between monitors. (A shared strip across two displays and captured-edge previews were removed on 2026-10-26: the staircase solves edge disappearance without them; a window cannot span two displays.)
- Keep ordinary vertical stacks and deliberate grids distinct. A stack holds up to three windows; a requested grid may have more rows if its cells fit.
- Use supported macOS APIs and normal permissions. No SIP changes, injection, private WindowServer dependencies, or replacement compositor. Third-party window position and size change only through public Accessibility. If private APIs are ever used, they are limited to optional read-only metadata, are resolved dynamically, and always have a fully working public fallback (the rule Defi documents in its ADR 0001). Kolom currently uses none.
- Keep each display's strip independent and park windows at the display's own edges.
- Sleep, display sleep, screen lock and user switching **suspend** management: the layout and recovery records are kept, nothing moves or is restored, and Kolom resumes by itself. A **Space switch pauses and restores**; the user re-enables on the Space they want managed. Automatic resume was built and removed for the same reason as below: it had to infer which windows were on which Space. Suspending across Space switches (Defi's model) was built and reviewed on 2026-10-26 but not adopted. Accessibility only lists the current Space's windows, and four review rounds kept finding cases where inferring "on another Space" lost records, stuck a display, or adopted the wrong Space's windows. Revisit only with live tests on per-display Spaces. Displays coming up bring their own Spaces: Space changes during a display reconfiguration, and for 3 s after its last stage, are re-checked once the displays settle instead of being taken as the user's.
- Desktop theming is per Space but its records are per display: Kolom only themes the Space whose original wallpaper it recorded, and only ever restores a screen that is showing Kolom's own theme image, so a real wallpaper is never overwritten. A themed Space without its own record is restored to the display's last restored original (wallpaper-last.json), else the macOS default. Known limit: replacing the wallpaper of a Space while Kolom has it themed leaves a record that keeps theming off on that display until wallpaper-restore.json is removed.
- Do not silently minimize windows as the normal hiding strategy. Earlier minimization experiments were explicitly experimental and did not establish an acceptable default.
- Make pause, quit, permission failure, and interruption leave surviving windows usable. Never delete unresolved recovery records merely to make an error disappear.

## 3. What has been built

| Capability | Status | What exists and where the limits are |
| --- | --- | --- |
| Real native tiling | Built / checked | Swift/AppKit/SwiftUI app controls eligible windows through Accessibility. Standard resizable windows are adopted; full-screen windows and nonstandard dialogs are excluded. |
| Horizontal navigation | Built / partial | Horizontal gestures, rail focus, keyboard navigation, and animated reveal. Native off-screen parking works, but boundary transitions are not yet consistently polished. |
| Per-display left rails | Built / checked | Native app icons, separate window entries, numbered focus shortcuts, overlapping stack icons, and navigation arrows. Rails run with window management. |
| Vertical stacks | Built / partial | Up to three windows share one width. Height proportions and divider handles exist. App minimum sizes and three-way stacks still need broader live regression testing. |
| Drag arrangement | Built / partial | Rail icon insertion/stacking indicators, icon-to-icon stacking, and native titlebar movement detection. Needs a complete live pass for stacking, unstacking, reordering, and display transfer. |
| Width and height resizing | Built / checked | Column-edge dragging, stack dividers, command sliders, and Fill display. A live three-window Notes stack reached 1,740 points, then 1,800 by physical drag. Native app constraints still apply; the logical width safety bound is 10,000 points. |
| Keyboard placement | Built / checked | Searchable placement palette for before/after/above/below and display destinations. This is a Kolom placement interface, not a replacement for system Spotlight. |
| Optional command shelf | Built / checked | Option M toggles Kolom commands. Closing removes the shelf. It currently exposes Kolom actions, not a complete tree of the focused app's native menus. |
| Desktop reveal | Built / checked | Scroll beyond the strip or use Option D. The virtual desktop destination includes a 110% viewport-width buffer. This does not create physical clipping or an invisible parking monitor. |
| Appearance | Built / partial | Light, Dark, and Wallpaper modes. Light/Dark match the real desktop background to the rail; Wallpaper preserves the image and transparent rail. Original appearance is restored, including by the watchdog after a crash (0.1.24). Records are keyed by display UUID and never capture Kolom's own theme image. More contrast, wallpaper, and interruption checks remain. |
| Display placement | Built / partial | Move windows through the rail/context menu/palette; choose an app-launch destination. Reusing an existing app window is distinct from creating a new window. KVM and reconnect behavior needs more verification. |
| Disconnect history | Built / partial | Stable display identities and history for surviving windows; disconnected columns join the primary, except windows the user moved there from a still-connected display, which return to their former place on it. Reconnect should return them; closing windows or explicit moves update history. Live KVM tests exposed placement/history gaps, so this is not considered complete. |
| Launch and recovery | Built / partial | Launch/reopen starts management after access and recovery checks. Pause/Quit restore and verify reachability. On-disk recovery and a same-executable watchdog exist; on 2026-10-20 the watchdog restored 10 of 10 windows after a 0.1.23 crash. 0.1.24 adds an instance lock (one owner for the windows), a watchdog that yields to a relaunched Kolom and stops after ten minutes, and a quit that is never refused silently. Broad crash, permission-loss, sleep/wake, and helper tests remain. No login item is implemented. |
| Display staircase | Built / hand test pending | While managing, displays whose heights overlap are moved corner to corner; the pointer is routed across the real arrangement. Toggle: Keep displays apart While Managing. See section 4. |
| Terminal grids | Built / checked | Typed requests create distinct Apple Terminal windows in named, linked grids. A live 6×3 / 18-window creation was verified on an earlier alpha. Up to 60 cells are allowed if minimum planned sizes of 260×120 points fit; app constraints and current-build retesting still matter. |
| Local CLI/MCP | Built / checked | Capability help, state, grid planning/creation, operation polling, undo/redo/cancel, display navigation, tracing, and explicit close-all Terminal windows. Mutation requires session opt-in. Local stdio and same-user file IPC; no network listener or arbitrary shell-text execution. The session token only switches the channel on; any same-user process can read it, so it is not authentication. 0.1.24 refuses FIFOs/symlinks/oversized files, bounds-checks operation files, scopes undo to its own grid, and claims requests atomically. |
| Ask Kolom | Built / partial | ⌥K opens a bar; Apple's on-device model (FoundationModels, macOS 26 with Apple Intelligence) maps the sentence to one structured command, `resolveAsk` checks it, and Kolom runs it through its existing paths (Terminal grids use the agent grid code without an agent session or the local agent opt-in, and are recorded in `agent/operations`; undo keeps sessions open and only undoes grids Ask Kolom made this session). Results wait for grid verification; Escape cancels a pending request. Written sizes like "4x3" are read from the text, bare totals get a balanced grid, maximum 60 windows. Nothing leaves the Mac. Screens are numbered left to right on the desk. On macOS 13–15 or without Apple Intelligence the bar explains why it is unavailable; build-app.sh weak-links FoundationModels only when the SDK has it. Phrasing coverage needs live tuning. |
| Built-in guide | Built / checked | The ? in each rail toggles a guide beside the rail (sections Start, Ask, Moves, Displays, Agents, Help). Opens on first launch instead of the permission alert; also from the menu bar icon and Help → Kolom Guide. Shares Performance's place; one shows at a time. |
| Performance dashboard | Built / checked | System widgets above a sortable/filterable app/process table with live CPU, memory, app icons, expandable children, and sparklines. Tested with tiling paused and active; closing it preserves tiling and column widths. Remaining metrics are listed below. |
| Public website | Built / partial | GitHub Pages site in `site/` with an interactive multi-monitor playground. It is a demonstration, not the app; update it as native capabilities change. |

### Performance dashboard contract

- Entry point: the rail's bottom resource area, plus **Kolom → Performance**. It also has a read-only entry when tiling access is unavailable.
- One mini dashboard: a few widgets above **App / CPU / GPU / Memory / Network**. No collection of separate metric tabs.
- Default to grouped apps; expand to processes or switch to a flat process list. Sort CPU or memory highest-first, and filter the list.
- Available measurements: overall CPU, approximate overall used memory, physical-interface network throughput, and per-process CPU/physical memory footprint.
- Current CPU and memory cells have real-sample sparklines. GPU and per-process network cells show **unavailable**, not zero or invented charts.
- CPU is normalized across all cores: 100% means the whole Mac. Process CPU counters use hardware-timebase conversion. Shared memory can overlap between processes.
- Charts retain at most 60 samples at a two-second cadence. Missing readings remain gaps. Process details are sampled only while the dashboard is open.
- Group identifiable app-bundle helpers; leave shared services separate. Disclose protected/unreadable processes rather than suggesting the table accounts for every system resource.
- Closing Performance must leave the normal Kolom rail and management session running. **Quit Kolom** intentionally stops Kolom and restores windows.
- Active-session menu open/close was verified. Direct pointer activation of the rail's resource button still needs a recorded live check; it uses the same toggle with its display ID.

## 4. Displays

Each monitor owns its own columns, focus, and scroll offset. Apps must not leak into a neighbor's workspace. Without the staircase, native parking prevents leakage by moving a window away when it would intersect another display, which makes it disappear early at a shared edge.

**Adopted (2026-10-26): a temporary "display staircase".** Edge parking cannot meet the P0 below on side-by-side displays: a column that crosses the shared edge would show on the neighbor, so it had to be hidden early (the user saw this on the two LG displays). While Kolom manages windows, displays whose heights overlap are moved corner to corner with `CGConfigureDisplayOrigin` and `CGCompleteDisplayConfiguration(.forAppOnly)` (adapted from Defi, MIT; see [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md)). A pointer router on its own event-tap thread warps the pointer across the user's real arrangement (the desk), so crossings follow it. The desk returns on pause, quit and the "Keep displays apart while managing" toggle; macOS reverts it if Kolom crashes. Recovery records are in desk coordinates. A user arrangement made while Kolom runs becomes the desk. Costs: System Settings › Displays shows the staircase while managing, and unmanaged apps see the technical coordinates. Verified 2026-10-26: edge crossings on every desk edge (synthetic events), desk restored after quit and within 2 s of a forced kill, windows recovered. Still to verify by hand: scrolling feel at the LG seam, real pointer crossings, drags across displays, DisplayLink off/on and sleep/wake while applied.

### Removed (2026-10-26): shared secondary strip and captured edges

The shared strip combined two aligned secondary displays into one strip so a window could span their seam. It never passed on this Mac: with **Displays have separate Spaces** on, macOS clipped a seam-spanning window to one display, and turning it off needs a logout. Captured-edge previews faked partial windows at an edge with ScreenCaptureKit surfaces; live handoff was never reliable. The staircase solves edge disappearance with native windows, so both were removed to cut states and failure paths (about 600 lines). Cost: a window cannot span two displays. The code is in git history before the removal commit. The 0.1.21 report records the spanning test.

## 5. What needs to be finished next

| Priority | Work | Acceptance criteria |
| --- | --- | --- |
| P0 · next | Hand-test the display staircase | At the LG seam, slow/fast scrolling and reversal show columns sliding off the edge with no early disappearance and no leak onto the neighbor. Real pointer crossings and window drags between all three displays feel unchanged. DisplayLink off/on, sleep/wake, pause and quit leave the user's arrangement intact. |
| P0 | Prove window identity/order and display lifecycle stability | Parked live windows retain membership/order during discovery gaps. Repeat KVM disconnect/reconnect, mixed scaling, sleep/wake, and Space changes. Surviving windows return to their expected displays; closed windows do not reappear. The 0.1.22 retention fix exists but needs its final repeated live scroll test. 0.1.24 fixes a crash from duplicate window IDs and retains windows of busy/hung apps instead of re-appending them; both need live confirmation. |
| P0 | Finish recovery coverage | Pause, Quit, interrupted launch, forced exit, permission revocation, and watchdog failure leave windows reachable or retain explicit recovery records. Never declare recovery from an accepted move alone. |
| P0 | Stabilize installation and updates | Stable signing identity/install location and permission retention across upgrades. Ad-hoc rebuilds repeatedly invalidated access and left the rail disabled. Root cause confirmed: ad-hoc builds have a cdhash designated requirement. `scripts/make-signing-identity.sh` (run by `scripts/install.sh`) plus `scripts/build-app.sh` give a stable bundle-ID + certificate requirement for local builds. Developer ID signing and notarization for downloadable builds remain. |
| P1 | Complete native interaction regression | Three-window stacks, minimum-size apps, oversized columns, height/width drags, titlebar moves, icon drops, unstacking, browser windows with separate tabs, display launch/transfer, menus, sheets, and shortcut conflicts. No bouncing, overlap, silent layout loss, or accidental app closure. |
| P1 | Finish dashboard integration and metric coverage | Record rail-button open/close, Escape, reopen, themes, long lists, sorting children, display changes, and sampling stopping when closed. Investigate reliable GPU/per-process network attribution before enabling those metrics. No false readings, privileged helper added silently, or guessed browser ownership. |
| P1 | Bring help and documentation into agreement | CLI/MCP help must describe display handling and the already-built local execution channel accurately. Keep this spec, current README sections, website claims, and release status aligned. 0.1.24 source: CLI/MCP help, AGENT-INTERFACE.md and GUIDE.md now describe display handling, the existing local channel, scoped undo and stable signing. Website claims not yet reviewed. |
| P1 | Broaden typed layout control | Explicit focus/move/resize/transfer of existing windows and mixed layouts through stable identities; meaningful previews, observed completion, partial-failure reporting, and reversible transactions. Current CLI is not a general arbitrary-app layout executor. |
| P2 | Generalize grid adapters | Support deliberate repeated windows beyond Apple Terminal, including Notes where practical. Distinguish new windows from tabs; respect minimum sizes. Validate 30 terminals in 6×5 and mixed requests such as eight terminals plus a browser on monitor 2. |
| P2 | Add built-in natural-language/voice control | Toggleable microphone, transcription, local interpretation where suitable (Apple Foundation Models is a candidate), typed plans, ambiguity handling, and undo. Do not type arbitrary commands into terminals. Typed requests via Ask Kolom (Apple Foundation Models, macOS 26) exist today; microphone recording and transcription do not. |
| P2 | Update and verify the public demonstration | Show current Performance and the display staircase with accurate readiness labels. Keep the multi-monitor playground, mobile layout, and social previews working. |

**Reliability gate before a stable release:** repeatable physical-monitor tests with real apps, usable recovery, documented topology constraints, and no unresolved blocking geometry or permission/update failures.

## 6. Future concepts to keep, without calling them built

### V2: bottom rail that expands into a minimap

Keep the original left-rail design as V1. V2 explores a compact bottom icon strip that reveals a spatial minimap of columns and vertically grouped windows, including miniature window state.

Preserve these design choices from the exploration:

- App/window entries align left and remain usable with many windows; Finder/Trash sit at the right if included.
- Do not spend space on redundant Command K or Map buttons.
- Separate a compact default state from an expanded inspection mode. The compact rail should be unobtrusive; expanded height can be larger because it is temporary or pinned.
- Expand on hover; provide a discoverable pinned/unpinned toggle. Background clicks can pin, and the gap between apps and minimap can collapse it.
- Reserve visible room for the expanded map instead of covering the bottom of app windows.
- Show actual column order and vertical members; do not reduce the idea to oversized unrelated app icons.

**Status:** HTML design exploration only. No native minimap, live thumbnails, or pin/hover behavior is implemented.

### Vertically scrollable columns

Explore placing full-height apps below other full-height apps in one column. Distinguish scrolling app content from navigating the column, with clear focus and navigation semantics. This is different from today's proportional stacks that fit within one viewport. Resolve the interaction model before implementing it.

### Richer app-command exploration

Keep the native menu bar. Option M currently exposes Kolom commands; a searchable, shortcut-rich view of the focused application's own menu tree remains a possible extension. Do not silently turn the existing shelf into a floating menu or claim native app-menu extraction is implemented.

### Ideas (not planned)

A paired-phone view of a column, running over the user's own network (LAN or a VPN such as Tailscale), with no Kolom-hosted server.

## 7. Validation record and immediate handoff

**Last checked session:** Kolom 0.1.23 had window-control permission and management enabled on three displays. Performance was left collapsed. Captured edges and shared mode were off (both removed 2026-10-26). Recheck live state before acting; these are recorded observations, not a promise about the next session.

| Evidence | What it establishes |
| --- | --- |
| [0.1.24 hardening report](test-reports/0.1.24-hardening.md) | Two 0.1.23 crash reports and their cause, the wallpaper-record defect seen on this Mac, and what 0.1.24 changes. Unit checks only; no live test yet. |
| [Core checks](../Tests/KolomCoreTests/main.swift) | Geometry, stacks, grids, history, recovery planning, startup, shared membership, and resource-counter/history cases. These do not prove compositor behavior or universal app compatibility. |

## 8. Project, commands, and references

### Source of truth and entry points

| Location | Purpose |
| --- | --- |
| `docs/SPEC.md` | Current scope, decisions, status, and acceptance checklist (this file). |
| `site/` | GitHub Pages website source. |
| `Sources/KolomCore/` | Layout, grid, display history, startup/recovery geometry, guidance, display staircase, resource history. |
| `Sources/Kolom/` | Native window control, lifecycle, panels, input, performance sampling/dashboard. |
| `Sources/KolomCLI/` | Local CLI and MCP adapter. |
| `build/Kolom.app` | The built app. |
| `kolomctl` | Project-root CLI wrapper for the bundled executable. |

Useful commands from the project root:

```sh
./scripts/test.sh
./scripts/build-app.sh
./scripts/make-signing-identity.sh   # once; keeps permission across rebuilds
python3 -I scripts/live-check.py      # read-only health check of the running session
./kolomctl help
./kolomctl state
./kolomctl plan-grid --columns 6 --rows 3 --display 2
./kolomctl mcp
```

Grid planning is read-only. Grid creation, navigation, undo/redo/cancel, tracing, and closing terminals require native session opt-in where specified. An accepted operation is not an applied layout: poll its result. Undo preserves created Terminal sessions. `close-terminals --confirm` ends sessions and is not undoable; preserve native close warnings.

Builds must not overwrite a running bundle. The build script uses a candidate bundle when necessary. Verify restoration before replacing the active build. Never clear recovery data to bypass a failed restore.

Public site: [ckluis.github.io/kolom](https://ckluis.github.io/kolom/).

### Supporting documents

- [Technical guide](GUIDE.md): setup and implementation details.
- [Changelog](../CHANGELOG.md): chronological changes, not proof every feature passed live testing.
- [Agent interface](AGENT-INTERFACE.md): CLI/MCP behavior and authorization.
- [Implementation provenance](PROVENANCE.md): independently written source and dependency policy.
- [Earlier roadmap](ROADMAP.md): historical sequencing; current priorities are in this spec.

### Product references, not dependencies

The research set, which is also the credits list: [Paneru](https://github.com/karinushka/paneru), [niri](https://github.com/niri-wm/niri), [Hyprland](https://hypr.land/), [PaperWM](https://github.com/paperwm/PaperWM), [AeroSpace](https://nikitabobko.github.io/AeroSpace/), [yabai](https://github.com/asmvik/yabai), [Strip](https://enisbrik.github.io/strip/), [Trellis](https://trelliswm.app/), [ChainYourMac](https://chainyourmac.com/), [TileMyMac](https://tilemymac.app/), [Spear](https://spearui.com/), [Nehir](https://github.com/apphane-dev/nehir), [Shoji](https://shojimac.com/), [Panevisa](https://panevisa.com/), [OmniWM](https://omniwm.app/), [Beam](https://beam.win/), and [Astropad Workbench](https://astropad.com/product/workbench/), and [Defi](https://github.com/qeude/Defi) (MIT, Swift, niri-inspired; reviewed 2026-10-26 for its macOS-authoritative private-API policy, Space/session handling, pure layout core with desktop end-to-end tests and latency probes, and display-staircase isolation).

These are interaction/feasibility references, not affiliations or incorporated code. Do not assume a competitor's marketing proves its clipping strategy. Evaluate licenses before adopting any code or dependency. Defi's display staircase and pointer mapping (MIT) are adapted in KolomCore/DisplayArrangement.swift; no other competitor implementation is incorporated.
