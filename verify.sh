#!/bin/bash
set -euo pipefail

usage() {
  /usr/bin/printf 'Usage: %s --owner <thread/session-id> --minimum-free-kib <positive integer> [--self-test-after-register failure|term]\n' "$0" >&2
}

VERIFY_OWNER=''
MINIMUM_FREE_KIB=''
SELF_TEST_MODE=''
SEEN_OWNER=0
SEEN_MINIMUM=0
SEEN_SELF_TEST=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --owner)
      if [ "$SEEN_OWNER" -ne 0 ] || [ "$#" -lt 2 ]; then
        usage
        exit 2
      fi
      VERIFY_OWNER="$2"
      SEEN_OWNER=1
      shift 2
      ;;
    --minimum-free-kib)
      if [ "$SEEN_MINIMUM" -ne 0 ] || [ "$#" -lt 2 ]; then
        usage
        exit 2
      fi
      MINIMUM_FREE_KIB="$2"
      SEEN_MINIMUM=1
      shift 2
      ;;
    --self-test-after-register)
      if [ "$SEEN_SELF_TEST" -ne 0 ] || [ "$#" -lt 2 ]; then
        usage
        exit 2
      fi
      SELF_TEST_MODE="$2"
      SEEN_SELF_TEST=1
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

case "$VERIFY_OWNER" in
  ''|-*)
    usage
    exit 2
    ;;
esac

case "$MINIMUM_FREE_KIB" in
  ''|*[!0-9]*)
    usage
    exit 2
    ;;
esac
if ! /usr/bin/awk -v value="$MINIMUM_FREE_KIB" 'BEGIN { exit !((value + 0) > 0) }'; then
  usage
  exit 2
fi

if [ "$SEEN_SELF_TEST" -eq 0 ]; then
  SELF_TEST_MODE=''
else
  case "$SELF_TEST_MODE" in
    failure|term)
      ;;
    *)
      usage
      exit 2
      ;;
  esac
fi

REPO_ROOT="$(cd "$(dirname "$0")" && /bin/pwd -P)"
DEVELOPER_DIR_26='/Applications/Xcode.app/Contents/Developer'
SDKROOT_26_5="$DEVELOPER_DIR_26/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk"
CLAYGO='/Users/vincent/.codex/skills/claygo/scripts/claygo.py'

if [ ! -f "$REPO_ROOT/Package.swift" ] || [ ! -r "$REPO_ROOT/Package.swift" ] \
  || [ ! -d "$REPO_ROOT/Sources" ] || [ ! -r "$REPO_ROOT/Sources" ] || [ ! -x "$REPO_ROOT/Sources" ] \
  || [ ! -d "$REPO_ROOT/Tests" ] || [ ! -r "$REPO_ROOT/Tests" ] || [ ! -x "$REPO_ROOT/Tests" ]; then
  /usr/bin/printf 'Package.swift, Sources, and Tests must exist and be readable verifier inputs.\n' >&2
  exit 1
fi

AVAILABLE_FREE_KIB="$(/bin/df -Pk /private/tmp | /usr/bin/awk 'NR == 2 { print $4 }')"
case "$AVAILABLE_FREE_KIB" in
  ''|*[!0-9]*)
    /usr/bin/printf 'Unable to determine free space for /private/tmp.\n' >&2
    exit 1
    ;;
esac
/usr/bin/printf '/private/tmp space: %s KiB available; %s KiB required.\n' \
  "$AVAILABLE_FREE_KIB" "$MINIMUM_FREE_KIB"
if ! /usr/bin/awk \
  -v available="$AVAILABLE_FREE_KIB" \
  -v minimum="$MINIMUM_FREE_KIB" \
  'BEGIN { exit !((available + 0) >= (minimum + 0)) }'; then
  /usr/bin/printf 'Insufficient /private/tmp space: %s KiB available; %s KiB required.\n' \
    "$AVAILABLE_FREE_KIB" "$MINIMUM_FREE_KIB" >&2
  exit 1
fi

BLOCKING_NAMES=''
for process_name in swift-frontend swiftc clang xcodebuild; do
  if /usr/bin/pgrep -x "$process_name" >/dev/null 2>&1; then
    if [ -n "$BLOCKING_NAMES" ]; then
      BLOCKING_NAMES="$BLOCKING_NAMES, $process_name"
    else
      BLOCKING_NAMES="$process_name"
    fi
  fi
