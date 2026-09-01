#!/bin/bash
###############################################################################
# SSDv2 — macOS native (non-Docker) installer for a single app.
#
# This is the native-mode counterpart of the generic Ansible role
# includes/dockerapps/templates/generique/generique.yml (which calls the
# Ansible `docker_container` module). Instead of a container, it:
#   - fetches the app         (git clone/pull, or `brew install`)
#   - builds it               (kind: node -> npm ; kind: go -> go build ;
#                              kind: brew -> nothing)
#   - renders config          (optional, via `config_render`)
#   - writes + loads a LaunchAgent  (templates/launchagent.plist.tpl)
#   - polls the health endpoint
#
# App definitions live in includes/nativeapps/vars/<name>.yml — a deliberately
# restricted YAML subset (NO Jinja2, NO Ansible): flat "key: value" lines plus
# one "env:" block whose children are indented by exactly two spaces
# ("  KEY: value"). "#" comment lines are ignored. The literal token
# __APP_DATA_DIR__ in any value is replaced with the app's data directory.
#
# Usage: install_native_app.sh <name>
###############################################################################
set -euo pipefail

NAME="${1:?usage: install_native_app.sh <name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARS_FILE="${SCRIPT_DIR}/vars/${NAME}.yml"
TEMPLATE="${SCRIPT_DIR}/templates/launchagent.plist.tpl"

# colours (fallback if not sourced from variables.sh)
YELLOW="${YELLOW:-\033[0;33m}"; GREEN="${GREEN:-\033[0;32m}"
RED="${RED:-\033[0;31m}"; BLUE="${BLUE:-\033[0;36m}"; NC="${NC:-\033[0m}"

if [ ! -f "${VARS_FILE}" ]; then
  echo -e "${RED}Pas de définition native pour '${NAME}' (${VARS_FILE} introuvable).${NC}" >&2
  exit 1
fi
if [ "$(uname -s)" != "Darwin" ]; then
  echo -e "${RED}install_native_app.sh ne fonctionne que sur macOS.${NC}" >&2
  exit 1
fi
command -v brew >/dev/null 2>&1 || { echo -e "${RED}Homebrew requis. https://brew.sh${NC}" >&2; exit 1; }

STORAGE_ROOT="${SETTINGS_STORAGE:-${HOME}/seedbox}/native"
# data_dir (optional, in vars/<name>.yml): overrides the default location.
# Absolute path -> used as-is; bare name -> under ${STORAGE_ROOT}. Pre-scanned
# here (not in the main parse loop) because the __APP_DATA_DIR__ token
# substitution done while parsing needs the final value.
data_dir_raw="$(sed -n '/^data_dir:[[:space:]]*/{s/^data_dir:[[:space:]]*//;s/^"//;s/"$//;p;q;}' "${VARS_FILE}")"
case "${data_dir_raw}" in
  "")  APP_DATA_DIR="${STORAGE_ROOT}/${NAME}" ;;
  /*)  APP_DATA_DIR="${data_dir_raw}" ;;
  *)   APP_DATA_DIR="${STORAGE_ROOT}/${data_dir_raw}" ;;
esac
APP_SRC_DIR="${APP_DATA_DIR}/src"
LOG_DIR="${HOME}/Library/Logs/ssd-native/${NAME}"
LAUNCHAGENT="${HOME}/Library/LaunchAgents/com.ssd.${NAME}.plist"
mkdir -p "${APP_DATA_DIR}" "${LOG_DIR}" "${HOME}/Library/LaunchAgents"

# ---------------------------------------------------------------------------
# restricted-YAML reader  (bash 3.2 compatible — no associative arrays)
# ---------------------------------------------------------------------------
kind=""; repo=""; ref="main"; build_cmd=""; start_cmd=""; port=""
health_path="/"; node_version="22"; formula=""; config_render=""
python_version="3.12"; post_fetch=""

# strip surrounding double-quotes only if the WHOLE value is quoted
unquote() {
  case "$1" in
    \"*\") s="${1%\"}"; printf '%s' "${s#\"}" ;;
    *) printf '%s' "$1" ;;
  esac
}
ENV_KEYS=(); ENV_VALS=()
in_env=0
while IFS= read -r line || [ -n "${line}" ]; do
  [ -z "${line}" ] && continue
  case "${line}" in \#*|"  #"*|" #"*) continue ;; esac
  if printf '%s' "${line}" | grep -qE '^env:[[:space:]]*$'; then in_env=1; continue; fi
  if [ ${in_env} -eq 1 ] && printf '%s' "${line}" | grep -qE '^[[:space:]]{2,}[A-Za-z_][A-Za-z0-9_]*:'; then
    k=$(printf '%s' "${line}" | sed -E 's/^[[:space:]]+([A-Za-z_][A-Za-z0-9_]*):.*/\1/')
    v=$(printf '%s' "${line}" | sed -E 's/^[[:space:]]+[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*//')
    v="$(unquote "${v}")"
    v=$(printf '%s' "${v}" | sed "s#__APP_SRC_DIR__#${APP_SRC_DIR}#g;s#__APP_DATA_DIR__#${APP_DATA_DIR}#g")
    ENV_KEYS[${#ENV_KEYS[@]}]="${k}"; ENV_VALS[${#ENV_VALS[@]}]="${v}"
    continue
  fi
  in_env=0
  case "${line}" in
    *:*)
      key=$(printf '%s' "${line}" | sed -E 's/^([A-Za-z_][A-Za-z0-9_]*):.*/\1/')
      val=$(printf '%s' "${line}" | sed -E 's/^[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*//')
      val="$(unquote "${val}")"
      val=$(printf '%s' "${val}" | sed "s#__APP_SRC_DIR__#${APP_SRC_DIR}#g;s#__APP_DATA_DIR__#${APP_DATA_DIR}#g")
      case "${key}" in
        kind) kind="${val}" ;;
        repo) repo="${val}" ;;
        ref) ref="${val}" ;;
        build_cmd) build_cmd="${val}" ;;
        start_cmd) start_cmd="${val}" ;;
        port) port="${val}" ;;
        health_path) health_path="${val}" ;;
        node_version) node_version="${val}" ;;
        formula) formula="${val}" ;;
        config_render) config_render="${val}" ;;
        python_version) python_version="${val}" ;;
        post_fetch) post_fetch="${val}" ;;
        data_dir) : ;;  # already handled in the pre-scan above
      esac
      ;;
  esac
