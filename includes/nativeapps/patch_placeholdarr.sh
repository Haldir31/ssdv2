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

# --- patch 4: localise placeholder .nfo + posters via TMDB --------------
# New setting PLACEHOLDER_METADATA_LANGUAGE (BCP-47, e.g. fr-FR): when set +
# TMDB_API_KEY present, re-fetch title/overview/poster from TMDB in that language
# in sync_runner, so placeholders are localised whatever Radarr/Sonarr return.
python3 - "${SRC}" <<'PYEOF'
import sys, pathlib
src = pathlib.Path(sys.argv[1])

cfg = src / "core/config.py"
c = cfg.read_text(encoding="utf-8")
if "PLACEHOLDER_METADATA_LANGUAGE" not in c:
    c = c.replace(
        "    MOVIE_LIBRARY_4K_FOLDER: str = \"\"\n    TV_LIBRARY_4K_FOLDER: str = \"\"\n",
        "    MOVIE_LIBRARY_4K_FOLDER: str = \"\"\n    TV_LIBRARY_4K_FOLDER: str = \"\"\n"
        "    PLACEHOLDER_METADATA_LANGUAGE: str = \"\"\n", 1)
    cfg.write_text(c, encoding="utf-8")
    print(" * core/config.py: added PLACEHOLDER_METADATA_LANGUAGE")

sr = src / "services/source_of_truth/sync_runner.py"
s = sr.read_text(encoding="utf-8")
if "_localize_metadata" not in s:
    HELPER = '''
_TMDB_LOC_CACHE: dict = {}


def _localize_metadata(kind, tmdbid, title, overview, poster):
    """TMDB re-fetch of title/overview/poster in PLACEHOLDER_METADATA_LANGUAGE.
    No-op unless the setting + a TMDB key exist."""
    lang = str(getattr(settings, "PLACEHOLDER_METADATA_LANGUAGE", "") or "").strip()
    try:
        tmdbid = int(tmdbid or 0)
    except Exception:
        tmdbid = 0
    if not lang or tmdbid <= 0 or not getattr(settings, "TMDB_API_KEY", None):
        return title, overview, poster
    ck = (kind, tmdbid, lang)
    data = _TMDB_LOC_CACHE.get(ck)
    if data is None:
        try:
            from services import tmdb_client
            path = f"/movie/{tmdbid}" if kind == "movie" else f"/tv/{tmdbid}"
            data = tmdb_client._request(path, {"language": lang}) or {}
        except Exception:
            data = {}
        _TMDB_LOC_CACHE[ck] = data
    t = str(data.get("title") or data.get("name") or "").strip()
    o = str(data.get("overview") or "").strip()
    pp = str(data.get("poster_path") or "").strip()
    return (t or title), (o or overview), (
        f"https://image.tmdb.org/t/p/original{pp}" if pp else poster
    )

'''
    s = s.replace("def _movie_fields(entry: Dict, is_4k: bool, instance_key: str) -> Dict:",
                  HELPER + "\ndef _movie_fields(entry: Dict, is_4k: bool, instance_key: str) -> Dict:", 1)
    s = s.replace(
        "    instance_id, resolved_instance_key = _resolve_instance_identity('radarr', instance_key, is_4k)\n",
        "    instance_id, resolved_instance_key = _resolve_instance_identity('radarr', instance_key, is_4k)\n"
        "    title, _ph_ov, _ph_poster = _localize_metadata('movie', tmdbid, title, entry.get('overview'), _extract_poster_url(entry))\n", 1)
    s = s.replace(
        "        'remote_poster': _extract_poster_url(entry),\n        'remote_fanart': _extract_image_url(entry, ('fanart', 'background')),\n        'radarr_runtime':",
        "        'remote_poster': _ph_poster,\n        'remote_fanart': _extract_image_url(entry, ('fanart', 'background')),\n        'radarr_runtime':", 1)
    s = s.replace("        'radarr_overview': entry.get('overview'),\n", "        'radarr_overview': _ph_ov,\n", 1)
    s = s.replace(
        "    placeholder_folder = _placeholder_series_folder(entry, title=title, year=year, tvdbid=tvdbid, is_4k=is_4k)\n    return {",
        "    placeholder_folder = _placeholder_series_folder(entry, title=title, year=year, tvdbid=tvdbid, is_4k=is_4k)\n"
        "    title, _ph_ov, _ph_poster = _localize_metadata('tv', entry.get('tmdbId'), title, entry.get('overview'), _extract_poster_url(entry))\n    return {", 1)
    s = s.replace("        'sonarr_series_overview': entry.get('overview'),\n", "        'sonarr_series_overview': _ph_ov,\n", 1)
    s = s.replace(
        "        'imdbid': entry.get('imdbId'),\n        'remote_poster': _extract_poster_url(entry),\n        'remote_fanart': _extract_image_url(entry, ('fanart', 'background')),\n        'remote_banner':",
        "        'imdbid': entry.get('imdbId'),\n        'remote_poster': _ph_poster,\n        'remote_fanart': _extract_image_url(entry, ('fanart', 'background')),\n        'remote_banner':", 1)
    import ast; ast.parse(s)
    sr.write_text(s, encoding="utf-8")
    print(" * sync_runner.py: added TMDB metadata localiser")