done
if [ -n "$BLOCKING_NAMES" ]; then
  /usr/bin/printf 'Refusing while build processes are active: %s\n' "$BLOCKING_NAMES" >&2
  exit 1
fi

if [ ! -d "$DEVELOPER_DIR_26" ] || [ ! -d "$SDKROOT_26_5" ]; then
  /usr/bin/printf 'Required Xcode developer directory or MacOSX26.5 SDK is unavailable.\n' >&2
  exit 1
fi

RESOLVED_SDK="$(/usr/bin/env DEVELOPER_DIR="$DEVELOPER_DIR_26" /usr/bin/xcrun --sdk macosx --show-sdk-path)"
if [ "$RESOLVED_SDK" != "$SDKROOT_26_5" ]; then
  /usr/bin/printf 'Resolved SDK does not match the required MacOSX26.5 SDK.\n' >&2
  exit 1
fi

if ! /usr/bin/git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  /usr/bin/printf 'Verifier must run from the Geraldine Git checkout.\n' >&2
  exit 1
fi

GIT_REVISION="$(/usr/bin/git -C "$REPO_ROOT" rev-parse HEAD)"
GIT_REVISION_SHORT="$(/usr/bin/printf '%s' "$GIT_REVISION" | /usr/bin/cut -c1-12)"
CURRENT_STATUS="$(/usr/bin/git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all)"

/usr/bin/printf 'Git revision: %s\n' "$GIT_REVISION"
/usr/bin/printf 'Git revision (short): %s\n' "$GIT_REVISION_SHORT"
if [ -n "$CURRENT_STATUS" ]; then
  /usr/bin/printf 'Git dirty state: dirty (the run is input-bound but not commit-reproducible)\n'
else
  /usr/bin/printf 'Git dirty state: clean\n'
fi
/usr/bin/printf 'Developer directory: %s\n' "$DEVELOPER_DIR_26"
/usr/bin/printf 'SDK path: %s\n' "$SDKROOT_26_5"
/usr/bin/env DEVELOPER_DIR="$DEVELOPER_DIR_26" /usr/bin/xcodebuild -version
/usr/bin/env DEVELOPER_DIR="$DEVELOPER_DIR_26" SDKROOT="$SDKROOT_26_5" \
  /usr/bin/xcrun --sdk macosx swift --version

OWNER_KEY="$(/usr/bin/printf '%s' "$VERIFY_OWNER" | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print substr($1, 1, 12) }')"
VERIFY_ROOT="/private/tmp/geraldine-verify-${OWNER_KEY}-$$"
VERIFY_RECEIPT="/tmp/geraldine-verify-${OWNER_KEY}-$$-receipt.json"
VERIFY_MODE="${SELF_TEST_MODE:-normal}"
VERIFY_COMPLETE=0

if [ -e "$VERIFY_ROOT" ] || [ -e "$VERIFY_RECEIPT" ]; then
  /usr/bin/printf 'Verifier scratch path or receipt already exists.\n' >&2
  exit 1
fi

cleanup_verifier() {
  original_status=$?
  final_status=$original_status
  cleanup_failed=0
  trap - EXIT INT TERM
  set +e

  "$CLAYGO" mark \
    --receipt "$VERIFY_RECEIPT" \
    --state disposable \
    --reason "Geraldine verifier ${VERIFY_MODE} run finished with status ${original_status}"
  if [ "$?" -ne 0 ]; then
    cleanup_failed=1
  fi

  "$CLAYGO" finalize --receipt "$VERIFY_RECEIPT" --check-open-files
  if [ "$?" -ne 0 ]; then
    cleanup_failed=1
  fi

  "$CLAYGO" closeout --owner "$VERIFY_OWNER" --finalize-disposable
  if [ "$?" -ne 0 ]; then
    cleanup_failed=1
  fi

  if [ -e "$VERIFY_ROOT" ] || [ -e "$VERIFY_RECEIPT" ]; then
    cleanup_failed=1
  fi

  if [ "$cleanup_failed" -eq 0 ]; then
    /usr/bin/printf 'VERIFY_INTERNAL_CLOSEOUT=OK mode=%s original_status=%s\n' \
      "$VERIFY_MODE" "$original_status"
    if [ "$original_status" -eq 0 ] && [ "$VERIFY_COMPLETE" -eq 1 ]; then
      /usr/bin/printf 'SOURCE VERIFICATION PASSED\n'
    elif [ "$original_status" -eq 0 ]; then
      final_status=1
    fi
  elif [ "$final_status" -eq 0 ]; then
    final_status=1
  fi

  exit "$final_status"
}