done < "${VARS_FILE}"

echo -e "${BLUE}### ${NAME} — installation native macOS (kind=${kind}) ###${NC}"

RUN_PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
WORKDIR="${APP_DATA_DIR}"

fetch_src() {
  if [ -d "${APP_SRC_DIR}/.git" ]; then
    git -C "${APP_SRC_DIR}" fetch --depth 1 origin "${ref}"
    git -C "${APP_SRC_DIR}" reset --hard "origin/${ref}"
  else
    git clone --depth 1 --branch "${ref}" "${repo}" "${APP_SRC_DIR}"
  fi
  # post_fetch: a script under includes/nativeapps/ run right after the source is
  # (re)fetched and before the build — for apps that need local patches on top of
  # a pristine upstream checkout (git reset --hard above wipes them every update).
  if [ -n "${post_fetch}" ]; then
    if [ -x "${SCRIPT_DIR}/${post_fetch}" ]; then
      echo -e " ${BLUE}* post_fetch : ${post_fetch}${NC}"
      "${SCRIPT_DIR}/${post_fetch}" "${APP_SRC_DIR}" "${APP_DATA_DIR}"
    else
      echo -e "${YELLOW} * post_fetch introuvable/non exécutable : ${SCRIPT_DIR}/${post_fetch}${NC}" >&2
    fi
  fi
}

case "${kind}" in
  node)
    NODE_BIN="/opt/homebrew/opt/node@${node_version}/bin"
    [ -d "${NODE_BIN}" ] || brew install "node@${node_version}"
    fetch_src
    ( cd "${APP_SRC_DIR}" && PATH="${NODE_BIN}:${PATH}" bash -c "${build_cmd}" )
    RUN_PATH="${NODE_BIN}:${RUN_PATH}"
    WORKDIR="${APP_SRC_DIR}"
    ;;
  go)
    command -v go >/dev/null 2>&1 || brew install go
    fetch_src
    ( cd "${APP_SRC_DIR}" && PATH="/opt/homebrew/bin:${PATH}" bash -c "${build_cmd}" )
    WORKDIR="${APP_SRC_DIR}"
    ;;
  python)
    PY_BIN="/opt/homebrew/opt/python@${python_version}/bin"
    [ -x "${PY_BIN}/python${python_version}" ] || brew install "python@${python_version}"
    VENV_DIR="${APP_DATA_DIR}/venv"
    [ -x "${VENV_DIR}/bin/python" ] || "${PY_BIN}/python${python_version}" -m venv "${VENV_DIR}"
    "${VENV_DIR}/bin/python" -m pip install -q --upgrade pip wheel
    fetch_src
    # build_cmd runs with the venv fully "activated" (PATH + VIRTUAL_ENV) so that
    # poetry/pip target the venv and never the Homebrew Python, CWD at the source
    # root. PIP_REQUIRE_VIRTUALENV guards against an accidental global install.
    ( cd "${APP_SRC_DIR}" \
        && PATH="${VENV_DIR}/bin:${PY_BIN}:${PATH}" \
           VIRTUAL_ENV="${VENV_DIR}" \
           PIP_REQUIRE_VIRTUALENV=true \
           POETRY_VIRTUALENVS_CREATE=false \
           bash -c "${build_cmd}" )
    RUN_PATH="${VENV_DIR}/bin:${RUN_PATH}"
    WORKDIR="${APP_SRC_DIR}"
    ;;
  brew)
    brew list --versions "${formula}" >/dev/null 2>&1 || brew install "${formula}"
    if [ -n "${config_render}" ] && [ -x "${SCRIPT_DIR}/${config_render}" ]; then
      "${SCRIPT_DIR}/${config_render}" "${APP_DATA_DIR}"
    fi
    ;;
  *)
    echo -e "${RED}kind '${kind}' inconnu dans ${VARS_FILE}${NC}" >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# LaunchAgent
