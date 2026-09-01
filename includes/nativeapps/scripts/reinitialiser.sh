#!/bin/bash
# Native-mode "reinit one app": re-fetch the source and rebuild from scratch,
# then reload the LaunchAgent. Data dir (config/db) is kept — use suppression.sh
# to wipe it. Linux path: docker rm -f + docker system prune + appli.sh.
. "$(dirname "$0")/_common.sh"

line="$1"
[ -z "${line}" ] && { echo "Erreur : nom d'application manquant."; exit 1; }

if ! have_native_def "${line}"; then
  not_supported "${line}"
  exit 1
fi

echo "Réinitialisation de ${line} (les données sous ${STORAGE_ROOT}/${line} sont conservées)…"
# blow away the build tree so install_native_app.sh re-clones cleanly
rm -rf "${STORAGE_ROOT}/${line}/src"
exec "${INSTALLER}" "${line}"
