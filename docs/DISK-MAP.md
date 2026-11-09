# Disk Map

A treemap of a disk or folder, in its own window, for finding what fills a disk
and (from 0.2.9) removing it. The bar is DiskTree's ([tobi/disktree](https://github.com/tobi/disktree),
MIT): it should be a joy to use. Kolom implements it natively (Swift, AppKit,
Core Graphics); it adopts DiskTree's ideas and its folder classification rules,
credited in THIRD-PARTY-NOTICES.md.

## Phases

| PR | Version | Scope |
|---|---|---|
| 1 | 0.2.8 | Window, parallel scan with live overview, squarified treemap coloured by kind, reclaimable hatch, selection, go in / up with animated zoom, breadcrumbs with sibling menus, keyboard, back/forward, side panel (selection, Worth a look, disk), Storage panel opens it |
| 2 | 0.2.9 | Marking (no double counting, marks absorb marks inside them), review screen, Move to Trash (default) and Delete permanently (asks), safety rules, rescan and space actually gained |
| 3 | 0.2.10 | Scroll-to-zoom-and-enter, Age and Files modes, filter `/`, choose any folder (⌘O), hidden and apparent-size toggles, depth `[` `]`, key help `?` |

## Scan

- A pool of worker threads (cores − 2, at least 2, utility QoS) takes directories
  from a shared depth-first stack; each lists one directory with `fstatat`
  (`AT_SYMLINK_NOFOLLOW`) and pushes its subdirectories. Each task writes only
  its own node; a final bottom-up pass totals sizes.
- Size is allocated bytes (`st_blocks × 512`); hard links count once.
- One disk: entries on another device are skipped. The startup disk is scanned
  from `/` without `/System/Volumes` (its data is reached through the
  firmlinks), `/Volumes`, `/dev`, `/net`, `/home`.
- Cloud-only (dataless) folders are not opened, so a scan never downloads.
- Kept: every folder, every file of 1 MB or more; smaller files are one
  "smaller files" entry per folder. A few names are noted per folder for
  classification (`Cargo.toml`, `package.json`, a bare git `HEAD`).
- While scanning, a live overview of the top-level folders (measured so far,
  not final) is drawn; the real treemap replaces it when the scan finishes.
- Stopping, closing the window or a new scan cancels; closing releases the tree.

## Kinds and reclaimable space

From names (DiskTree's rules): Code, Agent scratch, Toolchains, Synced, Git,
Media, Documents, Cache, Other. A folder's own name wins, otherwise it inherits;
an unknown top-level folder takes the kind of its largest recognisable child.
Reclaimable reasons (regenerable, build output, reinstallable, package store,
sync history, sandbox layers, snapshots, trash, temporary) are inherited
downward and drawn as a diagonal hatch, independent of colour. Amber is kept
for the selection, the main action and what can be had back.

## Screen

- **Top:** breadcrumbs from the scan root; each crumb's ▾ lists its siblings,
  largest first. Back / forward. Scan totals and the legend beneath.
- **Treemap:** squarified, nested (default 3 levels), top-level tiles with a
  name band. Hover highlights; click selects; double-click or Enter goes in;
  Backspace / Escape goes up; arrows move between tiles at a level; Tab is the
  next largest sibling; ⌘[ ⌘] back and forward; right-click reveals in Finder.
  Going in and up animates the tile to and from the full view.
- **Side panel:** the selection (size, share, files, kind, why it is
  reclaimable), *Worth a look* (the largest reclaimable folders), the disk's
  free space.
