#!/bin/bash
#
# Build Geraldine into a runnable .app bundle (no Xcode required).
#
#   ./build.sh                 # debug build + bundle + Developer ID sign
#   ./build.sh run             # also launch it
#   ./build.sh release run     # optimized build, then launch
#   ./build.sh install         # copy the built app into /Applications
#   ./build.sh release install notarize run
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
DO_NOTARIZE=0
for a in "$@"; do
  case "$a" in
    release|debug) CONFIG="$a" ;;
    run)           DO_RUN=1 ;;
    install)       DO_INSTALL=1 ;;
    notarize)      DO_NOTARIZE=1 ;;
    *) echo "Unknown argument: $a" >&2; exit 1 ;;
  esac
done

GIT_COMMIT="unknown"
GIT_COMMIT_SHORT="unknown"
GIT_DIRTY="unknown"
BUILD_DATE="$(/bin/date -u +"%Y-%m-%dT%H:%M:%SZ")"
if /usr/bin/git -C "$SRC_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GIT_COMMIT="$(/usr/bin/git -C "$SRC_DIR" rev-parse HEAD)"
  GIT_COMMIT_SHORT="$(/usr/bin/git -C "$SRC_DIR" rev-parse --short=12 HEAD)"
  if [ -n "$(/usr/bin/git -C "$SRC_DIR" status --porcelain --untracked-files=normal)" ]; then
    GIT_DIRTY="true"
  else
    GIT_DIRTY="false"
  fi
fi
if [ "$GIT_DIRTY" = "true" ]; then
  GIT_DIRTY_PLIST="<true/>"
  GIT_DIRTY_SUFFIX="-dirty"
elif [ "$GIT_DIRTY" = "false" ]; then
  GIT_DIRTY_PLIST="<false/>"
  GIT_DIRTY_SUFFIX=""
else
  GIT_DIRTY_PLIST="<false/>"
  GIT_DIRTY_SUFFIX="-unknown"
fi

echo "▸ Source revision: $GIT_COMMIT_SHORT$GIT_DIRTY_SUFFIX"

echo "▸ Staging sources → $STAGE"
mkdir -p "$STAGE"
rsync -a --delete \
  --exclude '.build' --exclude '.git' --exclude '.DS_Store' \
  "$SRC_DIR/Sources" "$STAGE/"
rsync -a "$SRC_DIR/Package.swift" "$STAGE/"
[ -d "$SRC_DIR/Tests" ] && rsync -a --delete "$SRC_DIR/Tests" "$STAGE/" || true
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

