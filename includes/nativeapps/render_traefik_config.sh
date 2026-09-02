#!/bin/bash
###############################################################################
# Renders a native (non-Docker) Traefik configuration on macOS.
#
# Called by install_native_app.sh for the `traefik` native app. Produces:
#   <data_dir>/traefik.yml        static config (entrypoints, providers, api)
#   <data_dir>/dynamic/           dynamic config dir (file provider, watched)
#   <data_dir>/dynamic/apps.yml   one HTTP router+service per native app that
#                                 has a `port` in includes/nativeapps/vars/*
#
# It intentionally starts from a minimal working config rather than rendering
# the full Docker-oriented Jinja2 templates in
# includes/dockerapps/templates/traefik/*.j2 (docker provider, Ansible vars) —
# those describe the richer routing/middleware/ACME setup to port incrementally.
#
# Ports: defaults to :8000 / :8443 so it runs as a plain LaunchAgent (no root).
# To use :80 / :443, edit traefik.yml and load it as a LaunchDaemon instead.
###############################################################################
set -euo pipefail

DATA_DIR="${1:?usage: render_traefik_config.sh <data_dir>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARS_DIR="${SCRIPT_DIR}/vars"
DYN_DIR="${DATA_DIR}/dynamic"
LOG_DIR="${HOME}/Library/Logs/ssd-native/traefik"
mkdir -p "${DYN_DIR}" "${LOG_DIR}"

# Base domain for the per-app routers: SSD_DOMAIN env, else utilisateur.domain
# from ssd-backend's settings.json (set via the WebUI), else empty. When set,
# each app answers on BOTH <app>.<domain> and <app>.local (so local access via
# /etc/hosts keeps working alongside the Cloudflare tunnel).
SSD_DOMAIN="${SSD_DOMAIN:-}"
if [ -z "${SSD_DOMAIN}" ]; then
  _bset="$(cd "${DATA_DIR}/.." 2>/dev/null && pwd)/ssd-backend/data/settings.json"
  [ -f "${_bset}" ] && SSD_DOMAIN="$(/usr/bin/python3 -c 'import json,sys;print((json.load(open(sys.argv[1])).get("utilisateur") or {}).get("domain","") or "")' "${_bset}" 2>/dev/null || true)"
fi
[ -n "${SSD_DOMAIN}" ] && echo " * domaine : ${SSD_DOMAIN} (routers <app>.${SSD_DOMAIN} + <app>.local)"

app_rule() {  # $1 = app name -> Traefik host rule
  if [ -n "${SSD_DOMAIN}" ]; then
    printf 'Host(`%s.%s`) || Host(`%s.local`)' "$1" "${SSD_DOMAIN}" "$1"
  else
    printf 'Host(`%s.local`)' "$1"
  fi
}

HTTP_PORT="${SSD_TRAEFIK_HTTP_PORT:-8000}"
HTTPS_PORT="${SSD_TRAEFIK_HTTPS_PORT:-8443}"
# 8090, not 8080: ssd-backend (webui) serves its API on 8080 in its upstream
# Docker setup and several clients hard-code it.
DASH_PORT="${SSD_TRAEFIK_DASH_PORT:-8090}"
# Which address the web/websecure entrypoints bind to. Default 127.0.0.1
# (localhost only — remote access via the Cloudflare tunnel). Set
# SSD_TRAEFIK_BIND=0.0.0.0 to also serve the LAN. The dashboard/api entrypoint
# stays on 127.0.0.1 always (api.insecure = true — never expose it).
BIND="${SSD_TRAEFIK_BIND:-127.0.0.1}"

# ---- static config -------------------------------------------------------
# (Re)write when absent, or when a previous render used a different dashboard
# port or bind address (kept simple: the file is fully generated, no hand-edits
# expected here — tune via the SSD_TRAEFIK_* env vars).
if [ -f "${DATA_DIR}/traefik.yml" ] && \
   { ! grep -q "127.0.0.1:${DASH_PORT}" "${DATA_DIR}/traefik.yml" || \
     ! grep -q "\"${BIND}:${HTTP_PORT}\"" "${DATA_DIR}/traefik.yml" || \
     ! grep -q "forwardedHeaders" "${DATA_DIR}/traefik.yml"; }; then
  cp "${DATA_DIR}/traefik.yml" "${DATA_DIR}/traefik.yml.bak"
  rm -f "${DATA_DIR}/traefik.yml"
  echo " * static config obsolète (port/bind/headers changés) -> régénération (ancien: traefik.yml.bak)"
