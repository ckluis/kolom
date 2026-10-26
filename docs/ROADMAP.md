# Kolom roadmap

For current priorities and feature status, use [SPEC.md](SPEC.md). This earlier sequencing plan is retained as historical context.

Updated October 18, 2026; paths revised for 0.2.0. This is a sequencing plan, not a release promise.

## Now — make native tiling dependable

Do not introduce network listeners, capture permissions, or cloud resources while tightening the tiling engine.

Priority order:

1. Finish the current build's live undo/redo verification using the existing Terminal windows. The final 0.1.16 bundle builds and offline checks pass; these final native changes have not yet passed live testing. Testing paused when the Mac locked.
2. Verify scrolling in both directions on every display, including physical trackpad input, rapid reversal, icon focus, and Option D. Check actual rendered boundaries during motion, not only final coordinates. Current evidence includes zero foreign bounds overlap in 95 primary-display samples and 94 display-3 samples; it does not prove every topology or shadow is correct.
3. Tighten shared-column width and stack-height dragging, app minimum-size handling, three-window stacks, and intentional grids. Confirm resize/focus/reconciliation cannot create bouncing, overlap, or duplicate windows.
4. Exercise display transfer, disconnect/reconnect history, sleep/wake, permission loss, and Space changes. Verify that pause, quit, interruption, and recovery leave every surviving window accessible.
5. Improve installation/update identity and diagnostics. Keep one current app bundle, preserve pending recovery records, and prevent a build from overwriting a running bundle.

Exit gate: repeatable native tests with real apps on a three-display setup; documented topology limits; usable restoration; no unresolved blocking geometry or recovery defects. Native boundary handoff must be described accurately, not called compositor clipping. No automatic minimization, SIP changes, injection, or unreviewed competitor code.

## Ideas (not planned)

A paired-phone view of a column, running over the user's own network (LAN or a VPN such as Tailscale), with no Kolom-hosted server.
