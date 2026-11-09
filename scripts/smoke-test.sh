#!/bin/zsh
# Opens the built Kolom.app in smoke mode: it drives Performance, the Disk Map and
# the guide, then quits on SIGTERM, without managing windows or touching Kolom's
# real storage. Safe to run beside a working copy of Kolom.
#
#   ./scripts/smoke-test.sh [--no-build] [output folder]
#
# Passes when every step passed and the app exited on its own within the limit.
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
BUILD=1
if [[ "${1:-}" == "--no-build" ]]; then BUILD=0; shift; fi
OUT="${1:-$PROJECT_DIR/build/smoke}"
LIMIT=150
APP="$PROJECT_DIR/build/Kolom-smoke.app"
(( BUILD )) && KOLOM_APP_DIR="$APP" ./scripts/build-app.sh >/dev/null
BINARY="$APP/Contents/MacOS/Kolom"
[[ -x "$BINARY" ]] || { print -u2 "smoke: no built app at $BINARY"; exit 1 }
rm -rf "$OUT"
mkdir -p "$OUT"
"$BINARY" --smoke-test "$OUT" > "$OUT/output.log" 2>&1 &
pid=$!
start=$SECONDS
while kill -0 $pid 2>/dev/null; do
  if (( SECONDS - start > LIMIT )); then
    kill -KILL $pid 2>/dev/null || true
    cat "$OUT/output.log"
    print -u2 "smoke: Kolom did not finish within ${LIMIT}s (killed)"
    exit 1
  fi
  sleep 0.5
done
code=0
wait $pid || code=$?
grep '^smoke:' "$OUT/output.log" || true
if [[ $code -ne 0 ]]; then
  print -u2 "smoke: Kolom exited with status $code"
  exit 1
fi
if ! /usr/bin/grep -q '"passed" : true' "$OUT/smoke-report.json" 2>/dev/null; then
  print -u2 "smoke: report missing or failed (see $OUT/smoke-report.json)"
  exit 1
fi
print "smoke: passed in $(( SECONDS - start ))s · report and renders in $OUT"
