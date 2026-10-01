#!/bin/sh
set -eu

# nginx:alpine does not ship openssl; install once at boot (demo-friendly).
if ! command -v openssl >/dev/null 2>&1; then
  apk add --no-cache openssl >/dev/null
fi

AUTH_FILE=/etc/nginx/.htpasswd
TEMPLATE=/etc/nginx/nginx.conf.template
CONF=/etc/nginx/nginx.conf

cp "$TEMPLATE" "$CONF"

if [ -n "${NGINX_BASIC_AUTH_USER:-}" ] && [ -n "${NGINX_BASIC_AUTH_PASSWORD:-}" ]; then
  HASH=$(openssl passwd -apr1 "$NGINX_BASIC_AUTH_PASSWORD")
  printf '%s:%s\n' "$NGINX_BASIC_AUTH_USER" "$HASH" > "$AUTH_FILE"
  echo "nginx: basic auth enabled for /prometheus /loki /tempo /alloy (user=$NGINX_BASIC_AUTH_USER)"
else
  sed -i \
    -e '/auth_basic /d' \
    -e '/auth_basic_user_file /d' \
    "$CONF"
  printf 'unused:$apr1$unused$xxxxxxxxxxxxxxxxxxxxxx\n' > "$AUTH_FILE"
  echo "nginx: basic auth disabled (set NGINX_BASIC_AUTH_* in .env to enable)"
fi

exec nginx -g 'daemon off;'
