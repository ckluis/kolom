#!/bin/zsh
# Build Kolom from source, install it to /Applications (or ~/Applications) and
# link kolomctl into ~/.local/bin. Safe to run again to update.
#
#   ./scripts/install.sh [--no-open] [--mcp]
#
# --mcp connects Kolom to Claude Code without asking (the installer asks
# when run in a terminal and Claude Code is installed).
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
fail() { print -u2 "install: $1"; exit 1 }
OPEN=1 MCP=0
for arg in "$@"; do
  case "$arg" in
    --no-open) OPEN=0 ;;
    --mcp) MCP=1 ;;
    *) fail "unknown option $arg" ;;
  esac
done

[[ "$(uname)" == Darwin ]] || fail "Kolom runs on macOS only."
(( $(sw_vers -productVersion | cut -d. -f1) >= 13 )) || fail "Kolom needs macOS 13 or later."
xcrun --find swift >/dev/null 2>&1 || fail "Swift is missing. Run: xcode-select --install"
# Replacing a running bundle would strand the windows it manages.
/usr/bin/pgrep -x Kolom >/dev/null &&
  fail "Kolom is running. Quit it from its menu bar icon (your windows are restored), then run this again."

# A stable local identity keeps the Accessibility permission across updates.
./scripts/make-signing-identity.sh
KOLOM_APP_DIR="$PROJECT_DIR/build/Kolom.app" ./scripts/build-app.sh

DEST=/Applications
[[ -w "$DEST" ]] || DEST="$HOME/Applications"
mkdir -p "$DEST" "$HOME/.local/bin"
rm -rf "$DEST/Kolom.app"
ditto "$PROJECT_DIR/build/Kolom.app" "$DEST/Kolom.app"
ln -sf "$DEST/Kolom.app/Contents/MacOS/kolomctl" "$HOME/.local/bin/kolomctl"

# Agents find Kolom through MCP; register it for every project, once.
if command -v claude >/dev/null 2>&1 && ! claude mcp get kolom >/dev/null 2>&1; then
  if (( ! MCP )) && [[ -t 0 ]]; then
    if read -q "?Connect Kolom to Claude Code (adds the kolom MCP server)? [y/N] "; then MCP=1; fi
    print
  fi
  if (( MCP )); then claude mcp add --scope user kolom -- "$HOME/.local/bin/kolomctl" mcp; fi
fi

print "
Installed $DEST/Kolom.app and ~/.local/bin/kolomctl.

Next: allow Kolom in System Settings → Privacy & Security → Accessibility.
Kolom starts managing windows as soon as it is allowed.

  ⌥← / ⌥→   previous / next column      ⌥1…⌥9   focus a window
  ⌥D        scroll to the desktop        ⌃⌥K     move the focused window
  ⌥M        Kolom commands               ⌥K      Ask Kolom (\"3×2 terminals on screen 2\")
  ?  in each rail opens the built-in guide
"
if (( OPEN )); then open "$DEST/Kolom.app"; fi