handle_int() {
  exit 130
}

handle_term() {
  exit 143
}

"$CLAYGO" init \
  --path "$VERIFY_ROOT" \
  --temp-root /private/tmp \
  --receipt "$VERIFY_RECEIPT" \
  --owner "$VERIFY_OWNER" \
  --purpose 'Geraldine staged source tests and clean release build' \
  --profile swiftpm

trap cleanup_verifier EXIT
trap handle_int INT
trap handle_term TERM

/usr/bin/printf 'VERIFY_ROOT=%s\n' "$VERIFY_ROOT"
/usr/bin/printf 'VERIFY_RECEIPT=%s\n' "$VERIFY_RECEIPT"

case "$SELF_TEST_MODE" in
  failure)
    /usr/bin/false
    ;;
  term)
    /bin/kill -TERM "$$"
    ;;
esac

write_input_manifest() {
  local base="$1"
  local output="$2"
  local input entry rel type mode digest find_list
  : > "$output"
  for input in Package.swift Sources Tests; do
    find_list="${output}.find.${input}"
    LC_ALL=C /usr/bin/find -s "$base/$input" -print0 > "$find_list" || return 1
    while IFS= read -r -d '' entry; do
      rel="${entry#"$base"/}"
      mode="$(/usr/bin/stat -f '%Lp' "$entry")" || return 1
      if [ -L "$entry" ]; then
        /usr/bin/printf 'Rejected symlink in verifier input: %s\n' "$rel" >&2
        return 1
      elif [ -f "$entry" ]; then
        type='file'
        digest="$(/usr/bin/shasum -a 256 "$entry" | /usr/bin/awk '{print $1}')" || return 1
      elif [ -d "$entry" ]; then
        type='directory'
        digest='-'
      else
        /usr/bin/printf 'Rejected special entry in verifier input: %s\n' "$rel" >&2
        return 1
      fi
      /usr/bin/printf '%s\0%s\0%s\0%s\0' \
        "$rel" "$type" "$mode" "$digest" >> "$output"
    done < "$find_list"
  done
}

/usr/bin/printf '%s\n' "$GIT_REVISION" > "$VERIFY_ROOT/source-head-before"
: > "$VERIFY_ROOT/source-status-before"
if [ -n "$CURRENT_STATUS" ]; then
  /usr/bin/printf '%s\n' "$CURRENT_STATUS" > "$VERIFY_ROOT/source-status-before"
fi
test "$(/usr/bin/git -C "$REPO_ROOT" rev-parse HEAD)" = "$GIT_REVISION"
/usr/bin/git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all > \
  "$VERIFY_ROOT/source-status-at-bind"
/usr/bin/cmp -s "$VERIFY_ROOT/source-status-before" "$VERIFY_ROOT/source-status-at-bind"
write_input_manifest "$REPO_ROOT" "$VERIFY_ROOT/source-before.manifest"
SOURCE_INPUT_SHA256="$(/usr/bin/shasum -a 256 "$VERIFY_ROOT/source-before.manifest" | /usr/bin/awk '{print $1}')"
/usr/bin/printf 'Source input SHA-256: %s\n' "$SOURCE_INPUT_SHA256"

/bin/mkdir -p "$VERIFY_ROOT/stage/Sources" "$VERIFY_ROOT/stage/Tests"
/usr/bin/rsync -a "$REPO_ROOT/Package.swift" "$VERIFY_ROOT/stage/Package.swift"
/usr/bin/rsync -a --delete "$REPO_ROOT/Sources/" "$VERIFY_ROOT/stage/Sources/"
/usr/bin/rsync -a --delete "$REPO_ROOT/Tests/" "$VERIFY_ROOT/stage/Tests/"

