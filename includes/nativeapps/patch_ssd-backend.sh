#!/bin/bash
###############################################################################
# post_fetch hook for the ssd-backend native app (see vars/ssd-backend.yml).
#
# `git reset --hard` in install_native_app.sh wipes local changes on every
# update, so the handful of macOS/native adjustments this fork needs are
# (re)applied here, idempotently, straight after the checkout.
#
# Upstream: github.com/laster13/ssd-backend (a trimmed Riven fork). None of
# this changes behaviour on Linux/Docker — each hunk is guarded by a
# "# [ssd-native]" marker and a no-op when the marker is already present.
#
# Usage: patch_ssd-backend.sh <src_dir> [<data_dir>]
###############################################################################
set -euo pipefail

SRC="${1:?usage: patch_ssd-backend.sh <src_dir> [data_dir]}"
DATA="${2:-}"
YELLOW="${YELLOW:-\033[0;33m}"; GREEN="${GREEN:-\033[0;32m}"; NC="${NC:-\033[0m}"

# Persistent JWT signing key for the seasonarr integration (env JWT_SECRET_KEY).
# Generated once, kept out of the repo so tokens survive restarts and updates.
if [ -n "${DATA}" ]; then
  mkdir -p "${DATA}"
  if [ ! -s "${DATA}/jwt_secret" ]; then
    openssl rand -hex 32 > "${DATA}/jwt_secret"
    echo -e " ${GREEN}* JWT secret généré -> ${DATA}/jwt_secret${NC}"
  fi
fi

python3 - "${SRC}" <<'PYEOF'
import io, os, sys, pathlib

src = pathlib.Path(sys.argv[1])
MARK = "# [ssd-native]"
changed = []

def patch(relpath, transform):
    p = src / relpath
    text = p.read_text(encoding="utf-8")
    new = transform(text)          # each transform is a no-op if its hunk is already in
    if new != text:
        p.write_text(new, encoding="utf-8")
        changed.append(relpath)

# --- 1. symlinks.py: module-level `docker.from_env()` explodes at import when
#        there is no Docker daemon (which kills the whole app on macOS). ---------
def p_symlinks(t):
    old = "\nclient = docker.from_env()\n"
    if old not in t or MARK in t:
        return t
    new = ("\ntry:  " + MARK + "\n"
           "    client = docker.from_env()\n"
           "except Exception:\n"
           "    client = None\n")
    return t.replace(old, new, 1)
patch("src/routers/secure/symlinks.py", p_symlinks)

# --- 2. program/utils/__init__.py: let SSD_DATA_DIR override the data dir so it
#        lives in the app's data dir, not inside the git checkout. --------------
def p_utils(t):
    old = 'data_dir_path = Path(__file__).resolve().parents[3] / "data"'
    if old not in t or MARK in t:
        return t
    new = ('data_dir_path = (Path(os.environ["SSD_DATA_DIR"]) if os.environ.get("SSD_DATA_DIR")  ' + MARK + '\n'
           '                 else Path(__file__).resolve().parents[3] / "data")')
    return t.replace(old, new, 1)
patch("src/program/utils/__init__.py", p_utils)

# --- 3. file_watcher.py: the YAML watcher tails an ansible-vault inventory that
#        does not exist in native mode -> watchdog raises FileNotFoundError.
#        Bail out cleanly when the inventory dir is absent. --------------------
def p_watcher(t):
    anchor = 'def start_yaml_watcher():\n    logger.info("\U0001f6f0️ YAML watcher démarré")\n'
    if anchor not in t or MARK in t:
        return t
    inject = (anchor +
              "    if not os.path.isdir(os.path.dirname(YAML_PATH)):  " + MARK + "\n"
              "        logger.info(\"\U0001f6f0️ YAML watcher désactivé (pas d'inventaire ansible — mode natif)\")\n"
              "        return\n")
    return t.replace(anchor, inject, 1)
patch("src/program/file_watcher.py", p_watcher)

# --- 4. seasonarr auth cookies: COOKIE_SECURE is hard-coded True and the cookies
#        are SameSite=None -> a browser drops them over plain HTTP, so login/
#        register "succeed" but no session sticks and onboarding loops. Make it
#        env-driven (COOKIE_SECURE, default true) and pick a valid SameSite. -----
def p_cookie_const(t):
    old = "COOKIE_SECURE = True"
    if old not in t or MARK in t:
        return t
    new = ('COOKIE_SECURE = os.getenv("COOKIE_SECURE", "true").strip().lower() not in ("0", "false", "no")  ' + MARK)
    return t.replace(old, new, 1)
patch("src/integrations/seasonarr/core/auth.py", p_cookie_const)

def p_cookie_samesite(t):
    # COOKIE_SECURE is already imported in this module. Replace the bare string
    # in every set_cookie/delete_cookie call; leaves any trailing comma intact.
    new_expr = 'samesite=("none" if COOKIE_SECURE else "lax")'
    if new_expr in t:
        return t
    return t.replace('samesite="none"', new_expr)
patch("src/integrations/seasonarr/api/routers.py", p_cookie_samesite)

# --- 5. dashboard endpoints degrade to empty instead of HTTP 500 in native mode
#        (no Docker daemon, no lm-sensors, no domains configured) — otherwise the
#        frontend's loadContainers() throws on the first fetch and never reaches
#        the /docker/stats call, so every perf gauge stays at 0. ----------------
def p_docker_containers(t):
    old = ('    except subprocess.CalledProcessError as e:\n'
           '        raise HTTPException(status_code=500, detail=f"Erreur docker: {e.stderr.strip()}")')
    if old not in t:
        return t
    new = ('    except (subprocess.CalledProcessError, FileNotFoundError):  ' + MARK + '  # pas de Docker -> liste vide\n'
           '        return []')
    return t.replace(old, new, 1)
patch("src/routers/secure/docker.py", p_docker_containers)

def p_docker_sensors(t):
    if MARK + "  # psutil macOS" in t:
        return t
    t = t.replace('temps = psutil.sensors_temperatures(fahrenheit=False)',
                  'temps = getattr(psutil, "sensors_temperatures", lambda **_: {})(fahrenheit=False)  ' + MARK + "  # psutil macOS", 1)
    t = t.replace('fans = psutil.sensors_fans()',
                  'fans = getattr(psutil, "sensors_fans", lambda: {})()', 1)
    return t
patch("src/routers/secure/docker.py", p_docker_sensors)

def p_domains(t):
    if 'return {}  ' + MARK in t:
        return t
    return (t
        .replace('raise HTTPException(status_code=500, detail="\'utilisateur.domain\' manquant")',
                 'return {}  ' + MARK + '  # pas de domaines en mode natif', 1)
        .replace('raise HTTPException(status_code=500, detail="\'dossiers.domaine\' manquant")',
                 'return {}  ' + MARK, 1))
patch("src/routers/secure/script.py", p_domains)

if changed:
    print("   patched: " + ", ".join(changed))
else:
    print("   (already patched — nothing to do)")
PYEOF

echo -e " ${GREEN}* ssd-backend patché pour le mode natif${NC}"
