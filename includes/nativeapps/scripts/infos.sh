#!/bin/bash
# Native-mode "infos" step. On Linux this syncs settings.json -> the ansible
# all.yml inventory + builds htpasswd + runs the OAuth playbook. In native mode
# ssd-backend's own data/settings.json IS the configuration source — there is no
# inventory to sync — so this is a success no-op.
. "$(dirname "$0")/_common.sh"

echo "Mode natif macOS : settings.json est la source de configuration, aucune"
echo "synchronisation vers un inventaire ansible n'est nécessaire."
echo "Infos : OK."
exit 0
