#!/bin/bash
#
# Publish one packaged Geraldine release to its update host.
#
#   scripts/release/publish-update.sh --payload ~/geraldine-releases/<version>-build<build>
#
# Checks the payload against its manifest and the public key every client
# ships with, refuses a build that is not newer than the live feed, uploads the
# archive under its immutable name, then swaps appcast.xml atomically (keeping
# appcast.previous.xml). Finally it downloads both public URLs and compares
# them byte for byte with the payload. Server configuration is never touched.
# Re-running with a payload that is already live only re-verifies it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOST="${GERALDINE_UPDATE_HOST:-skyward}"
REMOTE_DIR="${GERALDINE_UPDATE_REMOTE_DIR:-/var/www/geraldine.hemisthia.com/updates}"
PAYLOAD=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --payload) PAYLOAD="${2:-}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "✗ $*" >&2; exit 1; }
step() { echo "▸ $*"; }
sha256() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print $1 }'; }

[ -n "$PAYLOAD" ] && [ -f "$PAYLOAD/release.json" ] || die "Pass --payload with a folder made by package-update.sh"
manifest() {
  /usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$PAYLOAD/release.json" "$1"
}
VERSION="$(manifest version)"
BUILD="$(manifest build)"
ARCHIVE_NAME="$(manifest archive)"
ARCHIVE_URL="$(manifest archiveURL)"
ARCHIVE_SHA="$(manifest archiveSHA256)"
ARCHIVE_LENGTH="$(manifest archiveLength)"
ED_SIGNATURE="$(manifest edSignature)"
APPCAST_SHA="$(manifest appcastSHA256)"
FEED_URL="$(manifest feedURL)"
NOTARIZED="$(manifest notarized)"
REHEARSAL="$(manifest rehearsal)"
ARCHIVE="$PAYLOAD/$ARCHIVE_NAME"
APPCAST="$PAYLOAD/appcast.xml"

# --- The payload is exactly what package-update.sh signed ---------------------
step "Checking the payload for Geraldine $VERSION ($BUILD)"
[ "$FEED_URL" = "$(sed -n 's/^PRODUCTION_FEED_URL="\(.*\)"$/\1/p' "$REPO/build.sh")" ] \
  || die "The payload names another feed than build.sh"
PUBLIC_KEY="$(sed -n 's/^PRODUCTION_SPARKLE_PUBLIC_KEY="\(.*\)"$/\1/p' "$REPO/build.sh")"
case "$ARCHIVE_NAME" in Geraldine-"$VERSION"-"$BUILD".zip) ;; *) die "Unexpected archive name $ARCHIVE_NAME" ;; esac
[ "$ARCHIVE_URL" = "${FEED_URL%/appcast.xml}/$ARCHIVE_NAME" ] || die "The archive URL is not beside the feed"
[ "$(sha256 "$ARCHIVE")" = "$ARCHIVE_SHA" ] || die "The archive does not match release.json"
[ "$(/usr/bin/stat -f %z "$ARCHIVE")" = "$ARCHIVE_LENGTH" ] || die "The archive length does not match release.json"
[ "$(sha256 "$APPCAST")" = "$APPCAST_SHA" ] || die "appcast.xml does not match release.json"
/usr/bin/xcrun swift "$SCRIPT_DIR/sparkle-key.swift" verify "$PUBLIC_KEY" "$ARCHIVE" "$ED_SIGNATURE" >/dev/null \
  || die "The archive signature does not verify against the shipped public key"
/usr/bin/xcrun swift "$SCRIPT_DIR/sparkle-key.swift" verify-feed "$PUBLIC_KEY" "$APPCAST" >/dev/null \
  || die "The feed signature does not verify against the shipped public key"
/usr/bin/python3 -B - "$SCRIPT_DIR/appcast.py" "$APPCAST" "$BUILD" "$VERSION" "$ARCHIVE_URL" "$ARCHIVE_LENGTH" "$ED_SIGNATURE" <<'PY' \
  || die "appcast.xml does not describe exactly this archive"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("appcast", sys.argv[1])
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)
items = appcast.items(sys.argv[2])
assert len(items) == 1, "one item"
item = items[0]
assert item["signedFeed"], "signed"
assert item["build"] == sys.argv[3] and item["version"] == sys.argv[4], "version"
assert item["url"] == sys.argv[5] and item["length"] == int(sys.argv[6]), "enclosure"
assert item["edSignature"] == sys.argv[7], "signature"
PY
[ "$REHEARSAL" = "False" ] || die "This is a rehearsal payload; it can never be published."
[ "$NOTARIZED" = "True" ] || die "This payload is not notarized. Package it again with NOTARY_PROFILE set."

SCRATCH="$(/usr/bin/mktemp -d /private/tmp/geraldine-publish.XXXXXX)"
cleanup() {
  case "$SCRATCH" in
    /private/tmp/geraldine-publish.??????) /bin/rm -rf "$SCRATCH" ;;
  esac
}
trap cleanup EXIT

