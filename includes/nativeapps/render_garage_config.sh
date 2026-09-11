#!/bin/bash
# config_render for the `garage` native app — writes <data_dir>/config.toml
# (single-node S3-compatible object store for Silo). Idempotent: keeps the
# existing rpc_secret/admin_token across re-renders (regenerating them would
# desync a running cluster / invalidate the CLI's admin auth).
set -euo pipefail
DATA_DIR="${1:?usage: render_garage_config.sh <data_dir>}"
CONF="${DATA_DIR}/config.toml"
mkdir -p "${DATA_DIR}/meta" "${DATA_DIR}/data"

existing_secret=""
existing_admin_token=""
if [ -f "${CONF}" ]; then
  existing_secret="$(sed -n 's/^rpc_secret = "\(.*\)"$/\1/p' "${CONF}")"
  existing_admin_token="$(sed -n 's/^admin_token = "\(.*\)"$/\1/p' "${CONF}")"
fi
RPC_SECRET="${existing_secret:-$(openssl rand -hex 32)}"
ADMIN_TOKEN="${existing_admin_token:-$(openssl rand -hex 32)}"

cat > "${CONF}" <<EOF
# Rendered by render_garage_config.sh — re-run via install_native_app.sh garage
# to pick up path changes; rpc_secret/admin_token are preserved across re-renders.
metadata_dir = "${DATA_DIR}/meta"
data_dir = "${DATA_DIR}/data"
db_engine = "sqlite"

replication_factor = 1

rpc_bind_addr = "127.0.0.1:3901"
rpc_public_addr = "127.0.0.1:3901"
rpc_secret = "${RPC_SECRET}"

[s3_api]
s3_region = "garage"
api_bind_addr = "127.0.0.1:3900"
root_domain = ".s3api.jmiflix.fr"

# Anonymous read of buckets flagged \`garage bucket website --allow\` — this is
# how Silo's public poster assets are served to browsers (URLAuth "public",
# no SigV4 signature for Cloudflare to break). Bucket is matched by a global
# alias equal to the full Host when it isn't a subdomain of web_root_domain.
[s3_web]
bind_addr = "127.0.0.1:3902"
root_domain = ".web.jmiflix.fr"
index = "index.html"

[admin]
api_bind_addr = "127.0.0.1:3903"
admin_token = "${ADMIN_TOKEN}"
EOF
echo " * garage config.toml écrit : ${CONF}"
