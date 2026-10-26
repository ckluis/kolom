# Contributing to Kolom

Thanks for helping. Kolom moves people's real windows and displays, so reliability beats features: a change that can strand a window will not be merged, however nice it looks.

## Getting started

```sh
git clone https://github.com/ckluis/kolom.git && cd kolom
./scripts/make-signing-identity.sh   # once; keeps the Accessibility permission across rebuilds
./scripts/test.sh                    # core checks, no permissions needed
./scripts/build-app.sh               # build/Kolom.app
```

If Kolom is running, `build-app.sh` builds `build/Kolom-candidate.app` instead of replacing the running bundle. Quit Kolom from its menu (it restores every window) before swapping builds.

## Where things live

- `Sources/KolomCore`: pure layout, grid, display, recovery and staircase logic. No AppKit; everything here should have a check in `Tests/KolomCoreTests`.
- `Sources/Kolom`: the app: Accessibility, input, rails, panels, display configuration.
- `Sources/KolomCLI`: `kolomctl` and the MCP server.
- `docs/SPEC.md`: decisions and the honest status of every feature. Update it when behaviour changes.
- `site/`: the website and playground (static, served by GitHub Pages).

## Pull requests

- Keep each PR to one change, with a check in `Tests/KolomCoreTests` when the logic is testable.
- Run `./scripts/test.sh`, and for behaviour you changed, a live session with `python3 -I scripts/live-check.py` before and after.
- Format Swift with `swift-format` using `.swift-format`.
- Describe what you tested by hand (displays, apps, macOS version).

## Rules the code keeps

- Public APIs and normal permissions only: no SIP changes, injection or private WindowServer APIs.
- Pause, quit, crash and permission loss must leave every window reachable. Never delete recovery records just to clear an error.
- No telemetry and no network listeners.
