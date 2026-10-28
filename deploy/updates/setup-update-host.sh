#!/bin/bash
#
# One-time setup of geraldine.hemisthia.com on the update host (skyward).
#
#   deploy/updates/setup-update-host.sh           # report only; changes nothing
#   deploy/updates/setup-update-host.sh --apply   # site, certificate, and folders
#
# Needs the DNS record first: geraldine.hemisthia.com, type A, the host's IP,
# DNS only (not proxied), like tendryls.hemisthia.com. --apply backs up any
# replaced server file under /var/backups/geraldine-updates/<UTC time>/, and an
# nginx configuration test failure restores it before anything reloads.
set -euo pipefail

HOST="${GERALDINE_UPDATE_HOST:-skyward}"
DOMAIN="geraldine.hemisthia.com"
HERE="$(cd "$(dirname "$0")" && pwd)"
MODE=check
case "${1:-}" in
  "") ;;
  --apply) MODE=apply ;;
  *) echo "Usage: $0 [--apply]" >&2; exit 2 ;;
esac

HOST_IP="$(/usr/bin/ssh -G "$HOST" 2>/dev/null </dev/null | /usr/bin/awk '$1 == "hostname" { print $2 }')"
DNS_IP="$(/usr/bin/dig +short A "$DOMAIN" | /usr/bin/tail -n 1)"
echo "▸ $HOST is $HOST_IP; $DOMAIN resolves to ${DNS_IP:-nothing}"
if [ "$DNS_IP" != "$HOST_IP" ]; then
  echo "✗ Add a DNS-only A record in Cloudflare: $DOMAIN → $HOST_IP (proxy off), then run this again." >&2
  exit 1
fi

{
  printf "SITE_CONFIG_B64='%s'\n" "$(/usr/bin/base64 < "$HERE/geraldine-updates.conf" | /usr/bin/tr -d '\n')"
  cat "$HERE/setup-update-host.remote.sh"
} | /usr/bin/ssh -T -o BatchMode=yes "$HOST" bash -s -- "$MODE" "$DOMAIN"

if [ "$MODE" = apply ]; then
  feed_status="$(/usr/bin/curl -sS -o /dev/null -w '%{http_code}' "https://$DOMAIN/updates/appcast.xml")"
  redirect_status="$(/usr/bin/curl -sS -o /dev/null -w '%{http_code}' "http://$DOMAIN/updates/appcast.xml")"
  echo "▸ https feed: HTTP $feed_status (404 until the first release is published); http: HTTP $redirect_status"
  [ "$redirect_status" = 301 ] || { echo "✗ Plain HTTP should redirect to HTTPS" >&2; exit 1; }
  case "$feed_status" in 200|404) ;; *) echo "✗ The HTTPS site is not answering" >&2; exit 1 ;; esac
  echo "✓ $DOMAIN is ready for scripts/release/publish-update.sh"
fi
