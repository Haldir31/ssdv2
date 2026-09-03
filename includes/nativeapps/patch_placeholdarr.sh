#!/bin/bash
###############################################################################
# post_fetch hook for the placeholdarr native app (see vars/placeholdarr.yml).
#
# Re-applies the two local patches needed on a case-insensitive macOS FS + a
# non-Docker layout, and seeds the appdata dir. Idempotent — safe to re-run
# after every `git reset --hard origin/main`.
#
#   1. frontend case-collision: frontend/src/TmdbAttribution.tsx (component) and
#      frontend/src/tmdbAttribution.ts (utils) differ only by the case of the
#      first letter -> collide on disk -> vite build fails. Rename the utils
#      module to tmdbNotice.ts and fix the one import.
#   2. services/placeholders.py hardcodes "/config" (read-only at the macOS FS
#      root) -> derive it from settings.APPDATA_PATH.
#
# Usage: patch_placeholdarr.sh <src_dir> <data_dir>
###############################################################################
set -euo pipefail

SRC="${1:?usage: patch_placeholdarr.sh <src_dir> <data_dir>}"
DATA="${2:?usage: patch_placeholdarr.sh <src_dir> <data_dir>}"
GREEN="${GREEN:-\033[0;32m}"; YELLOW="${YELLOW:-\033[0;33m}"; NC="${NC:-\033[0m}"
say() { echo -e " ${GREEN}* [patch_placeholdarr]${NC} $*"; }

cd "${SRC}"

# --- patch 1: frontend case-collision -------------------------------------
if [ -f frontend/src/tmdbAttribution.ts ]; then
  cp frontend/src/tmdbAttribution.ts frontend/src/tmdbNotice.ts
  rm -f frontend/src/tmdbAttribution.ts
  say "renamed frontend/src/tmdbAttribution.ts -> tmdbNotice.ts"
fi
if grep -q '"./tmdbAttribution"' frontend/src/TmdbAttribution.tsx 2>/dev/null; then
  sed -i '' 's#"./tmdbAttribution"#"./tmdbNotice"#' frontend/src/TmdbAttribution.tsx
  say "fixed import in TmdbAttribution.tsx"
fi

# --- patch 2: services/placeholders.py /config hardcode ------------------
PF=services/placeholders.py
if ! grep -q '_APPDATA_DIR' "${PF}"; then
  # insert the derivation right after the settings import
  perl -0pi -e 's/(from core\.config import settings\n)/$1_APPDATA_DIR = (str(getattr(settings, "APPDATA_PATH", "") or "").strip() or "\/config")\n/' "${PF}"
  # swap the hardcoded /config paths
  perl -0pi -e 's{"/config/coming_soon_dummy\.mp4"}{os.path.join(_APPDATA_DIR, "coming_soon_dummy.mp4")}g;
                 s{"/config/dummy\.mp4"}{os.path.join(_APPDATA_DIR, "dummy.mp4")}g;
                 s{^(\s*)config_dir = "/config"}{$1config_dir = _APPDATA_DIR}gm;' "${PF}"
  say "patched ${PF} (/config -> APPDATA_PATH)"
fi

# --- patch 3: derived library subfolders 'movies'/'tv' -> 'Films'/'Séries' -
# (user runs a combined library over the existing ~/Medias/{Films,Séries} dirs)
if grep -q "library_root, 'movies'" core/config.py 2>/dev/null; then
  perl -CSD -0pi -e "s/os\\.path\\.join\\(library_root, 'movies'\\)/os.path.join(library_root, 'Films')/g;
                     s/os\\.path\\.join\\(library_root, 'tv'\\)/os.path.join(library_root, 'S\\x{e9}ries')/g" core/config.py
  say "core/config.py: movies/tv -> Films/Séries"
fi
if grep -q 'root, "movies"' services/app_config.py 2>/dev/null; then
  perl -CSD -0pi -e 's/os\\.path\\.join\\(root, "movies"\\)/os.path.join(root, "Films")/g;
                     s/os\\.path\\.join\\(root, "tv"\\)/os.path.join(root, "S\\x{e9}ries")/g;
                     s/for folder_name in \\("movies", "tv"\\):/for folder_name in ("Films", "S\\x{e9}ries"):/g' services/app_config.py
  say "services/app_config.py: movies/tv -> Films/Séries"
fi

# --- seed appdata -------------------------------------------------------
mkdir -p "${DATA}/config"
for f in dummy.mp4 coming_soon_dummy.mp4; do
  [ -f "${SRC}/${f}" ] && [ ! -f "${DATA}/config/${f}" ] && cp "${SRC}/${f}" "${DATA}/config/${f}"
done
# carry over the auth session secret from the pre-nativeapp install, if present
OLD="/Users/haldir/placeholdarr/config/.auth_session_secret"
[ -f "${OLD}" ] && [ ! -f "${DATA}/config/.auth_session_secret" ] && cp "${OLD}" "${DATA}/config/.auth_session_secret"
say "appdata seeded at ${DATA}/config"
