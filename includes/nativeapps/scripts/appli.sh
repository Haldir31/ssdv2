#!/bin/bash
# Native-mode "deploy one app". Linux path: ansible-playbook generique.yml.
# Here: includes/nativeapps/install_native_app.sh <app> (LaunchAgent, no Docker).
. "$(dirname "$0")/_common.sh"

line="$1"
[ -z "${line}" ] && { echo "Erreur : nom d'application manquant."; exit 1; }

if ! have_native_def "${line}"; then
  not_supported "${line}"
  exit 1
fi

echo "Déploiement natif de ${line}…"
exec "${INSTALLER}" "${line}"
