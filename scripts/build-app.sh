#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
source "$PROJECT_DIR/scripts/module-cache.sh"
BUILD_ARGS=(--disable-sandbox --cache-path "$PROJECT_DIR/.build/package-cache" --config-path "$PROJECT_DIR/.build/package-config" --security-path "$PROJECT_DIR/.build/package-security")
# Ask Kolom uses Apple's on-device model when the SDK has it (macOS 26). Weak
# linking lets the same app launch on older macOS; older SDKs build without it.
LINK_ARGS=()
if [[ -d "$(xcrun --show-sdk-path)/System/Library/Frameworks/FoundationModels.framework" ]]; then
  LINK_ARGS=(-Xlinker -weak_framework -Xlinker FoundationModels)
fi
swift build -c release --product Kolom "${BUILD_ARGS[@]}" "${LINK_ARGS[@]}"
swift build -c release --product kolomctl "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build -c release --show-bin-path "${BUILD_ARGS[@]}")"
APP_DIR="${KOLOM_APP_DIR:-$PROJECT_DIR/build/Kolom.app}"
if [[ -z "${KOLOM_APP_DIR:-}" ]] && /usr/bin/pgrep -x Kolom >/dev/null; then
  APP_DIR="$PROJECT_DIR/build/Kolom-candidate.app"
  print "Kolom is running; preserving its bundle and building $APP_DIR instead."
fi
if /usr/bin/pgrep -f "^${APP_DIR}/Contents/MacOS/Kolom( |$)" >/dev/null; then
  print -u2 "Refusing to overwrite a running Kolom bundle: $APP_DIR. Quit it and verify recovery first."
  exit 1
fi
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/Kolom" "$APP_DIR/Contents/MacOS/Kolom"
cp "$BIN_DIR/kolomctl" "$APP_DIR/Contents/MacOS/kolomctl"
# A stable identity keeps window-control permission across rebuilds; ad-hoc
# signatures are identified by cdhash and lose it. See make-signing-identity.sh.
SIGN_IDENTITY="${KOLOM_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]] && security find-identity -p codesigning 2>/dev/null | grep -q '"Kolom Local Signing"'; then
  SIGN_IDENTITY="Kolom Local Signing"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
[[ "$SIGN_IDENTITY" == "-" ]] && print "Signing ad hoc: window-control permission must be granted again after this build."
codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR/Contents/MacOS/kolomctl"
# VERSION is the release; the commit count and hash tell every build apart.
VERSION="$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { print -u2 "VERSION must be x.y.z, not '$VERSION'"; exit 1 }
BUILD_NUMBER=0 COMMIT=""
if git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  # Continues from 26, the last hand-set build: LaunchServices prefers the highest
  # build among copies of the app, so numbers must never go back below it.
  BUILD_NUMBER="$(( $(git -C "$PROJECT_DIR" rev-list --count HEAD) + 26 ))"
  COMMIT="$(git -C "$PROJECT_DIR" rev-parse --short HEAD)"
  if [[ -n "$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=no)" ]]; then COMMIT="$COMMIT-dirty"; fi
fi
COMMIT_KEY=""
if [[ -n "$COMMIT" ]]; then COMMIT_KEY="<key>KolomCommit</key><string>$COMMIT</string>"; fi
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Kolom</string>
<key>CFBundleIdentifier</key><string>io.github.ckluis.kolom</string>
<key>CFBundleName</key><string>Kolom</string>
<key>CFBundleDisplayName</key><string>Kolom</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>Kolom</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
$COMMIT_KEY
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Kolom creates separate Terminal windows for the terminal grids you request. It does not send shell command text.</string>
</dict></plist>
PLIST
swift "$PROJECT_DIR/scripts/make-icon.swift" "$PROJECT_DIR/build/Kolom.iconset"
iconutil -c icns "$PROJECT_DIR/build/Kolom.iconset" -o "$APP_DIR/Contents/Resources/Kolom.icns"
codesign --force --sign "$SIGN_IDENTITY" --identifier io.github.ckluis.kolom "$APP_DIR"
print "Built $APP_DIR · Kolom $VERSION (build $BUILD_NUMBER${COMMIT:+, $COMMIT})"
