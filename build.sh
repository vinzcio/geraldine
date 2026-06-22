#!/bin/bash
#
# Build Geraldine into a runnable .app bundle (no Xcode required).
#
#   ./build.sh                 # debug build + bundle + ad-hoc sign
#   ./build.sh run             # also launch it
#   ./build.sh release run     # optimized build, then launch
#   ./build.sh install         # copy the built app into /Applications
#
# Sources are staged to a local (non-iCloud/OneDrive) folder before building,
# because cloud sync can touch files mid-compile and break the build.
#
set -euo pipefail

APP_NAME="Geraldine"
BUNDLE_ID="com.vincent.geraldine"
VERSION="0.1.0"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HOME/Library/Caches/GeraldineBuild"
STAGE="$ROOT/src"
BUILD="$ROOT/build"

CONFIG="debug"
DO_RUN=0
DO_INSTALL=0
for a in "$@"; do
  case "$a" in
    release|debug) CONFIG="$a" ;;
    run)           DO_RUN=1 ;;
    install)       DO_INSTALL=1 ;;
    *) echo "Unknown argument: $a" >&2; exit 1 ;;
  esac
done

echo "▸ Staging sources → $STAGE"
mkdir -p "$STAGE"
rsync -a --delete \
  --exclude '.build' --exclude '.git' --exclude '.DS_Store' \
  "$SRC_DIR/Sources" "$STAGE/"
rsync -a "$SRC_DIR/Package.swift" "$STAGE/"
[ -d "$SRC_DIR/Resources" ] && rsync -a --delete "$SRC_DIR/Resources" "$STAGE/" || true

echo "▸ Compiling ($CONFIG)…"
swift build -c "$CONFIG" --scratch-path "$BUILD" --package-path "$STAGE"

BIN="$BUILD/$CONFIG/$APP_NAME"
APP="$ROOT/$APP_NAME.app"
CONTENTS="$APP/Contents"

echo "▸ Assembling $APP_NAME.app…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/$APP_NAME"

if [ -f "$SRC_DIR/Resources/AppIcon.icns" ]; then
  cp "$SRC_DIR/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
  ICON_KEY=""
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>geraldine</string>
            </array>
        </dict>
    </array>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    $ICON_KEY
    <key>NSDesktopFolderUsageDescription</key><string>Geraldine scans your Desktop to find large or old files you can clean up.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>Geraldine scans your Documents to find large or old files you can clean up.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>Geraldine scans your Downloads to find junk and old files you can clean up.</string>
    <key>NSRemovableVolumesUsageDescription</key><string>Geraldine can scan external volumes for files you can clean up.</string>
    <key>NSAppleEventsUsageDescription</key><string>Geraldine uses authorized commands to run system maintenance tasks you request.</string>
    <key>NSLocationUsageDescription</key><string>Geraldine uses your location only to read the name of the Wi-Fi network you're connected to. macOS requires this permission to reveal the network name.</string>
    <key>NSLocationWhenInUseUsageDescription</key><string>Geraldine uses your location only to read the name of the Wi-Fi network you're connected to. macOS requires this permission to reveal the network name.</string>
</dict>
</plist>
PLIST

# Sign with your Developer ID (override with CODESIGN_ID env var if needed).
# A stable identity means Full Disk Access & other permissions persist across rebuilds.
CODESIGN_ID="${CODESIGN_ID:-Developer ID Application: Lloyd Vincent Luardo (4S9BMP9GU3)}"
ENT="$SRC_DIR/Geraldine.entitlements"
sign_and_verify() {
  local app="$1"
  echo "▸ Signing $app as: $CODESIGN_ID"
  /usr/bin/xattr -cr "$app" 2>/dev/null || true
  codesign --force --options runtime ${ENT:+--entitlements "$ENT"} \
    --identifier "$BUNDLE_ID" --sign "$CODESIGN_ID" "$app"
  codesign --verify --verbose=1 "$app" || { echo "✗ signature verification failed"; exit 1; }
}

app_is_running() {
  local running
  running=$(/usr/bin/osascript -e "application id \"$BUNDLE_ID\" is running" 2>/dev/null || echo false)
  [ "$running" = "true" ]
}

quit_running_app() {
  if ! app_is_running; then
    return 0
  fi

  /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for attempt in {1..40}; do
    if ! app_is_running; then
      return 0
    fi
    sleep 0.25
  done

  echo "✗ $APP_NAME did not quit in time; not reopening over a running instance" >&2
  exit 1
}

sign_and_verify "$APP"
echo "✓ Built & signed: $APP"

if [ "$DO_INSTALL" -eq 1 ]; then
  if app_is_running; then
    echo "▸ Quitting running $APP_NAME before install…"
    quit_running_app
  fi
  echo "▸ Installing to /Applications…"
  # Keep the bundle root stable so macOS privacy grants are less likely to be
  # disturbed during local rebuilds.
  rsync -a --delete "$APP/" "/Applications/$APP_NAME.app/"
  APP="/Applications/$APP_NAME.app"
  sign_and_verify "$APP"
  echo "✓ Installed & signed: $APP"
fi

if [ "$DO_RUN" -eq 1 ]; then
  echo "▸ Relaunching…"
  quit_running_app
  open "$APP"
fi
