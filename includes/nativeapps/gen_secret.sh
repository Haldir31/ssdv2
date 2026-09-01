#!/bin/bash
# Generic post_fetch helper: create <data>/secret_key (64 hex chars) once, so an
# app's signing/encryption key survives restarts and `git reset --hard` updates.
# Reference it from start_cmd: KEY="$(cat __APP_DATA_DIR__/secret_key)" ...
set -euo pipefail
DATA="${2:?usage: gen_secret.sh <src_dir> <data_dir>}"
GREEN="${GREEN:-\033[0;32m}"; NC="${NC:-\033[0m}"
mkdir -p "${DATA}"
if [ ! -s "${DATA}/secret_key" ]; then
  openssl rand -hex 32 > "${DATA}/secret_key"
  echo -e " ${GREEN}* secret_key généré -> ${DATA}/secret_key${NC}"
fi
