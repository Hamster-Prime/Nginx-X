#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# shellcheck disable=SC1091
source <(sed '$d' nx.sh)

SUDO=""
CONF_DIR="$TMPDIR_ROOT/conf.d"
SSL_DIR="$TMPDIR_ROOT/ssl"
mkdir -p "$CONF_DIR" "$SSL_DIR/example.com"
: > "$SSL_DIR/example.com/fullchain.pem"
: > "$SSL_DIR/example.com/privkey.pem"

out="$TMPDIR_ROOT/example-443.conf"
build_external_proxy_conf \
  "example.com" \
  "443" \
  "https://upstream.example.com" \
  "normal" \
  "$out" \
  "1"

grep -q '^# https_enabled=true$' "$out"
grep -q 'listen 443 ssl;' "$out"
grep -q "ssl_certificate     ${SSL_DIR}/example.com/fullchain.pem;" "$out"
grep -q "ssl_certificate_key ${SSL_DIR}/example.com/privkey.pem;" "$out"

bad_conf="$TMPDIR_ROOT/bad.conf"
cat > "$bad_conf" <<'EOF'
server {
    listen 443 ssl;
    server_name broken.example.com;
}
EOF

if ensure_ssl_directives_present "$bad_conf"; then
  echo "expected ensure_ssl_directives_present to fail for incomplete ssl config" >&2
  exit 1
fi

echo "ok"