fi
if [ ! -f "${DATA_DIR}/traefik.yml" ]; then
  cat > "${DATA_DIR}/traefik.yml" <<EOF
global:
  checkNewVersion: false
  sendAnonymousUsage: false

api:
  dashboard: true
  insecure: true          # API + dashboard on the 'traefik' entrypoint (127.0.0.1:${DASH_PORT} only)

ping:
  entryPoint: traefik

log:
  level: INFO
  filePath: "${LOG_DIR}/traefik.log"

accessLog:
  filePath: "${LOG_DIR}/access.log"
  format: json
  bufferingSize: 100

entryPoints:
  web:
    address: "${BIND}:${HTTP_PORT}"
    # Trust X-Forwarded-* from cloudflared (loopback) so the real https scheme
    # reaches the apps — SvelteKit's CSRF check ("Cross-site POST form
    # submissions are forbidden") needs it to rebuild the right Origin.
    forwardedHeaders:
      trustedIPs: ["127.0.0.1/32", "::1/128"]
  websecure:
    address: "${BIND}:${HTTPS_PORT}"
    forwardedHeaders:
      trustedIPs: ["127.0.0.1/32", "::1/128"]
  traefik:
    address: "127.0.0.1:${DASH_PORT}"

providers:
  file:
    directory: "${DYN_DIR}"
    watch: true

# --- Optional: Let's Encrypt via Cloudflare DNS-01 -----------------------
# Uncomment and set CF_DNS_API_TOKEN in the LaunchAgent env to enable.
# certificatesResolvers:
#   cloudflare:
#     acme:
#       email: "you@example.com"
#       storage: "${DATA_DIR}/acme.json"
#       dnsChallenge:
#         provider: cloudflare
#         resolvers: ["1.1.1.1:53"]
EOF
  echo " * static config -> ${DATA_DIR}/traefik.yml"
else
  echo " * static config déjà présent -> ${DATA_DIR}/traefik.yml (laissé tel quel)"
fi

