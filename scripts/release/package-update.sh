#!/bin/bash
#
# Build, sign, notarize, and package one Geraldine release for the update feed.
#
#   NOTARY_PROFILE=<notarytool keychain profile> \
#     scripts/release/package-update.sh --notes <release-notes.md>
#
# Options:
#   --output <dir>        Payload folder (default ~/geraldine-releases/<version>-build<build>)
#   --skip-live-check     Do not compare with the live feed (only before the host exists)
#   --rehearsal           Exercise the whole pipeline on the working tree: no
#                         notarization, no clean/merged/live checks. The payload
#                         says "rehearsal" and publish-update.sh refuses it.
#
# The payload holds Geraldine-<version>-<build>.zip, a signed appcast.xml, the
# release notes, and release.json. publish-update.sh uploads exactly that.
# Signing material stays on this Mac: the Developer ID identity in the login
# keychain and the update key file named by GERALDINE_SPARKLE_KEY_FILE.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
KEY_FILE="${GERALDINE_SPARKLE_KEY_FILE:-$HOME/Library/Application Support/Geraldine Release/sparkle-ed25519.key}"
TEAM_ID="4S9BMP9GU3"
BUNDLE_ID="com.vincent.geraldine"
# The one Developer ID identity on the release Mac, by hash so a duplicate
# keychain listing can never make the name ambiguous.
CODESIGN_ID="${CODESIGN_ID:-7C2D0C6BBB3E0FB2628245B94E258A227E9920B7}"

NOTES=""
OUTPUT=""
REHEARSAL=0
SKIP_LIVE_CHECK=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --notes) NOTES="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --skip-live-check) SKIP_LIVE_CHECK=1; shift ;;
    --rehearsal) REHEARSAL=1; SKIP_LIVE_CHECK=1; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "✗ $*" >&2; exit 1; }
step() { echo "▸ $*"; }

[ -n "$NOTES" ] && [ -f "$NOTES" ] || die "Pass --notes with a Markdown file describing the release"
NOTES="$(cd "$(dirname "$NOTES")" && pwd)/$(basename "$NOTES")"
[ -f "$KEY_FILE" ] || die "The update signing key is missing: $KEY_FILE"
if [ "$REHEARSAL" -eq 0 ] && [ -z "${NOTARY_PROFILE:-}" ]; then
  die "Set NOTARY_PROFILE to a notarytool keychain profile"
fi
if [ "$REHEARSAL" -eq 1 ] && [ -z "$OUTPUT" ]; then
  die "A rehearsal needs --output, so its payload never sits with real releases"
fi

FEED_URL="$(sed -n 's/^PRODUCTION_FEED_URL="\(.*\)"$/\1/p' "$REPO/build.sh")"
EXPECTED_PUBLIC_KEY="$(sed -n 's/^PRODUCTION_SPARKLE_PUBLIC_KEY="\(.*\)"$/\1/p' "$REPO/build.sh")"
[ -n "$FEED_URL" ] && [ -n "$EXPECTED_PUBLIC_KEY" ] || die "build.sh must define the production feed and key"
ARCHIVE_BASE="${FEED_URL%/appcast.xml}"

KEY_PUBLIC="$(/usr/bin/xcrun swift "$SCRIPT_DIR/sparkle-key.swift" public-key "$KEY_FILE")"
[ "$KEY_PUBLIC" = "$EXPECTED_PUBLIC_KEY" ] \
  || die "$KEY_FILE does not match build.sh's production public key"

# --- Source ------------------------------------------------------------------
COMMIT="$(/usr/bin/git -C "$REPO" rev-parse HEAD)"
if [ "$REHEARSAL" -eq 0 ]; then
  [ -z "$(/usr/bin/git -C "$REPO" status --porcelain --untracked-files=normal)" ] \
    || die "Commit or stash local changes first; releases are built from a clean checkout"
  step "Confirming $COMMIT is on origin/main"
  /usr/bin/git -C "$REPO" fetch --quiet origin main
  /usr/bin/git -C "$REPO" merge-base --is-ancestor "$COMMIT" origin/main \
    || die "HEAD is not on origin/main. Merge first."
fi

# An operator may supply an empty CLAYGO-owned directory. Its outer owner
# finalizes it after preserving packaging/install proof.
if [ -n "${GERALDINE_RELEASE_SCRATCH:-}" ]; then
  SCRATCH="$GERALDINE_RELEASE_SCRATCH"
  [ -d "$SCRATCH" ] && [ -z "$(/bin/ls -A "$SCRATCH")" ] || die "Release scratch must be an empty owned directory"
