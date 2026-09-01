#!/bin/bash
###############################################################################
# post_fetch hook for the ssd-frontend native app (see vars/ssd-frontend.yml).
#
# ssd-frontend (SvelteKit, adapter-node) reads its backend URL + API key at
# runtime from `config/servers.json` (hooks.server.ts) and `config/server.json`
# (lib/serverConfig.ts), resolved against the process CWD (= the app's source
# dir). In the Docker setup these are provided via a mounted volume; here we
# generate them from the native ssd-backend's own settings.json (its api_key is
# auto-generated on first run).
#
# Usage: patch_ssd-frontend.sh <src_dir> <data_dir>
###############################################################################
set -euo pipefail

SRC="${1:?usage: patch_ssd-frontend.sh <src_dir> <data_dir>}"
DATA="${2:?usage: patch_ssd-frontend.sh <src_dir> <data_dir>}"
GREEN="${GREEN:-\033[0;32m}"; YELLOW="${YELLOW:-\033[0;33m}"; NC="${NC:-\033[0m}"

BACKEND_URL="${SSD_BACKEND_URL:-http://127.0.0.1:8091}"
# <storage>/native/ssd-frontend -> <storage>/native/ssd-backend/data/settings.json
BACKEND_SETTINGS="$(cd "${DATA}/.." && pwd)/ssd-backend/data/settings.json"

API_KEY=""
if [ -f "${BACKEND_SETTINGS}" ]; then
  API_KEY="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("api_key",""))' "${BACKEND_SETTINGS}" 2>/dev/null || true)"
fi
if [ -z "${API_KEY}" ]; then
  echo -e "${YELLOW} * clé API backend introuvable (${BACKEND_SETTINGS}) — installez ssd-backend d'abord ; config/servers.json écrit sans clé${NC}" >&2
fi

mkdir -p "${SRC}/config"
for f in servers.json server.json; do
  cat > "${SRC}/config/${f}" <<EOF
{
  "backendUrl": "${BACKEND_URL}",
  "apiKey": "${API_KEY}"
}
EOF
done
echo -e " ${GREEN}* config/servers.json + config/server.json générés (backend: ${BACKEND_URL})${NC}"
