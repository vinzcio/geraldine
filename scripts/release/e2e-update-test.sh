#!/bin/bash
#
# End-to-end update test in an isolated lane. Proves that a packaged Geraldine
# finds a newer signed release on its own, installs it automatically, relaunches,
# and continues a running Keep Awake session, without touching the installed
# app, its preferences, its control socket, or its data.
#
#   scripts/release/e2e-update-test.sh --payload <package-update.sh output> \
#       --work <empty owned folder> --sparkle-bin <folder holding sign_update>
#
# The payload's app is copied twice and given its own lane: bundle ID
# com.vincent.geraldine.updatetest, its own Application Support folder (so its
# own socket and history), a loopback feed, a throwaway signing key, no
# geraldine: URL scheme, Stay Active off, and only the code signature redone.
# Copy A (0.2.0, build 9001) runs; the loopback feed offers copy B (0.2.1,
# build 9002). A's first scheduled check is set to fire 45 seconds after
# launch, after this script has turned Keep Awake on through A's socket.
# Everything the lane creates outside --work is removed on exit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
CODESIGN_ID="${CODESIGN_ID:-7C2D0C6BBB3E0FB2628245B94E258A227E9920B7}"
TEST_ID="com.vincent.geraldine.updatetest"
TEST_NAME="Geraldine Update Test"
TIMEOUT=300
PAYLOAD=""
WORK=""
SPARKLE_BIN=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --payload) PAYLOAD="${2:-}"; shift 2 ;;
    --work) WORK="${2:-}"; shift 2 ;;
    --sparkle-bin) SPARKLE_BIN="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "✗ $*" >&2; exit 1; }
step() { echo "▸ $(date -u +%H:%M:%S) $*"; }
# Prints a dotted path from JSON on stdin; missing keys and bad input print nothing.
json() { /usr/bin/python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    for k in sys.argv[1].split("."): d = d.get(k) if isinstance(d, dict) else None
except ValueError:
    d = None
print("" if d is None else d)' "$1"; }

[ -f "$PAYLOAD/release.json" ] || die "Pass --payload with a folder made by package-update.sh"
[ -d "$WORK" ] && [ -z "$(ls -A "$WORK")" ] || die "Pass --work with an empty folder this test may fill"
SIGN_UPDATE="$SPARKLE_BIN/sign_update"
[ -x "$SIGN_UPDATE" ] || die "Pass --sparkle-bin with the folder holding Sparkle's sign_update"

SUPPORT="$HOME/Library/Application Support/$TEST_NAME"
OWNED_PATHS=(
  "$SUPPORT"
  "$HOME/Library/Caches/$TEST_ID"
  "$HOME/Library/HTTPStorages/$TEST_ID"
  "$HOME/Library/HTTPStorages/$TEST_ID.binarycookies"
  "$HOME/Library/Saved Application State/$TEST_ID.savedState"
  "$HOME/Library/Preferences/$TEST_ID.plist"
)
# The lane only ever removes what it created: refuse to start over leftovers.
for path in "${OWNED_PATHS[@]}"; do
  [ ! -e "$path" ] || die "$path already exists; remove it by hand after checking it is test residue"
done
/usr/bin/defaults read "$TEST_ID" >/dev/null 2>&1 && die "The $TEST_ID preferences domain already exists"
/usr/bin/pgrep -f "$WORK/" >/dev/null && die "Something is already running from $WORK"

APP_A="$WORK/apps/$TEST_NAME.app"
APP_B="$WORK/next/$TEST_NAME.app"
FEED="$WORK/feed"
CLI="$WORK/geraldine-cli"
SOCKET="$SUPPORT/control.sock"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
SERVER_PID=""

lane_pids() { /usr/bin/pgrep -f "$WORK/apps/$TEST_NAME.app/Contents/MacOS/" || true; }
cleanup() {
  set +e
  for pid in $(lane_pids); do kill -TERM "$pid" 2>/dev/null; done
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -z "$(lane_pids)" ] && break; sleep 0.5; done
  for pid in $(lane_pids); do kill -KILL "$pid" 2>/dev/null; done
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null
  for app in "$APP_A" "$APP_B"; do [ ! -d "$app" ] || "$LSREGISTER" -u "$app" 2>/dev/null; done
  /usr/bin/defaults delete "$TEST_ID" >/dev/null 2>&1
  for path in "${OWNED_PATHS[@]}"; do [ ! -e "$path" ] || /bin/rm -rf "$path"; done
  for path in "${OWNED_PATHS[@]}"; do [ ! -e "$path" ] || echo "✗ cleanup left $path" >&2; done
}
trap cleanup EXIT

