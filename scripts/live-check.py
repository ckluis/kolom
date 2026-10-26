#!/usr/bin/env python3
"""Read-only health check of a running Kolom session.

Samples `kolomctl state` and Kolom's files for a few seconds and reports
anything that breaks the invariants in docs/SPEC.md. It never moves windows,
sends agent commands, or changes settings, so it is safe to run at any time.

    python3 -I scripts/live-check.py [--seconds 3]

Exit status: 0 when every check passes (warnings allowed), 1 on a failure.
"""
import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
CTL = PROJECT / "kolomctl"
BUNDLE = PROJECT / "build/Kolom.app"
STORAGE = Path.home() / "Library/Application Support/Kolom"
REPORTS = Path.home() / "Library/Logs/DiagnosticReports"

results = []


def report(level, name, detail=""):
    results.append((level, name, detail))


def state():
    out = subprocess.run([str(CTL), "state"], capture_output=True, text=True, timeout=10)
    return json.loads(out.stdout)


def processes():
    out = subprocess.run(["/bin/ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    app, watchdogs = [], []
    for line in out.splitlines():
        pid, _, command = line.strip().partition(" ")
        if "/Kolom.app/Contents/MacOS/Kolom" not in command:
            continue
        (watchdogs if "--recovery-watchdog" in command else app).append(int(pid))
    return app, watchdogs


def bundle_version():
    try:
        out = subprocess.run(
            ["/usr/libexec/PlistBuddy", "-c", "Print CFBundleShortVersionString", str(BUNDLE / "Contents/Info.plist")],
            capture_output=True, text=True)
        return out.stdout.strip()
    except OSError:
        return "?"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=float, default=3.0, help="sampling window for transient overlaps")
    args = parser.parse_args()

    app, watchdogs = processes()
    if len(app) != 1:
        report("FAIL", "one Kolom process", f"found {len(app)}: {app}")
    else:
        report("ok", "one Kolom process", f"pid {app[0]}")

    samples = []
    deadline = time.time() + max(0.5, args.seconds)
    while time.time() < deadline:
        try:
            samples.append(state())
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            report("FAIL", "kolomctl state", str(error))
            break
        time.sleep(0.5)
    if not samples:
        return finish()
    last = samples[-1]

    expected = bundle_version()
    version = last.get("version")
    report("ok" if version == expected else "WARN", "running version matches the installed bundle",
           f"running {version}, bundle {expected}")
    if app and last.get("pid") != app[0]:
        report("WARN", "live state written by the running app",
               f"state pid {last.get('pid')} (an exited process or its watchdog wrote it)")
    if last.get("snapshotAgeSeconds", 99) > 5:
        report("WARN", "live state is fresh", f"{last.get('snapshotAgeSeconds', 0):.0f} s old; a modal dialog may be open")
    report("ok" if last.get("permissionGranted") else "FAIL", "window-control permission")

    enabled = last.get("enabled") is True
    report("ok" if enabled else "WARN", "window management enabled", last.get("status", ""))
    if enabled and last.get("suspended"):
        report("WARN", "managing this Space", f"suspended ({last['suspended']}); layout kept, resumes by itself")
    if enabled:
        report("ok" if len(watchdogs) == 1 else "FAIL", "one recovery watchdog while enabled",
               f"{len(watchdogs)} watchdog process(es)")

    # A pause restores every window and removes the rails, which looks like a crash.
    try:
        pauses = json.loads((STORAGE / "pause-log.json").read_text())
    except (OSError, ValueError):
        pauses = []
    recent = [p for p in pauses if time.time() - p.get("time", 0) < 3600]
    if recent:
        last = recent[-1]
        age = (time.time() - last["time"]) / 60
        report("WARN", "no pauses in the last hour",
               f"{len(recent)} pause(s); last {age:.0f} min ago: {last.get('reason', '?')}")
    else:
        report("ok", "no pauses in the last hour")

    # Displays whose heights overlap share an edge a column could cross; while
    # managing, Kolom moves them corner to corner (the display staircase).
    bounds = [d.get("bounds") for d in last.get("displays", []) if d.get("bounds")]
    overlapping = any(a[1] < b[1] + b[3] and b[1] < a[1] + a[3]
                      for i, a in enumerate(bounds) for b in bounds[i + 1:])
    arrangement = last.get("displayArrangement", "?")
    if enabled and not last.get("suspended") and last.get("isolateDisplays"):
        report("ok" if not overlapping else "FAIL", "displays kept apart while managing",
               f"{arrangement}; {last.get('pointerWarps', 0)} pointer crossing(s) routed")

    # Saved windows the first pass after enabling missed keep their place until found.
    try:
        hold = json.loads((STORAGE / "startup-hold.json").read_text())
        report("ok" if not hold.get("dropped") else "WARN", "saved windows kept their place at startup",
               f"first pass missed {hold.get('missed', 0)}, found {hold.get('found', 0)} later, "
               f"dropped {hold.get('dropped', 0)} ({hold.get('version', '?')})")
    except (OSError, ValueError):
        pass

    restore = STORAGE / "restore.json"
    if enabled:
        report("ok" if restore.exists() else "FAIL", "recovery records persisted while managing windows")
    else:
        report("ok" if not restore.exists() else "WARN", "no leftover recovery records while paused",
               "restore.json present: use Recover windows" if restore.exists() else "")

    # Window identity and placement, per sample.
    persistent = None
    for sample in samples:
        ids = []
        overlapping = set()
        for display in sample.get("displays", []):
            for column in display.get("columns", []):
                for window in column.get("windows", []):
                    ids.append(window["id"])
                    if window.get("foreignOverlaps") or window.get("renderedForeignOverlaps"):
                        overlapping.add(window["id"])
        duplicates = sorted({i for i in ids if ids.count(i) > 1})
        if duplicates:
            report("FAIL", "window IDs unique", f"duplicated: {duplicates}")
            break
        persistent = overlapping if persistent is None else persistent & overlapping
    else:
        report("ok", "window IDs unique", f"{len(ids)} managed windows")
    # Animations can overlap briefly; only overlap present in every sample counts.
    if persistent:
        report("FAIL", "no window covers another display", f"persistent overlap: {sorted(persistent)}")
    else:
        report("ok", "no window covers another display")

    wallpaper = STORAGE / "wallpaper-restore.json"
    if wallpaper.exists():
        try:
            records = json.loads(wallpaper.read_text())
            themed = [k for k, v in records.items() if str(STORAGE).replace(" ", "%20") in v.get("url", "")]
            report("FAIL" if themed else "ok", "wallpaper records hold real originals",
                   f"theme image recorded for {themed}" if themed else f"{len(records)} record(s)")
        except (OSError, ValueError) as error:
            report("FAIL", "wallpaper record readable", str(error))

    if BUNDLE.exists() and REPORTS.exists():
        installed = BUNDLE.stat().st_mtime
        crashes = sorted(p.name for p in REPORTS.glob("Kolom-*.ips") if p.stat().st_mtime > installed)
        report("FAIL" if crashes else "ok", "no crash reports since this build was installed", ", ".join(crashes))

    return finish()


def finish():
    width = max(len(name) for _, name, _ in results) if results else 0
    for level, name, detail in results:
        print(f"{level:4}  {name.ljust(width)}  {detail}".rstrip())
    return 1 if any(level == "FAIL" for level, _, _ in results) else 0


if __name__ == "__main__":
    sys.exit(main())
