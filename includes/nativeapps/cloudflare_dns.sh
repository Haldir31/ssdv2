#!/bin/bash
###############################################################################
# Publie les apps natives sur un domaine via un tunnel Cloudflare :
#   - ajoute <app>.<domaine> -> http://localhost:<port web Traefik> à l'ingress
#     du tunnel  (GET/PUT /accounts/{acc}/cfd_tunnel/{tun}/configurations)
#   - crée/maj le CNAME exact <app> -> <tunnel_id>.cfargotunnel.com (proxied)
#     (ajouter un hostname à l'ingress ne crée PAS le DNS — cf. l'expérience
#      jmiflix.fr : les enregistrements exacts priment sur un éventuel wildcard)
#
# Idempotent. NE FAIT RIEN sans SSD_CF_DNS=1. DRY_RUN=1 pour ne rien écrire.
#
# Config (env, sinon ~/.config/ssd/cloudflare.env, sinon settings.json backend) :
#   CF_API_TOKEN     token : Account.Cloudflare Tunnel (R+W) + Zone.DNS (Write)
#   CF_ACCOUNT_ID
#   SSD_TUNNEL_ID
#   CF_ZONE_ID       (sinon résolu depuis SSD_DOMAIN via GET /zones?name=)
#   SSD_DOMAIN
#
# Usage : cloudflare_dns.sh [<data_dir_traefik>]
###############################################################################
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARS_DIR="${SCRIPT_DIR}/vars"
YELLOW="${YELLOW:-\033[0;33m}"; GREEN="${GREEN:-\033[0;32m}"
RED="${RED:-\033[0;31m}"; BLUE="${BLUE:-\033[0;36m}"; NC="${NC:-\033[0m}"
say(){ echo -e "${BLUE}==>${NC} $*"; }
warn(){ echo -e " ${YELLOW}!${NC} $*" >&2; }

[ "${SSD_CF_DNS:-}" = "1" ] || { warn "SSD_CF_DNS != 1 — publication Cloudflare ignorée."; exit 0; }

# --- config -----------------------------------------------------------------
CF_ENV="${HOME}/.config/ssd/cloudflare.env"
[ -f "${CF_ENV}" ] && . "${CF_ENV}"

DATA_DIR="${1:-}"
BSET=""
[ -n "${DATA_DIR}" ] && BSET="$(cd "${DATA_DIR}/.." 2>/dev/null && pwd)/ssd-backend/data/settings.json"
[ -z "${BSET:-}" ] || [ -f "${BSET}" ] || BSET="${HOME}/seedbox/native/ssd-backend/data/settings.json"

_from_settings(){ [ -f "${BSET}" ] && /usr/bin/python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print((d.get('$1') or {}).get('$2','') or '')" "${BSET}" 2>/dev/null || true; }

CF_API_TOKEN="${CF_API_TOKEN:-$(_from_settings cloudflare cloudflare_api_key)}"
SSD_DOMAIN="${SSD_DOMAIN:-$(_from_settings utilisateur domain)}"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-}"
SSD_TUNNEL_ID="${SSD_TUNNEL_ID:-}"
CF_ZONE_ID="${CF_ZONE_ID:-}"
HTTP_PORT="${SSD_TRAEFIK_HTTP_PORT:-8000}"
TUNNEL_SVC="http://localhost:${HTTP_PORT}"

for v in CF_API_TOKEN SSD_DOMAIN CF_ACCOUNT_ID SSD_TUNNEL_ID; do
  [ -n "$(eval printf '%s' \"\$$v\")" ] || { warn "${v} manquant (env ou ${CF_ENV})."; exit 1; }
done