sanitize_app_executable_rpaths() {
  local executable="$1"
  local rpath
  local rpaths=()

  while IFS= read -r rpath; do
    rpaths+=("$rpath")
  done < <(
    otool -l "$executable" \
      | awk '/cmd LC_RPATH/{in_rpath=1; next} in_rpath && $1 == "path" {print $2; in_rpath=0}'
  )

  for rpath in "${rpaths[@]}"; do
    case "$rpath" in
      /usr/lib/swift|@loader_path*|@executable_path*)
        ;;
      /*)
        echo "▸ Removing external app rpath from $APP_NAME: $rpath"
        install_name_tool -delete_rpath "$rpath" "$executable"
        ;;
    esac
  done
}

sanitize_app_executable_rpaths "$CONTENTS/MacOS/$APP_NAME"

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
    <key>GeraldineBuildCommit</key><string>$GIT_COMMIT</string>
    <key>GeraldineBuildCommitShort</key><string>$GIT_COMMIT_SHORT</string>
    <key>GeraldineBuildDirty</key>$GIT_DIRTY_PLIST
    <key>GeraldineBuildDate</key><string>$BUILD_DATE</string>
    <key>GeraldineBuildConfiguration</key><string>$CONFIG</string>
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
NOTARY_PROFILE="${NOTARY_PROFILE:-harken-notary}"
ENT="$SRC_DIR/Geraldine.entitlements"
sign_and_verify() {
  local app="$1"
  local -a sign_args=(--force --options runtime)
  if [ -f "$ENT" ]; then
    sign_args+=(--entitlements "$ENT")
  fi

  # Older/ad-hoc signing passes can leave a legacy resource seal here. Modern
  # app bundles should only carry Contents/_CodeSignature/CodeResources.
  /bin/rm -f "$app/Contents/CodeResources" 2>/dev/null || true

  echo "▸ Signing $app as: $CODESIGN_ID"
  /usr/bin/xattr -cr "$app" 2>/dev/null || true
  codesign "${sign_args[@]}" --identifier "$BUNDLE_ID" --sign "$CODESIGN_ID" "$app"
  codesign --verify --verbose=1 "$app" || { echo "✗ signature verification failed"; exit 1; }
}

verify_bundle_provenance() {
  local app="$1"
  local plist="$app/Contents/Info.plist"
  local actual_commit actual_dirty actual_config actual_date

  actual_commit="$(/usr/libexec/PlistBuddy -c 'Print :GeraldineBuildCommit' "$plist" 2>/dev/null || true)"
  actual_dirty="$(/usr/libexec/PlistBuddy -c 'Print :GeraldineBuildDirty' "$plist" 2>/dev/null || true)"
  actual_config="$(/usr/libexec/PlistBuddy -c 'Print :GeraldineBuildConfiguration' "$plist" 2>/dev/null || true)"
  actual_date="$(/usr/libexec/PlistBuddy -c 'Print :GeraldineBuildDate' "$plist" 2>/dev/null || true)"

  if [ "$GIT_COMMIT" != "unknown" ] && [ "$actual_commit" != "$GIT_COMMIT" ]; then
    echo "✗ $app does not match the source revision that was just built." >&2
    echo "  expected: $GIT_COMMIT" >&2
    echo "  actual:   ${actual_commit:-missing}" >&2
    exit 1
  fi
  if [ "$GIT_DIRTY" != "unknown" ] && [ "$actual_dirty" != "$GIT_DIRTY" ]; then
    echo "✗ $app has mismatched dirty-state provenance." >&2
    echo "  expected: $GIT_DIRTY" >&2
    echo "  actual:   ${actual_dirty:-missing}" >&2
    exit 1
  fi
  if [ "$actual_config" != "$CONFIG" ]; then
    echo "✗ $app has mismatched build configuration provenance." >&2
    echo "  expected: $CONFIG" >&2
    echo "  actual:   ${actual_config:-missing}" >&2
    exit 1
  fi
  if [ "$actual_date" != "$BUILD_DATE" ]; then
    echo "✗ $app has mismatched build timestamp provenance." >&2
    echo "  expected: $BUILD_DATE" >&2
    echo "  actual:   ${actual_date:-missing}" >&2
    exit 1
  fi

  echo "✓ Build provenance: $GIT_COMMIT_SHORT$GIT_DIRTY_SUFFIX ($CONFIG, $BUILD_DATE)"
}

notarize_app_bundle() {
  local app="$1"
  local notary_dir zip_path

  if ! /usr/bin/command -v xcrun >/dev/null 2>&1; then
    echo "✗ xcrun is required for notarization" >&2
    exit 1
  fi

  notary_dir="$(mktemp -d "${TMPDIR:-/tmp}/geraldine-notary.XXXXXX")"
  zip_path="$notary_dir/$APP_NAME.zip"

  echo "▸ Preparing notarization archive: $zip_path"
  ditto -c -k --keepParent "$app" "$zip_path"

  echo "▸ Submitting $APP_NAME.app to Apple notary service with profile: $NOTARY_PROFILE"
  xcrun notarytool submit "$zip_path" --keychain-profile "$NOTARY_PROFILE" --wait

  echo "▸ Stapling notarization ticket…"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
}

app_is_running() {
  local running
  running=$(/usr/bin/osascript -e "application id \"$BUNDLE_ID\" is running" 2>/dev/null || echo false)
  [ "$running" = "true" ]
}

rss_for_pid() {
  /bin/ps -o rss= -p "$1" 2>/dev/null | /usr/bin/awk '{print $1}'
}

check_launch_policy() {
  if ! /usr/bin/command -v syspolicy_check >/dev/null 2>&1; then
    return 0
  fi

  local policy_output
  if policy_output="$(syspolicy_check distribution "$APP" 2>&1)"; then
    return 0
  fi

  echo "$policy_output" >&2
  echo "✗ $APP_NAME.app failed macOS launch policy checks; not opening a process that macOS will block." >&2
  exit 1
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

launch_app_bundle() {
  local pid=""
  local rss=0

  /usr/bin/open "$APP"
  for attempt in {1..20}; do
    pid="$(/usr/bin/pgrep -f "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null | /usr/bin/head -n 1 || true)"
    if [ -n "$pid" ]; then
      rss="$(rss_for_pid "$pid")"
      if [ "${rss:-0}" -gt 8192 ]; then
        echo "✓ Relaunched: $APP"
        return 0
      fi
    fi
    sleep 0.25
  done

  if [ -n "$pid" ] && [ "${rss:-0}" -le 1024 ]; then
    echo "▸ LaunchServices started a pre-main stalled process (pid $pid); stopping it…"
    /bin/kill "$pid" >/dev/null 2>&1 || true
  fi

  return 1
}

sign_and_verify "$APP"
verify_bundle_provenance "$APP"
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
  verify_bundle_provenance "$APP"
  if [ "$DO_NOTARIZE" -eq 1 ]; then
    notarize_app_bundle "$APP"
  fi
  echo "✓ Installed & signed: $APP"
fi

if [ "$DO_INSTALL" -ne 1 ] && [ "$DO_NOTARIZE" -eq 1 ]; then
  notarize_app_bundle "$APP"
fi

if [ "$DO_RUN" -eq 1 ]; then
  echo "▸ Relaunching…"
  quit_running_app
  if [ "$DO_NOTARIZE" -eq 1 ]; then
    check_launch_policy
  fi
  if ! launch_app_bundle; then
    echo "✗ $APP_NAME.app did not initialize after LaunchServices started it" >&2
    echo "  The stalled process was stopped; no alternate executable was launched." >&2
    exit 1
  fi
fi