PYEOF
say "patch 4 (TMDB localisation) applied"

# --- patch 5: byte-unique placeholder files ----------------------------
# Every placeholder .mp4 is a hardlink/copy of ONE shared dummy -> byte
# identical. Plex's scanner does content-hash "part rename detection" and
# collapses all identical-hash files into a single library item (only the
# last-scanned title survives). Force a copy + append a unique tail keyed
# by the file path so each placeholder has a distinct hash. Trailing bytes
# after the last MP4 atom are ignored by players and ffprobe.
python3 - "${SRC}" <<'PYEOF'
import sys, pathlib
pf = pathlib.Path(sys.argv[1]) / "services/placeholders.py"
s = pf.read_text(encoding="utf-8")
MARK = "# patch_placeholdarr: byte-unique placeholder"
if MARK not in s:
    OLD = (
        '    strategy = str(getattr(settings, "PLACEHOLDER_STRATEGY", "hardlink") or "hardlink").strip().lower()\n'
        '    if strategy == "hardlink":\n'
        '        try:\n'
        '            os.link(dummy_path, path)\n'
        '            os.utime(path, None)\n'
        '            _ensure_open_permissions(path)\n'
        '            return True\n'
        '        except OSError:\n'
        '            # Cross-device links can fail; copy is the safe fallback.\n'
        '            shutil.copy2(dummy_path, path)\n'
        '            os.utime(path, None)\n'
        '            _ensure_open_permissions(path)\n'
        '            return True\n'
        '\n'
        '    shutil.copy2(dummy_path, path)\n'
        '    os.utime(path, None)\n'
        '    _ensure_open_permissions(path)\n'
        '    return True\n'
    )
    NEW = (
        '    ' + MARK + ' (Plex hash-collision fix; hardlink strategy disabled)\n'
        '    import hashlib as _hl\n'
        '    shutil.copy2(dummy_path, path)\n'
        '    try:\n'
        '        with open(path, "ab") as _f:\n'
        '            _f.write(b"\\x00\\x00PLHDR" + _hl.sha1(os.fsencode(path)).digest())\n'
        '    except OSError:\n'
        '        pass\n'
        '    os.utime(path, None)\n'
        '    _ensure_open_permissions(path)\n'
        '    return True\n'
    )
    if OLD not in s:
        raise SystemExit("patch_placeholdarr patch 5: ensure_placeholder_file tail not found - upstream changed")
    pf.write_text(s.replace(OLD, NEW, 1), encoding="utf-8")
    print(" * placeholders.py: placeholder files are now byte-unique")
PYEOF
say "patch 5 (byte-unique placeholders) applied"

# --- seed appdata -------------------------------------------------------
mkdir -p "${DATA}/config"
for f in dummy.mp4 coming_soon_dummy.mp4; do
  [ -f "${SRC}/${f}" ] && [ ! -f "${DATA}/config/${f}" ] && cp "${SRC}/${f}" "${DATA}/config/${f}"
done
# carry over the auth session secret from the pre-nativeapp install, if present
OLD="/Users/haldir/placeholdarr/config/.auth_session_secret"
[ -f "${OLD}" ] && [ ! -f "${DATA}/config/.auth_session_secret" ] && cp "${OLD}" "${DATA}/config/.auth_session_secret"
say "appdata seeded at ${DATA}/config"
