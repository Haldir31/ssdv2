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

# The Applications page's catalog endpoint hard-codes the Linux seedbox-compose
# path and ignores SERVICES_AVAILABLE_PATH — make it honour the env var.
CATALOG_EP="${SRC}/src/routes/settings/services.json/+server.ts"
if [ -f "${CATALOG_EP}" ] && ! grep -q 'SERVICES_AVAILABLE_PATH' "${CATALOG_EP}"; then
  /usr/bin/sed -i '' \
    's#const filePath = `/home/\${userName}/seedbox-compose/includes/config/services-available`;#const filePath = process.env.SERVICES_AVAILABLE_PATH || `/home/${userName}/seedbox-compose/includes/config/services-available`;  // [ssd-native]#' \
    "${CATALOG_EP}"
  echo -e " ${GREEN}* services.json endpoint : SERVICES_AVAILABLE_PATH honoré${NC}"
fi

# seedbox-form.svelte : le use:enhance a un onResult custom qui n'appelle jamais
# update() -> l'état "tainted" du superform n'est jamais remis à zéro après une
# sauvegarde réussie, d'où le "Leave page? Changes may not be saved" en changeant
# d'onglet alors que "Settings saved!" vient de s'afficher.
SB_FORM="${SRC}/src/lib/forms/seedbox-form.svelte"
if [ -f "${SB_FORM}" ] && ! grep -q 'taintedMessage: false' "${SB_FORM}"; then
  /usr/bin/python3 - "${SB_FORM}" <<'PYEOF'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace(
    '  const form = superForm(data, {\n'
    '    validators: zodClient(seedboxSettingsSchema),\n'
    '    dataType: "json",\n'
    '  });',
    '  const form = superForm(data, {\n'
    '    validators: zodClient(seedboxSettingsSchema),\n'
    '    dataType: "json",\n'
    '    taintedMessage: false,  // [ssd-native]\n'
    '  });', 1)
t = t.replace(
    '        onResult: ({ result }) => {\n'
    '          if (result.type === "success") onSuccess();',
    '        onResult: async ({ result, update }) => {  /* [ssd-native] */\n'
    '          await update();\n'
    '          if (result.type === "success") onSuccess();', 1)
open(p, 'w').write(t)
PYEOF
  echo -e " ${GREEN}* seedbox-form : taintedMessage off + update() après save${NC}"
fi
