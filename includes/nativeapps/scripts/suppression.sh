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

echo "Suppression de ${line} terminée."
exit 0