API="https://api.cloudflare.com/client/v4"
AUTH=(-H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")
DRY="${DRY_RUN:-0}"
CNAME_TARGET="${SSD_TUNNEL_ID}.cfargotunnel.com"

cf(){ curl -sS "${AUTH[@]}" "$@"; }
ok(){ /usr/bin/python3 -c "import json,sys;d=json.load(sys.stdin);sys.exit(0 if d.get('success') else 1)"; }

# --- zone id ---------------------------------------------------------------
if [ -z "${CF_ZONE_ID}" ]; then
  CF_ZONE_ID="$(cf "${API}/zones?name=${SSD_DOMAIN}" | /usr/bin/python3 -c "import json,sys;r=json.load(sys.stdin).get('result') or [];print(r[0]['id'] if r else '')" 2>/dev/null || true)"
  [ -n "${CF_ZONE_ID}" ] || { warn "zone ${SSD_DOMAIN} introuvable (le token a-t-il Zone:Read ? sinon poser CF_ZONE_ID)."; exit 1; }
fi

# --- liste des hostnames à publier -----------------------------------------
# Par défaut : toutes les apps natives avec un port + webui.
# SSD_CF_HOSTS="a b c" pour restreindre à ces apps-là.
FILTER=" ${SSD_CF_HOSTS:-} "
HOSTS=""
for f in "${VARS_DIR}"/*.yml; do
  app="$(basename "${f}" .yml)"
  [ "${app}" = "traefik" ] && continue
  [ "${FILTER}" != "  " ] && case "${FILTER}" in *" ${app} "*) : ;; *) continue ;; esac
  if [ "${app}" = "webui" ]; then HOSTS="${HOSTS} webui"; continue; fi
  grep -qE '^port:[[:space:]]*[0-9]' "${f}" && HOSTS="${HOSTS} ${app}"
done
[ -n "${HOSTS// /}" ] || { warn "aucun hostname à publier (SSD_CF_HOSTS='${SSD_CF_HOSTS:-}')"; exit 0; }
say "Domaine ${SSD_DOMAIN} | tunnel ${SSD_TUNNEL_ID} | hostnames :${HOSTS}"
[ "${DRY}" = "1" ] && warn "DRY_RUN=1 — aucune écriture"

# --- ingress du tunnel ----------------------------------------------------
CFG="$(cf "${API}/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${SSD_TUNNEL_ID}/configurations")"
echo "${CFG}" | ok || { warn "lecture config tunnel échouée : $(echo "${CFG}" | head -c 200)"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
CFG_JSON="${CFG}" SSD_DOMAIN="${SSD_DOMAIN}" TUNNEL_SVC="${TUNNEL_SVC}" HOSTS="${HOSTS}" OUT="${WORK}" /usr/bin/python3 - <<'PY'
import json, os, sys
d = json.loads(os.environ["CFG_JSON"])
cfg = d["result"].get("config") or {}
ingress = cfg.get("ingress") or [{"service": "http_status:404"}]
dom, svc = os.environ["SSD_DOMAIN"], os.environ["TUNNEL_SVC"]
want = {f"{h}.{dom}" for h in os.environ["HOSTS"].split()}
kept = [e for e in ingress if e.get("hostname")]
catchall = [e for e in ingress if not e.get("hostname")] or [{"service": "http_status:404"}]
have = {e["hostname"] for e in kept}
added = []
for hn in sorted(want - have):
    kept.append({"hostname": hn, "service": svc}); added.append(hn)
for e in kept:
    if e.get("hostname") in want and e.get("service") != svc:
        e["service"] = svc; added.append(e["hostname"] + " (maj)")
cfg["ingress"] = kept + catchall
open(os.path.join(os.environ["OUT"], "cfg.json"), "w").write(json.dumps({"config": cfg}))
open(os.path.join(os.environ["OUT"], "added.txt"), "w").write(", ".join(added))
PY

ADDED="$(cat "${WORK}/added.txt")"
if [ -n "${ADDED}" ]; then
  if [ "${DRY}" = "1" ]; then
    echo -e " ${YELLOW}[dry] ingress à ajouter/màj : ${ADDED}${NC}"
  else
    R="$(cf -X PUT "${API}/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${SSD_TUNNEL_ID}/configurations" --data "@${WORK}/cfg.json")"
    echo "${R}" | ok && echo -e " ${GREEN}* ingress tunnel màj : ${ADDED}${NC}" || { warn "PUT ingress échoué : $(echo "${R}" | head -c 200)"; exit 1; }
  fi
else
  echo " * ingress tunnel déjà à jour"
fi

# --- DNS : un CNAME exact par hostname -----------------------------------
for h in ${HOSTS}; do
  fqdn="${h}.${SSD_DOMAIN}"
  rec="$(cf "${API}/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${fqdn}")"
  rid="$(echo "${rec}" | /usr/bin/python3 -c "import json,sys;r=json.load(sys.stdin).get('result') or [];print(r[0]['id'] if r else '')" 2>/dev/null || true)"
  cur="$(echo "${rec}" | /usr/bin/python3 -c "import json,sys;r=json.load(sys.stdin).get('result') or [];print(r[0]['content'] if r else '')" 2>/dev/null || true)"
  body="{\"type\":\"CNAME\",\"name\":\"${fqdn}\",\"content\":\"${CNAME_TARGET}\",\"proxied\":true,\"ttl\":1}"
  if [ "${cur}" = "${CNAME_TARGET}" ]; then
    echo " * DNS ${fqdn} OK"
  elif [ "${DRY}" = "1" ]; then
    echo -e " ${YELLOW}[dry] DNS ${fqdn} -> ${CNAME_TARGET} ($([ -n "${rid}" ] && echo maj || echo création))${NC}"
  elif [ -n "${rid}" ]; then
    cf -X PATCH "${API}/zones/${CF_ZONE_ID}/dns_records/${rid}" -d "${body}" | ok \
      && echo -e " ${GREEN}* DNS ${fqdn} mis à jour${NC}" || warn "PATCH DNS ${fqdn} échoué"
  else
    cf -X POST "${API}/zones/${CF_ZONE_ID}/dns_records" -d "${body}" | ok \
      && echo -e " ${GREEN}* DNS ${fqdn} créé${NC}" || warn "POST DNS ${fqdn} échoué"
  fi
done

say "Publication Cloudflare terminée."
