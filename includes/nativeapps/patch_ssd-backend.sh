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

# --- native service layer: presents the com.ssd.* LaunchAgents to docker.py as
#     if they were containers (list + start/stop/restart via launchctl). --------
mkdir -p "${SRC}/src/routers/secure"
cat > "${SRC}/src/routers/secure/_native_svc.py" <<'NATIVEEOF'
"""macOS-native service layer for the ssdv2 fork (includes/nativeapps/).

docker.py imports this to list / act on the com.ssd.* LaunchAgents instead of
Docker containers when running in native mode.  [ssd-native]
"""
import glob
import os
import subprocess

SSD_NATIVE = (
    os.getenv("SSD_NATIVE", "").strip().lower() in ("1", "true", "yes")
    or os.uname().sysname == "Darwin"
)

_LA_DIR = os.path.expanduser("~/Library/LaunchAgents")
_PREFIX = "com.ssd."
_UID = os.getuid()

try:
    import psutil
except Exception:  # pragma: no cover
    psutil = None

_procs = {}  # pid -> psutil.Process (kept so cpu_percent() has a delta reference)


def _launchctl_pids():
    out = {}
    try:
        r = subprocess.run(["launchctl", "list"], capture_output=True, text=True, timeout=5)
        for line in r.stdout.splitlines()[1:]:
            parts = line.split("\t")
            if len(parts) >= 3 and parts[2].startswith(_PREFIX):
                pid = parts[0].strip()
                out[parts[2].strip()] = int(pid) if pid.lstrip("-").isdigit() and pid != "-" else None
    except Exception:
        pass
    return out


def _cpu_mem(pid):
    if not psutil or not pid:
        return "N/A", "N/A"
    try:
        p = _procs.get(pid)
        if p is None or not p.is_running():
            p = psutil.Process(pid)
            _procs[pid] = p
            p.cpu_percent(None)
        return f"{p.cpu_percent(None):.1f}%", f"{p.memory_percent():.1f}%"
    except Exception:
        return "N/A", "N/A"


def native_services():
    pids = _launchctl_pids()
    out = []
    for plist in sorted(glob.glob(os.path.join(_LA_DIR, _PREFIX + "*.plist"))):
        label = os.path.basename(plist)[:-6]
        name = label[len(_PREFIX):]
        pid = pids.get(label)
        if pid:
            cpu, mem = _cpu_mem(pid)
            status = f"Up (pid {pid})"
        else:
            cpu = mem = "-"
            status = "Exited"
        out.append({"id": name, "name": name, "status": status, "cpu": cpu, "mem": mem})
    return out


def native_action(name, action):
    from fastapi import HTTPException

    if not name or action not in ("start", "stop", "restart"):
        raise HTTPException(status_code=400, detail="Paramètres invalides")
    label = _PREFIX + name
    plist = os.path.join(_LA_DIR, label + ".plist")
    dom = f"gui/{_UID}"
    try:
        if action == "restart":
            cmd = ["launchctl", "kickstart", "-k", f"{dom}/{label}"]
        elif action == "stop":
            cmd = ["launchctl", "bootout", f"{dom}/{label}"]
        else:
            cmd = ["launchctl", "bootstrap", dom, plist]
        subprocess.run(cmd, check=True, capture_output=True, text=True)
        return {"message": f"{name} {action}ed"}
    except subprocess.CalledProcessError as e:
        raise HTTPException(status_code=500, detail=f"launchctl {action}: {(e.stderr or '').strip()}")
NATIVEEOF
echo -e " ${GREEN}* _native_svc.py déposé${NC}"

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

# --- 6. docker.py: in native mode the com.ssd.* LaunchAgents ARE the services —
#        route list + start/stop/restart through _native_svc; disk usage of $HOME
#        (macOS "/" is a tiny read-only volume). ------------------------------
def p_docker_native_list(t):
    anchor = ('def list_containers():\n'
              '    """Liste les conteneurs Docker avec CPU/MEM si dispo"""\n'
              '    global _last_containers, _last_containers_time\n')
    if anchor not in t or (anchor + "    from routers.secure._native_svc") in t:
        return t
    return t.replace(anchor, anchor +
        "    from routers.secure._native_svc import SSD_NATIVE, native_services  " + MARK + "\n"
        "    if SSD_NATIVE:\n"
        "        return native_services()\n", 1)
patch("src/routers/secure/docker.py", p_docker_native_list)

def p_docker_native_action(t):
    anchor = 'def docker_action(data: dict):\n    container_id = data.get("id")\n'
    if anchor not in t or "native_action" in t:
        return t
    return t.replace(anchor,
        'def docker_action(data: dict):\n'
        '    from routers.secure._native_svc import SSD_NATIVE, native_action  ' + MARK + '\n'
        '    if SSD_NATIVE:\n'
        '        return native_action(data.get("id"), data.get("action"))\n'
        '    container_id = data.get("id")\n', 1)
patch("src/routers/secure/docker.py", p_docker_native_action)

def p_docker_disk(t):
    old = 'disk = psutil.disk_usage("/")'
    if old not in t:
        return t
    return t.replace(old, 'disk = psutil.disk_usage(os.path.expanduser("~"))  ' + MARK, 1)
patch("src/routers/secure/docker.py", p_docker_disk)

# --- 7. version.py: read the frontends' version.json straight off disk (native
#        install) instead of `docker exec <container> cat`. --------------------
def p_version(t):
    anchor = 'def _read_version_from_container(container_name: str, path: str, label: str) -> str:\n'
    if anchor not in t or "os.path.isfile(path)" in t:
        return t
    return t.replace(anchor, anchor +
        '    if os.path.isfile(path):  ' + MARK + '  # fichier local (install natif)\n'
        '        return _read_version_file(Path(path), label)\n', 1)
patch("src/version.py", p_version)

# --- 8. script.py check-file: the native ssdv2 platform is "installed" by
#        definition (this fork IS running). --------------------------------
def p_checkfile(t):
    anchor = 'async def check_file():\n'
    if anchor not in t or 'SSD_NATIVE' in t:
        return t
    return t.replace(anchor, anchor +
        '    if os.getenv("SSD_NATIVE"):  ' + MARK + '\n'
        '        return {"exists": True}\n', 1)
patch("src/routers/secure/script.py", p_checkfile)

if changed:
    print("   patched: " + ", ".join(changed))
else:
    print("   (already patched — nothing to do)")
PYEOF

echo -e " ${GREEN}* ssd-backend patché pour le mode natif${NC}"