verify_public() {
  step "Downloading the public feed and archive"
  /usr/bin/curl -fsS --max-time 30 -D "$SCRATCH/feed-headers" -o "$SCRATCH/public-appcast.xml" "$FEED_URL" \
    || die "Could not download $FEED_URL"
  [ "$(sha256 "$SCRATCH/public-appcast.xml")" = "$APPCAST_SHA" ] || die "The public feed differs from the payload"
  grep -qi '^cache-control:.*no-store' "$SCRATCH/feed-headers" || die "The public feed may be cached"
  /usr/bin/curl -fsS --max-time 300 -o "$SCRATCH/public-archive.zip" "$ARCHIVE_URL" \
    || die "Could not download $ARCHIVE_URL"
  [ "$(sha256 "$SCRATCH/public-archive.zip")" = "$ARCHIVE_SHA" ] || die "The public archive differs from the payload"
  echo "✓ $FEED_URL now offers Geraldine $VERSION ($BUILD); the feed and archive match the payload byte for byte."
}

# --- Compare with what is live --------------------------------------------------
step "Reading the live feed"
status="$(/usr/bin/curl -sS -o "$SCRATCH/live-appcast.xml" -w '%{http_code}' --max-time 20 "$FEED_URL" || echo 000)"
case "$status" in
  200)
    if [ "$(sha256 "$SCRATCH/live-appcast.xml")" = "$APPCAST_SHA" ]; then
      step "This payload is already live"
      verify_public
      exit 0
    fi
    LIVE_BUILD="$(/usr/bin/python3 -B "$SCRIPT_DIR/appcast.py" latest-build "$SCRATCH/live-appcast.xml")" \
      || die "The live feed is unreadable"
    if [ -n "$LIVE_BUILD" ] && [ "$BUILD" -le "$LIVE_BUILD" ]; then
      die "Build $BUILD is not newer than the live build $LIVE_BUILD"
    fi
    ;;
  404) step "No feed is live yet; publishing the first release" ;;
  *) die "Could not read $FEED_URL (HTTP $status). Run deploy/updates/setup-update-host.sh first." ;;
esac

remote() { /usr/bin/ssh -T -o BatchMode=yes "$HOST" "$@"; }

# --- Archive: immutable name ------------------------------------------------------
step "Uploading $ARCHIVE_NAME to $HOST"
existing="$(remote bash -s -- "$REMOTE_DIR" "$ARCHIVE_NAME" <<'SH'
set -euo pipefail
cd "$1" || { echo missing-folder; exit 0; }
if [ -e "$2" ]; then sha256sum "$2" | cut -d' ' -f1; else echo absent; fi
SH
)"
case "$existing" in
  missing-folder) die "$HOST has no $REMOTE_DIR. Run deploy/updates/setup-update-host.sh --apply first." ;;
  absent)
    /usr/bin/scp -q -o BatchMode=yes "$ARCHIVE" "$HOST:$REMOTE_DIR/.incoming/$ARCHIVE_NAME.partial"
    remote bash -s -- "$REMOTE_DIR" "$ARCHIVE_NAME" "$ARCHIVE_SHA" <<'SH'
set -euo pipefail
cd "$1"
partial=".incoming/$2.partial"
[ "$(sha256sum "$partial" | cut -d' ' -f1)" = "$3" ] || { rm -f "$partial"; echo "upload corrupted" >&2; exit 1; }
chmod 0644 "$partial"
[ ! -e "$2" ] || { echo "$2 appeared during the upload" >&2; exit 1; }
mv -n "$partial" "$2"
[ "$(sha256sum "$2" | cut -d' ' -f1)" = "$3" ]
SH
    ;;
  "$ARCHIVE_SHA") step "The archive is already on $HOST with the same bytes" ;;
  *) die "$HOST already has a different $ARCHIVE_NAME. Archives are never replaced; package a new build." ;;
esac

# --- Feed: atomic swap ---------------------------------------------------------------
step "Switching appcast.xml to build $BUILD"
/usr/bin/scp -q -o BatchMode=yes "$APPCAST" "$HOST:$REMOTE_DIR/.incoming/appcast.xml.$BUILD"
remote bash -s -- "$REMOTE_DIR" "$BUILD" "$APPCAST_SHA" "$ARCHIVE_NAME" "$ARCHIVE_SHA" <<'SH'
set -euo pipefail
cd "$1"
staged=".incoming/appcast.xml.$2"
[ "$(sha256sum "$staged" | cut -d' ' -f1)" = "$3" ] || { rm -f "$staged"; echo "feed upload corrupted" >&2; exit 1; }
[ "$(sha256sum "$4" | cut -d' ' -f1)" = "$5" ] || { echo "the archive changed before the switch" >&2; exit 1; }
chmod 0644 "$staged"
[ ! -e appcast.xml ] || cp -p appcast.xml appcast.previous.xml
mv -f "$staged" appcast.xml
[ "$(sha256sum appcast.xml | cut -d' ' -f1)" = "$3" ]
SH

verify_public