# Apps that belong to a bundle (vars/*.yml with a `members:` line) get their
# routing from that bundle's own render hook, not a bare <app>.local router here.
BUNDLE_MEMBERS=" $(sed -n 's/^members:[[:space:]]*//p' "${VARS_DIR}"/*.yml | tr '\n' ' ') "
is_bundle_member() { case "${BUNDLE_MEMBERS}" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ---- dynamic config: one router per native app with a port --------------
{
  echo "# generated by render_traefik_config.sh — one router/service per"
  echo "# includes/nativeapps/vars/*.yml that declares a port (bundle members"
  echo "# excluded). Re-run the traefik native install to regenerate."
  echo "http:"
  echo "  routers:"
  for f in "${VARS_DIR}"/*.yml; do
    app="$(basename "${f}" .yml)"
    [ "${app}" = "traefik" ] && continue
    is_bundle_member "${app}" && continue
    p="$(sed -n 's/^port:[[:space:]]*//p' "${f}" | head -1)"
    [ -z "${p}" ] && continue
    printf "    %s:\n" "${app}"
    printf "      rule: \"%s\"\n" "$(app_rule "${app}")"
    printf "      entryPoints: ['web']\n"
    printf "      service: '%s'\n" "${app}"
    # Beat the WebUI bundle's host-less PathPrefix routers (webui.yml:
    # /api/v1 @100, / @10). Without this, <app>.<domain>/api/v1/... is
    # hijacked by webui-backend — broke AIOStreams' frontend (2026-09-01).
    printf "      priority: 200\n"
  done
  echo "  services:"
  for f in "${VARS_DIR}"/*.yml; do
    app="$(basename "${f}" .yml)"
    [ "${app}" = "traefik" ] && continue
    is_bundle_member "${app}" && continue
    p="$(sed -n 's/^port:[[:space:]]*//p' "${f}" | head -1)"
    [ -z "${p}" ] && continue
    echo "    ${app}:"
    echo "      loadBalancer:"
    echo "        servers:"
    echo "          - url: \"http://127.0.0.1:${p}\""
  done
} > "${DYN_DIR}/apps.yml"
echo " * dynamic config -> ${DYN_DIR}/apps.yml"

# ---- Traefik dashboard / API on its own host ---------------------------------
# Exposed through the `web` entrypoint (so it rides the Cloudflare tunnel like
# every other app) at traefik.<domain>, behind HTTP basic auth. Unauthenticated
# local access stays on 127.0.0.1:${DASH_PORT} (api.insecure in the static
# config). Credentials come from SSD_TRAEFIK_DASHBOARD_AUTH ("user:password"),
# hashed here with bcrypt (htpasswd) — fallback to openssl apr1-MD5, both
# understood by Traefik's basicAuth.
DASH_AUTH="${SSD_TRAEFIK_DASHBOARD_AUTH:-haldir:***REMOVED-CREDENTIAL***}"
DASH_USER="${DASH_AUTH%%:*}"
DASH_PASS="${DASH_AUTH#*:}"
HTPASSWD_BIN="$(command -v htpasswd 2>/dev/null || true)"
[ -x "${HTPASSWD_BIN:-}" ] || HTPASSWD_BIN="/usr/sbin/htpasswd"
if [ -x "${HTPASSWD_BIN}" ]; then
  DASH_HASH="$("${HTPASSWD_BIN}" -nbB "${DASH_USER}" "${DASH_PASS}")"
else
  DASH_HASH="${DASH_USER}:$(openssl passwd -apr1 "${DASH_PASS}")"
fi
{
  echo "# generated by render_traefik_config.sh — Traefik dashboard + API,"
  echo "# published on its own host behind basic auth (user: ${DASH_USER})."
  echo "# Regenerated on every 'install_native_app.sh traefik'. Change the"
  echo "# credentials with SSD_TRAEFIK_DASHBOARD_AUTH=user:pass then reinstall."
  echo "http:"
  echo "  routers:"
  echo "    traefik-dashboard:"
  printf "      rule: \"%s\"\n" "$(app_rule traefik)"
  echo "      entryPoints: ['web']"
  echo "      service: 'api@internal'"
  echo "      middlewares: ['traefik-dashboard-root', 'traefik-dashboard-auth']"
  echo "      priority: 200"
  echo "  middlewares:"
  echo "    traefik-dashboard-auth:"
  echo "      basicAuth:"
  echo "        users:"
  printf "          - \"%s\"\n" "${DASH_HASH}"
  echo "    traefik-dashboard-root:"
  echo "      redirectRegex:"
  printf '        regex: "^https?://[^/]+/?$"\n'
  printf '        replacement: "/dashboard/"\n'
}  > "${DYN_DIR}/dashboard.yml"
echo " * dashboard config -> ${DYN_DIR}/dashboard.yml (host $(app_rule traefik | sed 's/Host(`//;s/`).*//'), auth ${DASH_USER})"

# Publication Cloudflare (ingress tunnel + CNAME) — opt-in via SSD_CF_DNS=1.
# Lancé APRÈS le rendu des routers (les <app>.<domaine> doivent exister avant
# que le tunnel n'y pointe). Config dans ~/.config/ssd/cloudflare.env.
# Ce rendu est déclenché par un (ré)install de `traefik` : par défaut on ne
# (re)publie QUE traefik, sinon un simple `SSD_CF_DNS=1 install_native_app.sh
# traefik` exposerait toutes les apps natives (gethomepage, ssd-backend…).
# Passer SSD_CF_HOSTS="a b c" (ou lancer cloudflare_dns.sh directement) pour
# publier davantage.
if [ "${SSD_CF_DNS:-}" = "1" ] && [ -n "${SSD_DOMAIN}" ]; then
  SSD_DOMAIN="${SSD_DOMAIN}" SSD_CF_HOSTS="${SSD_CF_HOSTS:-traefik}" \
    "${SCRIPT_DIR}/cloudflare_dns.sh" "${DATA_DIR}" || \
    echo " ! publication Cloudflare échouée (voir ci-dessus) — routing local OK quand même" >&2
fi
