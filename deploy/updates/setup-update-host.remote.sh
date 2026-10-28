# Runs on the update host, streamed by setup-update-host.sh after a
# SITE_CONFIG_B64 line. Arguments: check|apply, domain.
set -euo pipefail

MODE="$1"
DOMAIN="$2"
AVAILABLE=/etc/nginx/sites-available/geraldine-updates.conf
ENABLED=/etc/nginx/sites-enabled/geraldine-updates.conf
WEBROOT="/var/www/$DOMAIN"
CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
BACKUP="/var/backups/geraldine-updates/$(date -u +%Y%m%dT%H%M%SZ)"
DESIRED="$(printf '%s' "$SITE_CONFIG_B64" | base64 -d)"

others="$(grep -rlE "server_name[^;]*\b$DOMAIN\b" /etc/nginx/sites-enabled/ 2>/dev/null | grep -v "^$ENABLED$" || true)"
if [ -n "$others" ]; then
  echo "✗ Another enabled site already claims $DOMAIN: $others" >&2
  exit 1
fi

echo "▸ nginx test before any change:"
nginx -t
if [ -e "$AVAILABLE" ]; then
  if [ "$(cat "$AVAILABLE")" = "$DESIRED" ]; then echo "▸ Site config: current"; else echo "▸ Site config: differs (would be replaced)"; fi
else
  echo "▸ Site config: absent"
fi
[ -L "$ENABLED" ] && echo "▸ Site enabled" || echo "▸ Site not enabled"
[ -e "$CERT" ] && echo "▸ Certificate: present" || echo "▸ Certificate: absent (certbot --webroot will issue it)"
[ -d "$WEBROOT/updates" ] && echo "▸ Update folder: present" || echo "▸ Update folder: absent"

[ "$MODE" = apply ] || exit 0

mkdir -p "$BACKUP"
[ ! -e "$AVAILABLE" ] || cp -a "$AVAILABLE" "$BACKUP/"
echo "▸ Backup folder: $BACKUP"

restore() {
  echo "▸ Restoring the previous site configuration" >&2
  if [ -e "$BACKUP/geraldine-updates.conf" ]; then
    cp -a "$BACKUP/geraldine-updates.conf" "$AVAILABLE"
  else
    rm -f "$ENABLED" "$AVAILABLE"
  fi
  nginx -t && systemctl reload nginx
}

install_site() {
  printf '%s\n' "$1" > "$AVAILABLE.new"
  mv -f "$AVAILABLE.new" "$AVAILABLE"
  ln -sfn "$AVAILABLE" "$ENABLED"
  if ! nginx -t; then
    restore
    exit 1
  fi
  systemctl reload nginx
}

install -d -m 0755 -o root -g root "$WEBROOT" "$WEBROOT/updates"
# Staging for uploads; root only, and nginx answers 404 for it anyway.
install -d -m 0700 -o root -g root "$WEBROOT/updates/.incoming"

if [ ! -e "$CERT" ]; then
  install_site "server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type text/plain;
    }
    location / {
        return 404;
    }
}"
  certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" \
    --non-interactive --agree-tos --keep-until-expiring \
    --deploy-hook "systemctl reload nginx"
fi

install_site "$DESIRED"
echo "✓ $DOMAIN is configured"
