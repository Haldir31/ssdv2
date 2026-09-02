#!/bin/bash
# Native-mode "remove one app": stop + unload the LaunchAgent, delete its plist,
# and remove the app's data dir (config, DB, build tree, logs). Linux path:
# suppression_appli (container + all.yml entry).
. "$(dirname "$0")/_common.sh"

line="$1"
[ -z "${line}" ] && { echo "Erreur : nom d'application manquant."; exit 1; }

label="com.ssd.${line}"
plist="${HOME}/Library/LaunchAgents/${label}.plist"
data_dir="${STORAGE_ROOT}/${line}"
log_dir="${HOME}/Library/Logs/ssd-native/${line}"

echo "Arrêt de ${label}…"
launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
for _ in $(seq 1 10); do
  launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1 || break
  sleep 1
done

[ -f "${plist}" ] && { rm -f "${plist}"; echo "LaunchAgent supprimé : ${plist}"; }
[ -d "${data_dir}" ] && { rm -rf "${data_dir}"; echo "Données supprimées : ${data_dir}"; }
[ -d "${log_dir}" ]  && rm -rf "${log_dir}"

# Cloudflare : retire le CNAME + l'entrée d'ingress du tunnel (symétrique de la
# publication auto à l'install). No-op si SSD_CF_DNS != 1 ou config absente.
if [ -x "${NATIVEAPPS}/cloudflare_dns.sh" ]; then
  SSD_CF_RM="${line}" "${NATIVEAPPS}/cloudflare_dns.sh" "${STORAGE_ROOT}/traefik" || true
fi

# Router Traefik : régénéré depuis vars/*.yml — retiré au prochain rendu si le
# vars/<app>.yml a disparu. On force le rendu maintenant si Traefik est installé.
if [ -f "${STORAGE_ROOT}/traefik/traefik.yml" ] && [ -x "${NATIVEAPPS}/render_traefik_config.sh" ] \
   && [ ! -f "${VARS_DIR}/${line}.yml" ]; then
  "${NATIVEAPPS}/render_traefik_config.sh" "${STORAGE_ROOT}/traefik" >/dev/null 2>&1 || true
  echo "Config Traefik régénérée (router ${line} retiré)."
fi

echo "Suppression de ${line} terminée."
exit 0