test -f "$VERIFY_ROOT/stage/Package.swift"
test -d "$VERIFY_ROOT/stage/Sources"
test -d "$VERIFY_ROOT/stage/Tests"
test ! -e "$VERIFY_ROOT/stage/.git"
test ! -e "$VERIFY_ROOT/stage/.jj"
test ! -e "$VERIFY_ROOT/stage/.build"
UNEXPECTED_STAGE_ENTRY="$(/usr/bin/find "$VERIFY_ROOT/stage" -mindepth 1 -maxdepth 1 \
  ! -name Package.swift ! -name Sources ! -name Tests -print -quit)"
test -z "$UNEXPECTED_STAGE_ENTRY"

write_input_manifest "$VERIFY_ROOT/stage" "$VERIFY_ROOT/stage.manifest"
write_input_manifest "$REPO_ROOT" "$VERIFY_ROOT/source-after-copy.manifest"
/usr/bin/cmp -s "$VERIFY_ROOT/source-before.manifest" "$VERIFY_ROOT/stage.manifest"
/usr/bin/cmp -s "$VERIFY_ROOT/source-before.manifest" "$VERIFY_ROOT/source-after-copy.manifest"
test "$(/usr/bin/git -C "$REPO_ROOT" rev-parse HEAD)" = "$(<"$VERIFY_ROOT/source-head-before")"
/usr/bin/git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all > \
  "$VERIFY_ROOT/source-status-after-copy"
/usr/bin/cmp -s "$VERIFY_ROOT/source-status-before" "$VERIFY_ROOT/source-status-after-copy"
STAGED_INPUT_SHA256="$(/usr/bin/shasum -a 256 "$VERIFY_ROOT/stage.manifest" | /usr/bin/awk '{print $1}')"
test "$STAGED_INPUT_SHA256" = "$SOURCE_INPUT_SHA256"
/usr/bin/printf 'Staged input SHA-256: %s\n' "$STAGED_INPUT_SHA256"

/usr/bin/env \
  DEVELOPER_DIR="$DEVELOPER_DIR_26" \
  SDKROOT="$SDKROOT_26_5" \
  CLANG_MODULE_CACHE_PATH="$VERIFY_ROOT/test-clang-module-cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$VERIFY_ROOT/test-swiftpm-module-cache" \
  /usr/bin/xcrun --sdk macosx swift test \
    --package-path "$VERIFY_ROOT/stage" \
    --scratch-path "$VERIFY_ROOT/test-build"

write_input_manifest "$VERIFY_ROOT/stage" "$VERIFY_ROOT/stage-after-tests.manifest"
/usr/bin/cmp -s "$VERIFY_ROOT/stage.manifest" "$VERIFY_ROOT/stage-after-tests.manifest"

test ! -e "$VERIFY_ROOT/release-build"
test ! -e "$VERIFY_ROOT/release-clang-module-cache"
test ! -e "$VERIFY_ROOT/release-swiftpm-module-cache"
/usr/bin/env \
  DEVELOPER_DIR="$DEVELOPER_DIR_26" \
  SDKROOT="$SDKROOT_26_5" \
  CLANG_MODULE_CACHE_PATH="$VERIFY_ROOT/release-clang-module-cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$VERIFY_ROOT/release-swiftpm-module-cache" \
  /usr/bin/xcrun --sdk macosx swift build -c release \
    --package-path "$VERIFY_ROOT/stage" \
    --scratch-path "$VERIFY_ROOT/release-build"

write_input_manifest "$VERIFY_ROOT/stage" "$VERIFY_ROOT/stage-after-release.manifest"
/usr/bin/cmp -s "$VERIFY_ROOT/stage.manifest" "$VERIFY_ROOT/stage-after-release.manifest"

write_input_manifest "$REPO_ROOT" "$VERIFY_ROOT/source-final.manifest"
/usr/bin/cmp -s "$VERIFY_ROOT/source-before.manifest" "$VERIFY_ROOT/source-final.manifest"
test "$(/usr/bin/git -C "$REPO_ROOT" rev-parse HEAD)" = "$(<"$VERIFY_ROOT/source-head-before")"
/usr/bin/git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all > \
  "$VERIFY_ROOT/source-status-final"
/usr/bin/cmp -s "$VERIFY_ROOT/source-status-before" "$VERIFY_ROOT/source-status-final"

VERIFY_COMPLETE=1