# ---------------------------------------------------------------------------
# env entries: write to a temp file (KEY<TAB>VALUE) for python to read + escape
ENV_TSV="$(mktemp)"
for i in "${!ENV_KEYS[@]}"; do
  printf '%s\t%s\n' "${ENV_KEYS[$i]}" "${ENV_VALS[$i]}" >> "${ENV_TSV}"
done

tmp_plist="$(mktemp)"
NATIVE_LABEL="com.ssd.${NAME}" \
NATIVE_WORKDIR="${WORKDIR}" \
NATIVE_START_CMD="${start_cmd}" \
NATIVE_RUN_PATH="${RUN_PATH}" \
NATIVE_OUT_LOG="${LOG_DIR}/${NAME}.log" \
NATIVE_ERR_LOG="${LOG_DIR}/${NAME}.err.log" \
NATIVE_ENV_TSV="${ENV_TSV}" \
python3 - "${TEMPLATE}" "${tmp_plist}" <<'PYEOF'
import os, sys
from xml.sax.saxutils import escape
tpl, out = sys.argv[1], sys.argv[2]
env_entries = []
with open(os.environ["NATIVE_ENV_TSV"]) as fh:
    for row in fh:
        row = row.rstrip("\n")
        if not row:
            continue
        k, _, v = row.partition("\t")
        env_entries.append("        <key>%s</key>" % escape(k))
        env_entries.append("        <string>%s</string>" % escape(v))
repl = {
    "{{LABEL}}":       escape(os.environ["NATIVE_LABEL"]),
    "{{WORKDIR}}":     escape(os.environ["NATIVE_WORKDIR"]),
    "{{START_CMD}}":   escape(os.environ["NATIVE_START_CMD"]),
    "{{RUN_PATH}}":    escape(os.environ["NATIVE_RUN_PATH"]),
    "{{OUT_LOG}}":     escape(os.environ["NATIVE_OUT_LOG"]),
    "{{ERR_LOG}}":     escape(os.environ["NATIVE_ERR_LOG"]),
    "{{ENV_ENTRIES}}": "\n".join(env_entries),
}
s = open(tpl).read()
for a, b in repl.items():
    s = s.replace(a, b)
open(out, "w").write(s)
PYEOF
rm -f "${ENV_TSV}"

plutil -lint "${tmp_plist}" >/dev/null
mv "${tmp_plist}" "${LAUNCHAGENT}"
echo -e " ${GREEN}* LaunchAgent : ${LAUNCHAGENT}${NC}"

launchctl bootout "gui/$(id -u)/com.ssd.${NAME}" >/dev/null 2>&1 || true
# wait for the previous instance (and its KeepAlive respawns) to actually exit
for _ in $(seq 1 10); do
  launchctl print "gui/$(id -u)/com.ssd.${NAME}" >/dev/null 2>&1 || break
  sleep 1
done
launchctl bootstrap "gui/$(id -u)" "${LAUNCHAGENT}"

# ---------------------------------------------------------------------------
# health check
# ---------------------------------------------------------------------------
if [ -n "${port}" ]; then
  echo -n " * $(printf '%s' "en attente de :${port}${health_path} ")"
  ok=0
  for _ in $(seq 1 30); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${port}${health_path}" || true)"
    if [ "${code}" != "000" ] && [ -n "${code}" ]; then ok=1; echo " -> HTTP ${code}"; break; fi
    sleep 2; echo -n "."
  done
  if [ "${ok}" -eq 1 ]; then
    echo -e " ${GREEN}--> ${NAME} répond sur http://127.0.0.1:${port}${NC}"
  else
    echo -e " ${YELLOW}--> ${NAME} ne répond pas encore — voir ${LOG_DIR}/${NAME}.err.log${NC}"
  fi
fi