else
  SCRATCH="$(/usr/bin/mktemp -d /private/tmp/geraldine-release.XXXXXX)"
fi
cleanup() {
  [ -z "${GERALDINE_RELEASE_SCRATCH:-}" ] || return 0
  case "$SCRATCH" in
    /private/tmp/geraldine-release.??????) /bin/rm -rf "$SCRATCH" ;;
  esac
}
trap cleanup EXIT

# --- Build --------------------------------------------------------------------
step "Building the production channel"
GERALDINE_BUILD_ROOT="$SCRATCH/build" GERALDINE_UPDATE_CHANNEL=production CODESIGN_ID="$CODESIGN_ID" \
  "$REPO/build.sh" release
APP="$SCRATCH/build/Geraldine.app"
PLIST="$APP/Contents/Info.plist"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null || true; }

VERSION="$(plist CFBundleShortVersionString "$PLIST")"
BUILD="$(plist CFBundleVersion "$PLIST")"
[ "$(plist CFBundleIdentifier "$PLIST")" = "$BUNDLE_ID" ] || die "Unexpected bundle identifier"
[ "$(plist GeraldineUpdateChannel "$PLIST")" = "production" ] || die "The build is not on the production channel"
[ "$(plist SUFeedURL "$PLIST")" = "$FEED_URL" ] || die "The build names another feed"
[ "$(plist SUPublicEDKey "$PLIST")" = "$EXPECTED_PUBLIC_KEY" ] || die "The build carries another public key"
[ "$(plist GeraldineBuildCommit "$PLIST")" = "$COMMIT" ] || die "The build does not match $COMMIT"
if [ "$REHEARSAL" -eq 0 ]; then
  [ "$(plist GeraldineBuildDirty "$PLIST")" = "false" ] || die "The build came from a dirty tree"
fi
case "$BUILD" in ''|0|*[!0-9]*) die "The build number must be a positive whole number, got: $BUILD" ;; esac

step "Verifying signatures"
/usr/bin/codesign --verify --deep --strict "$APP" || die "The app signature does not verify"
for code in "$APP" "$APP/Contents/Frameworks/Sparkle.framework" "$APP/Contents/Helpers/geraldine"; do
  details="$(/usr/bin/codesign -dvv "$code" 2>&1)"
  grep -q "^TeamIdentifier=$TEAM_ID$" <<<"$details" || die "$code is not signed by team $TEAM_ID"
done
app_details="$(/usr/bin/codesign -dvv "$APP" 2>&1)"
grep -q 'flags=.*runtime' <<<"$app_details" || die "The app lacks the hardened runtime"

# --- Live feed ----------------------------------------------------------------
if [ "$SKIP_LIVE_CHECK" -eq 0 ]; then
  step "Reading the live feed"
  status="$(/usr/bin/curl -sS -o "$SCRATCH/live-appcast.xml" -w '%{http_code}' --max-time 20 "$FEED_URL" || echo 000)"
  case "$status" in
    200)
      LIVE_BUILD="$(/usr/bin/python3 -B "$SCRIPT_DIR/appcast.py" latest-build "$SCRATCH/live-appcast.xml")" \
        || die "The live feed is unreadable"
      if [ -n "$LIVE_BUILD" ] && [ "$BUILD" -le "$LIVE_BUILD" ]; then
        die "Build $BUILD is not newer than the published build $LIVE_BUILD"
      fi
      ;;
    404) step "No feed is published yet; this is the first release" ;;
    *) die "Could not read $FEED_URL (HTTP $status). Pass --skip-live-check only before the host exists." ;;
  esac
fi

# --- Notarize -----------------------------------------------------------------
NOTARIZED=false
if [ "$REHEARSAL" -eq 0 ]; then
  step "Notarizing with profile $NOTARY_PROFILE"
  /usr/bin/ditto -c -k --keepParent "$APP" "$SCRATCH/notarize.zip"
  /usr/bin/xcrun notarytool submit "$SCRATCH/notarize.zip" --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json > "$SCRATCH/notary.json"
  notary_status="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$SCRATCH/notary.json")"
  if [ "$notary_status" != "Accepted" ]; then
    cat "$SCRATCH/notary.json" >&2
    die "Notarization finished as: ${notary_status:-unknown}"
  fi
  /usr/bin/xcrun stapler staple "$APP"
  /usr/bin/xcrun stapler validate "$APP"
  NOTARIZED=true
fi

# --- Archive ------------------------------------------------------------------
[ -n "$OUTPUT" ] || OUTPUT="$HOME/geraldine-releases/$VERSION-build$BUILD"
[ ! -e "$OUTPUT" ] || die "$OUTPUT already exists; a payload is never overwritten"
mkdir -p "$OUTPUT"
ARCHIVE_NAME="Geraldine-$VERSION-$BUILD.zip"
ARCHIVE="$OUTPUT/$ARCHIVE_NAME"
step "Archiving $ARCHIVE_NAME"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