# --- Build the lane ---------------------------------------------------------------
ARCHIVE="$PAYLOAD/$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["archive"])' "$PAYLOAD/release.json")"
step "Extracting $ARCHIVE"
/usr/bin/ditto -x -k "$ARCHIVE" "$WORK/source"
SOURCE="$WORK/source/Geraldine.app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :GeraldineUpdateChannel' "$SOURCE/Contents/Info.plist")" = production ] \
  || die "The payload app is not a production-channel build"

TEST_PUBLIC_KEY="$(/usr/bin/xcrun swift "$SCRIPT_DIR/sparkle-key.swift" create "$WORK/test-key/sparkle-ed25519.key")"
PORT="$(/usr/bin/python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"

relane() {
  local destination="$1" version="$2" build="$3" plist
  mkdir -p "$(dirname "$destination")"
  /usr/bin/ditto "$SOURCE" "$destination"
  plist="$destination/Contents/Info.plist"
  /usr/bin/plutil -replace CFBundleIdentifier -string "$TEST_ID" "$plist"
  /usr/bin/plutil -replace CFBundleName -string "$TEST_NAME" "$plist"
  /usr/bin/plutil -replace CFBundleDisplayName -string "$TEST_NAME" "$plist"
  /usr/bin/plutil -remove CFBundleURLTypes "$plist"
  /usr/bin/plutil -replace CFBundleShortVersionString -string "$version" "$plist"
  /usr/bin/plutil -replace CFBundleVersion -string "$build" "$plist"
  /usr/bin/plutil -replace GeraldineUpdateChannel -string "e2e-test" "$plist"
  /usr/bin/plutil -replace SUFeedURL -string "http://127.0.0.1:$PORT/appcast.xml" "$plist"
  /usr/bin/plutil -replace SUPublicEDKey -string "$TEST_PUBLIC_KEY" "$plist"
  /usr/bin/plutil -replace GeraldineSupportFolderName -string "$TEST_NAME" "$plist"
  /usr/bin/plutil -replace NSAppTransportSecurity -json '{"NSAllowsLocalNetworking":true}' "$plist"
  # A stapled notarization ticket belongs to the original signature.
  /bin/rm -f "$destination/Contents/CodeResources"
  /usr/bin/codesign --force --options runtime --entitlements "$REPO/Geraldine.entitlements" \
    --identifier "$TEST_ID" --sign "$CODESIGN_ID" "$destination" 2>/dev/null
  /usr/bin/codesign --verify --deep --strict "$destination"
}
step "Re-laning copy A (0.2.0, 9001) and copy B (0.2.1, 9002)"
relane "$APP_A" 0.2.0 9001
relane "$APP_B" 0.2.1 9002
cp "$APP_A/Contents/Helpers/geraldine" "$CLI"

step "Publishing copy B on http://127.0.0.1:$PORT"
mkdir -p "$FEED"
ZIP="$FEED/Geraldine-0.2.1-9002.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_B" "$ZIP"
signed="$("$SIGN_UPDATE" --ed-key-file "$WORK/test-key/sparkle-ed25519.key" "$ZIP")"
printf '## Update test\n\n- Copy B for the isolated update lane.\n' > "$WORK/notes.md"
/usr/bin/python3 -B "$SCRIPT_DIR/appcast.py" write --output "$FEED/appcast.xml" --allow-loopback-http \
  --version 0.2.1 --build 9002 --url "http://127.0.0.1:$PORT/Geraldine-0.2.1-9002.zip" \
  --length "$(sed -n 's/.* length="\([0-9]*\)".*/\1/p' <<<"$signed")" \
  --ed-signature "$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$signed")" \
  --notes "$WORK/notes.md" --hardware arm64
"$SIGN_UPDATE" --ed-key-file "$WORK/test-key/sparkle-ed25519.key" "$FEED/appcast.xml" >/dev/null
/usr/bin/xcrun swift "$SCRIPT_DIR/sparkle-key.swift" verify-feed "$TEST_PUBLIC_KEY" "$FEED/appcast.xml" >/dev/null
/usr/bin/python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$FEED" >"$WORK/http.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 40); do /usr/bin/curl -fsS -o /dev/null "http://127.0.0.1:$PORT/appcast.xml" 2>/dev/null && break; sleep 0.25; done
/usr/bin/curl -fsS -o /dev/null "http://127.0.0.1:$PORT/appcast.xml" || die "The loopback feed did not start"

# --- Run copy A -------------------------------------------------------------------
/usr/bin/defaults write "$TEST_ID" appShape -string menuBarOnly
/usr/bin/defaults write "$TEST_ID" didOnboard -bool true
/usr/bin/defaults write "$TEST_ID" keepAwake.simulateIdleActivity -bool false
/usr/bin/defaults write "$TEST_ID" keepAwake.allowDisplaySleep -bool true
/usr/bin/defaults write "$TEST_ID" powerTools.window.missionControlTwoFingerClose -bool false
/usr/bin/defaults write "$TEST_ID" SULastCheckTime -date "$(date -u -v-3555S '+%Y-%m-%d %H:%M:%S +0000')"

