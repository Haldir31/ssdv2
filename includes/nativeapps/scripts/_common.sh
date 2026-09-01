#!/bin/bash
# Sourced by the native-mode replacements of ssd-frontend/scripts/*.sh.
# ssd-backend runs these via GET /api/v1/scripts/run/<name> when SCRIPTS_DIR
# points here (vars/ssd-backend.yml). No ssdv2 shell framework, no ansible.
set -o pipefail

# includes/nativeapps/scripts -> repo root
_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_SOURCE="${SETTINGS_SOURCE:-$(cd "${_SELF}/../../.." && pwd)}"
NATIVEAPPS="${SETTINGS_SOURCE}/includes/nativeapps"
INSTALLER="${NATIVEAPPS}/install_native_app.sh"
VARS_DIR="${NATIVEAPPS}/vars"

STORAGE_ROOT="${SETTINGS_STORAGE:-${HOME}/seedbox}/native"

have_native_def() { [ -f "${VARS_DIR}/${1}.yml" ]; }

not_supported() {
  echo "「${1}」 n'est pas disponible en mode natif macOS (nécessite Docker)."
  echo "Ajoutez ${VARS_DIR}/${1}.yml pour l'intégrer au catalogue natif."
}