step "Checking the app inside the archive"
mkdir "$SCRATCH/extracted"
/usr/bin/ditto -x -k "$ARCHIVE" "$SCRATCH/extracted"
EXTRACTED="$SCRATCH/extracted/Geraldine.app"
/usr/bin/codesign --verify --deep --strict "$EXTRACTED" || die "The archived app's signature does not verify"
cdhash() { /usr/bin/codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }
[ "$(cdhash "$EXTRACTED")" = "$(cdhash "$APP")" ] || die "The archived app differs from the built app"
[ "$(plist CFBundleVersion "$EXTRACTED/Contents/Info.plist")" = "$BUILD" ] || die "The archived build number differs"
if [ "$NOTARIZED" = true ]; then
  /usr/bin/xcrun stapler validate "$EXTRACTED" || die "The archived app lost its notarization ticket"
  /usr/sbin/spctl --assess --type execute "$EXTRACTED" || die "Gatekeeper rejects the archived app"
fi

# --- Sign ---------------------------------------------------------------------
SIGN_UPDATE="$(/usr/bin/find "$SCRATCH/build/build/artifacts" -path '*/Sparkle/bin/sign_update' -type f -perm +111 -print -quit)"
[ -x "$SIGN_UPDATE" ] || die "Sparkle's sign_update was not found in the build"
step "Signing the archive"
signed="$("$SIGN_UPDATE" --ed-key-file "$KEY_FILE" "$ARCHIVE")"
ED_SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$signed")"
LENGTH="$(sed -n 's/.* length="\([0-9]*\)".*/\1/p' <<<"$signed")"
[ -n "$ED_SIGNATURE" ] && [ "$LENGTH" = "$(/usr/bin/stat -f %z "$ARCHIVE")" ] || die "Unexpected sign_update output: $signed"
/usr/bin/xcrun swift "$SCRIPT_DIR/sparkle-key.swift" verify "$EXPECTED_PUBLIC_KEY" "$ARCHIVE" "$ED_SIGNATURE" >/dev/null \
  || die "The archive signature does not verify against the shipped public key"

HARDWARE=""
case "$(/usr/bin/lipo -archs "$APP/Contents/MacOS/Geraldine")" in
  arm64) HARDWARE=arm64 ;;
  x86_64) HARDWARE=x86_64 ;;
esac

step "Writing and signing appcast.xml"
/usr/bin/python3 -B "$SCRIPT_DIR/appcast.py" write \
  --output "$OUTPUT/appcast.xml" \
  --version "$VERSION" --build "$BUILD" \
  --url "$ARCHIVE_BASE/$ARCHIVE_NAME" --length "$LENGTH" --ed-signature "$ED_SIGNATURE" \
  --notes "$NOTES" \
  --minimum-system-version "$(plist LSMinimumSystemVersion "$PLIST")" \
  ${HARDWARE:+--hardware "$HARDWARE"}
"$SIGN_UPDATE" --ed-key-file "$KEY_FILE" "$OUTPUT/appcast.xml" >/dev/null
"$SIGN_UPDATE" --verify --ed-key-file "$KEY_FILE" "$OUTPUT/appcast.xml" >/dev/null \
  || die "The signed appcast does not verify"
cp "$NOTES" "$OUTPUT/notes.md"

/usr/bin/python3 - "$OUTPUT" <<PY
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
manifest = {
    "format": 1,
    "version": "$VERSION",
    "build": "$BUILD",
    "commit": "$COMMIT",
    "feedURL": "$FEED_URL",
    "archive": "$ARCHIVE_NAME",
    "archiveURL": "$ARCHIVE_BASE/$ARCHIVE_NAME",
    "archiveSHA256": sha256(out / "$ARCHIVE_NAME"),
    "archiveLength": $LENGTH,
    "edSignature": "$ED_SIGNATURE",
    "appcastSHA256": sha256(out / "appcast.xml"),
    "notarized": $( [ "$NOTARIZED" = true ] && echo True || echo False ),
    "hardware": "${HARDWARE:-any}",
    "rehearsal": $( [ "$REHEARSAL" -eq 1 ] && echo True || echo False ),
}
(out / "release.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY

echo "✓ Geraldine $VERSION ($BUILD) is packaged in $OUTPUT"
[ "$REHEARSAL" -eq 0 ] || echo "  Rehearsal payload: not notarized, and publish-update.sh refuses it."