lane() { GERALDINE_CONTROL_SOCKET="$SOCKET" "$CLI" "$@" --json --timeout 5 2>/dev/null; }
LIVE_CLI="$HOME/.local/bin/geraldine"
live_status() { [ -x "$LIVE_CLI" ] && env -u GERALDINE_CONTROL_SOCKET "$LIVE_CLI" status --json --timeout 5 2>/dev/null || true; }
LIVE_BEFORE="$(live_status)"

step "Launching copy A"
/usr/bin/open -g "$APP_A"
STATUS=""
for _ in $(seq 1 60); do STATUS="$(lane status || true)"; [ -n "$STATUS" ] && break; sleep 0.5; done
[ -n "$STATUS" ] || die "Copy A never answered on its own socket"
PID_A="$(json result.app.pid <<<"$STATUS")"
[ "$(json result.app.build <<<"$STATUS")" = 9001 ] || die "Copy A reports another build"
[ "$(json result.app.socket <<<"$STATUS")" = "$SOCKET" ] || die "Copy A is not on its isolated socket"

AWAKE="$(lane awake on --for 2h)" || die "Could not turn Keep Awake on in copy A"
UNTIL="$(json result.activeUntil <<<"$AWAKE")"
[ -n "$UNTIL" ] || die "Keep Awake reported no end time: $AWAKE"
step "Copy A (pid $PID_A) is running with Keep Awake on until $UNTIL; waiting for the scheduled check"

AFTER=""
deadline=$((SECONDS + TIMEOUT))
while [ "$SECONDS" -lt "$deadline" ]; do
  current="$(lane status || true)"
  if [ -n "$current" ] && [ "$(json result.app.build <<<"$current")" = 9002 ]; then
    AFTER="$current"
    break
  fi
  sleep 2
done
[ -n "$AFTER" ] || die "Copy A did not update itself within $TIMEOUT seconds (see $WORK/http.log)"
PID_B="$(json result.app.pid <<<"$AFTER")"
step "Relaunched as 0.2.1 (9002), pid $PID_B"

# --- Verify -------------------------------------------------------------------------
[ "$PID_B" != "$PID_A" ] || die "The process never restarted"
[ "$(json result.app.version <<<"$AFTER")" = 0.2.1 ] || die "Unexpected version after the update"
[ "$(json result.keepAwake.active <<<"$AFTER")" = True ] || die "Keep Awake did not survive the update restart"
[ "$(json result.keepAwake.activeUntil <<<"$AFTER")" = "$UNTIL" ] || die "Keep Awake came back with another end time"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_A/Contents/Info.plist")" = 9002 ] \
  || die "The bundle on disk is not copy B"
/usr/bin/codesign --verify --deep --strict "$APP_A" || die "The installed copy fails code signature checks"
! /usr/bin/defaults read "$TEST_ID" appUpdate.relaunchHandoff >/dev/null 2>&1 || die "The relaunch handoff was not consumed"
/usr/bin/grep -q 'GET /Geraldine-0.2.1-9002.zip' "$WORK/http.log" || die "The archive was never downloaded"

LIVE_AFTER="$(live_status)"
if [ -n "$LIVE_BEFORE" ]; then
  [ "$(json result.app.pid <<<"$LIVE_AFTER")" = "$(json result.app.pid <<<"$LIVE_BEFORE")" ] || die "The installed app restarted"
  [ "$(json result.keepAwake.active <<<"$LIVE_AFTER")" = "$(json result.keepAwake.active <<<"$LIVE_BEFORE")" ] \
    || die "The installed app's Keep Awake changed"
  [ "$(json result.stayActive.enabled <<<"$LIVE_AFTER")" = "$(json result.stayActive.enabled <<<"$LIVE_BEFORE")" ] \
    || die "The installed app's Stay Active changed"
fi

/usr/bin/python3 - "$WORK/e2e-result.json" "$PID_A" "$PID_B" "$UNTIL" "$(json result.app.pid <<<"$LIVE_BEFORE")" <<'PY'
import json, sys
json.dump({
    "result": "passed",
    "fromBuild": "9001", "toBuild": "9002",
    "pidBefore": sys.argv[2], "pidAfter": sys.argv[3],
    "keepAwakeActiveUntil": sys.argv[4],
    "installedAppPid": sys.argv[5],
}, open(sys.argv[1], "w"), indent=2)
PY
echo "✓ The lane updated itself from 9001 to 9002, restarted, and kept Keep Awake on until $UNTIL. The installed Geraldine was untouched."
