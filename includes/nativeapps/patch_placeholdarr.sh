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

# --- patch 6: episode playback — series-title fallback --------------------
# Tracearr's stream_started sends the EPISODE's tvdb/tmdb ids (from Plex), not
# the show's. Placeholdarr's _try_resolve_episode_from_catalog_ids only matched a
# Series by tvdb/sonarr id -> "unresolved_episode_playback_kind" -> no Sonarr
# search on TV placeholder plays. Add a series-title fallback and let a resolved
# Series/Episode row's ids override the payload's episode-level ids.
python3 - "${SRC}" <<'PYEOF'
import sys, pathlib, ast
ep = pathlib.Path(sys.argv[1]) / "services/source_of_truth/event_playback.py"
s = ep.read_text(encoding="utf-8")
if "_extract_series_title" not in s:
    s = s.replace(
        "def _extract_imdb_id(payload: dict[str, Any]) -> str | None:",
        "def _extract_series_title(payload: dict[str, Any]) -> str | None:\n"
        "    \"\"\"patch_placeholdarr: show title for an episode play (match a Series when the\n"
        "    webhook carries episode-level or no external ids).\"\"\"\n"
        "    if _extract_declared_media_type(payload) != 'episode':\n"
        "        return None\n"
        "    series = payload.get('series') if isinstance(payload.get('series'), dict) else {}\n"
        "    media = payload.get('media') if isinstance(payload.get('media'), dict) else {}\n"
        "    data = payload.get('data') if isinstance(payload.get('data'), dict) else {}\n"
        "    data_media = data.get('media') if isinstance(data.get('media'), dict) else {}\n"
        "    for value in (series.get('title'), series.get('name'), media.get('title'),\n"
        "                  data_media.get('title'), payload.get('grandparentTitle'),\n"
        "                  payload.get('showTitle'), data_media.get('grandparentTitle')):\n"
        "        if isinstance(value, str) and value.strip():\n"
        "            return value.strip()\n"
        "    return None\n\n\n"
        "def _extract_imdb_id(payload: dict[str, Any]) -> str | None:", 1)

    s = s.replace(
        "    season_number: int | None,\n"
        "    episode_number: int | None,\n"
        ") -> dict[str, Any] | None:\n"
        "    if season_number is None or episode_number is None:\n"
        "        return None\n"
        "    if tvdb_id is None and sonarr_series_id is None:\n"
        "        return None\n"
        "    q = (\n"
        "        session.query(Episode)\n"
        "        .join(Season, Episode.season_id == Season.id)\n"
        "        .join(Series, Season.series_id == Series.id)\n"
        "        .filter(\n"
        "            Episode.is_deleted == False,  # noqa: E712\n"
        "            Series.is_deleted == False,  # noqa: E712\n"
        "            Season.season_number == season_number,\n"
        "            Episode.episode_number == episode_number,\n"
        "        )\n"
        "    )\n"
        "    if tvdb_id is not None:\n"
        "        q = q.filter(Series.tvdbid == int(tvdb_id))\n"
        "    else:\n"
        "        q = q.filter(Series.sonarrid == int(sonarr_series_id))\n"
        "    rows = q.all()\n"
        "    if not rows:\n"
        "        return None\n",
        "    season_number: int | None,\n"
        "    episode_number: int | None,\n"
        "    series_title: str | None = None,\n"
        ") -> dict[str, Any] | None:\n"
        "    if season_number is None or episode_number is None:\n"
        "        return None\n"
        "    if tvdb_id is None and sonarr_series_id is None and not series_title:\n"
        "        return None\n\n"
        "    def _base_q():\n"
        "        return (\n"
        "            session.query(Episode)\n"
        "            .join(Season, Episode.season_id == Season.id)\n"
        "            .join(Series, Season.series_id == Series.id)\n"
        "            .filter(\n"
        "                Episode.is_deleted == False,  # noqa: E712\n"
        "                Series.is_deleted == False,  # noqa: E712\n"
        "                Season.season_number == season_number,\n"
        "                Episode.episode_number == episode_number,\n"
        "            )\n"
        "        )\n\n"
        "    q = _base_q()\n"
        "    if tvdb_id is not None:\n"
        "        q = q.filter(Series.tvdbid == int(tvdb_id))\n"
        "    elif sonarr_series_id is not None:\n"
        "        q = q.filter(Series.sonarrid == int(sonarr_series_id))\n"
        "    else:\n"
        "        q = q.filter(Series.title.ilike(str(series_title).strip()))\n"
        "    rows = q.all()\n"
        "    if not rows and series_title and (tvdb_id is not None or sonarr_series_id is not None):\n"
        "        rows = _base_q().filter(Series.title.ilike(str(series_title).strip())).all()\n"
        "    if not rows:\n"
        "        return None\n", 1)

    s = s.replace(
        "    episode_number: int | None,\n"
        "    declared_media_type: str | None,\n"
        ") -> dict[str, Any]:\n"
        "    \"\"\"When path equality fails (Docker / different roots), resolve row + playback_kind from catalog IDs.\"\"\"\n"
        "    pk = str(path_info.get('playback_kind') or 'unknown')\n"
        "    if pk not in ('unknown', '', 'none', 'None'):\n"
        "        return path_info\n"
        "    merged = dict(path_info)\n\n"
        "    episode_first = declared_media_type == 'episode' or (\n"
        "        season_number is not None and episode_number is not None and (tvdb_id is not None or sonarr_series_id is not None)\n"
        "    )\n"
        "    if episode_first:\n"
        "        cat = _try_resolve_episode_from_catalog_ids(\n"
        "            session,\n"
        "            tvdb_id=tvdb_id,\n"
        "            sonarr_series_id=sonarr_series_id,\n"
        "            season_number=season_number,\n"
        "            episode_number=episode_number,\n"
        "        )\n",
        "    episode_number: int | None,\n"
        "    declared_media_type: str | None,\n"
        "    series_title: str | None = None,\n"
        ") -> dict[str, Any]:\n"
        "    \"\"\"When path equality fails (Docker / different roots), resolve row + playback_kind from catalog IDs.\"\"\"\n"
        "    pk = str(path_info.get('playback_kind') or 'unknown')\n"
        "    if pk not in ('unknown', '', 'none', 'None'):\n"
        "        return path_info\n"
        "    merged = dict(path_info)\n\n"
        "    episode_first = declared_media_type == 'episode' or (\n"
        "        season_number is not None and episode_number is not None\n"
        "        and (tvdb_id is not None or sonarr_series_id is not None or bool(series_title))\n"
        "    )\n"
        "    if episode_first:\n"
        "        cat = _try_resolve_episode_from_catalog_ids(\n"
        "            session,\n"
        "            tvdb_id=tvdb_id,\n"
        "            sonarr_series_id=sonarr_series_id,\n"
        "            season_number=season_number,\n"
        "            episode_number=episode_number,\n"
        "            series_title=series_title,\n"
        "        )\n", 1)

    s = s.replace(
        "    declared_media_type = _extract_declared_media_type(payload)\n"
        "    path_info = _resolve_media_from_path(session, file_path)\n"
        "    path_info = _merge_path_info_with_catalog_ids(\n"
        "        session,\n"
        "        path_info,\n"
        "        tmdb_id=tmdb_id,\n"
        "        tvdb_id=tvdb_id,\n"
        "        imdb_id=imdb_id,\n"
        "        sonarr_series_id=sonarr_series_id,\n"
        "        season_number=season_number,\n"
        "        episode_number=episode_number,\n"
        "        declared_media_type=declared_media_type,\n"
        "    )\n\n"
        "    if tmdb_id is None and path_info.get('tmdb_id') is not None:\n"
        "        tmdb_id = int(path_info['tmdb_id'])\n"
        "    if tvdb_id is None and path_info.get('tvdb_id') is not None:\n"
        "        tvdb_id = int(path_info['tvdb_id'])\n",
        "    declared_media_type = _extract_declared_media_type(payload)\n"
        "    series_title = _extract_series_title(payload)\n"
        "    path_info = _resolve_media_from_path(session, file_path)\n"
        "    path_info = _merge_path_info_with_catalog_ids(\n"
        "        session,\n"
        "        path_info,\n"
        "        tmdb_id=tmdb_id,\n"
        "        tvdb_id=tvdb_id,\n"
        "        imdb_id=imdb_id,\n"
        "        sonarr_series_id=sonarr_series_id,\n"
        "        season_number=season_number,\n"
        "        episode_number=episode_number,\n"
        "        declared_media_type=declared_media_type,\n"
        "        series_title=series_title,\n"
        "    )\n\n"
        "    _resolved_row = path_info.get('series_id') is not None or path_info.get('movie_id') is not None\n"
        "    if path_info.get('tmdb_id') is not None and (tmdb_id is None or _resolved_row):\n"
        "        tmdb_id = int(path_info['tmdb_id'])\n"
        "    if path_info.get('tvdb_id') is not None and (tvdb_id is None or _resolved_row):\n"
        "        tvdb_id = int(path_info['tvdb_id'])\n", 1)

    ast.parse(s)
    ep.write_text(s, encoding="utf-8")
    print(" * event_playback.py: episode series-title fallback")
PYEOF
say "patch 6 (episode series-title fallback) applied"

# --- patch 7: French episode titles/overviews + genres -------------------
# patch 4's _localize_metadata only re-fetches series/movie title+overview+poster
# from TMDB. Episode titles/overviews came straight from Sonarr (English, no
# metadata-language option), and genres were never localised. Add a per-episode
# TMDB re-fetch (_localize_episode) and make _localize_metadata also return
# localised genres.
python3 - "${SRC}" <<'PYEOF'
import sys, pathlib, ast
sr = pathlib.Path(sys.argv[1]) / "services/source_of_truth/sync_runner.py"
s = sr.read_text(encoding="utf-8")
if "_localize_episode" not in s:
    s = s.replace(
        "def _localize_metadata(kind, tmdbid, title, overview, poster):",
        "def _localize_metadata(kind, tmdbid, title, overview, poster, genres=None):", 1)
    s = s.replace(
        "    if not lang or tmdbid <= 0 or not getattr(settings, \"TMDB_API_KEY\", None):\n"
        "        return title, overview, poster\n",
        "    if not lang or tmdbid <= 0 or not getattr(settings, \"TMDB_API_KEY\", None):\n"
        "        return title, overview, poster, genres\n", 1)
    s = s.replace(
        "    pp = str(data.get(\"poster_path\") or \"\").strip()\n"
        "    return (t or title), (o or overview), (\n"
        "        f\"https://image.tmdb.org/t/p/original{pp}\" if pp else poster\n"
        "    )\n",
        "    pp = str(data.get(\"poster_path\") or \"\").strip()\n"
        "    g = [x.get(\"name\") for x in (data.get(\"genres\") or []) if isinstance(x, dict) and x.get(\"name\")]\n"
        "    return (t or title), (o or overview), (\n"
        "        f\"https://image.tmdb.org/t/p/original{pp}\" if pp else poster\n"
        "    ), (g or genres)\n\n\n"
        "_TMDB_EP_LOC_CACHE: dict = {}\n\n\n"
        "def _localize_episode(series_tmdbid, season_num, ep_num, title, overview):\n"
        "    \"\"\"TMDB re-fetch of an episode's name + overview in PLACEHOLDER_METADATA_LANGUAGE.\"\"\"\n"
        "    lang = str(getattr(settings, \"PLACEHOLDER_METADATA_LANGUAGE\", \"\") or \"\").strip()\n"
        "    try:\n"
        "        series_tmdbid = int(series_tmdbid or 0)\n"
        "        season_num = int(season_num)\n"
        "        ep_num = int(ep_num or 0)\n"
        "    except Exception:\n"
        "        return title, overview\n"
        "    if (not lang or series_tmdbid <= 0 or season_num < 0 or ep_num <= 0\n"
        "            or not getattr(settings, \"TMDB_API_KEY\", None)):\n"
        "        return title, overview\n"
        "    ck = (series_tmdbid, season_num, ep_num, lang)\n"
        "    data = _TMDB_EP_LOC_CACHE.get(ck)\n"
        "    if data is None:\n"
        "        try:\n"
        "            from services import tmdb_client\n"
        "            data = tmdb_client._request(\n"
        "                f\"/tv/{series_tmdbid}/season/{season_num}/episode/{ep_num}\",\n"
        "                {\"language\": lang},\n"
        "            ) or {}\n"
        "        except Exception:\n"
        "            data = {}\n"
        "        _TMDB_EP_LOC_CACHE[ck] = data\n"
        "    t = str(data.get(\"name\") or \"\").strip()\n"
        "    o = str(data.get(\"overview\") or \"\").strip()\n"
        "    return (t or title), (o or overview)\n", 1)
    # movie call site
    s = s.replace(
        "    title, _ph_ov, _ph_poster = _localize_metadata('movie', tmdbid, title, entry.get('overview'), _extract_poster_url(entry))",
        "    title, _ph_ov, _ph_poster, _ph_genres = _localize_metadata('movie', tmdbid, title, entry.get('overview'), _extract_poster_url(entry), entry.get('genres') if isinstance(entry.get('genres'), list) else None)", 1)
    s = s.replace(
        "        'radarr_genres': entry.get('genres') if isinstance(entry.get('genres'), list) else None,",
        "        'radarr_genres': _ph_genres,", 1)
    # series call site
    s = s.replace(
        "    title, _ph_ov, _ph_poster = _localize_metadata('tv', entry.get('tmdbId'), title, entry.get('overview'), _extract_poster_url(entry))",
        "    title, _ph_ov, _ph_poster, _ph_genres = _localize_metadata('tv', entry.get('tmdbId'), title, entry.get('overview'), _extract_poster_url(entry), entry.get('genres') if isinstance(entry.get('genres'), list) else None)", 1)
    s = s.replace(
        "        'sonarr_genres': entry.get('genres') if isinstance(entry.get('genres'), list) else None,",
        "        'sonarr_genres': _ph_genres,", 1)
    # episode fields
    s = s.replace(
        "    episode_sonarrpath = os.path.dirname(sonarr_filepath) if sonarr_filepath else season_folder\n"
        "    return {\n"
        "        'season_id': season.id,\n"
        "        'episode_number': int(entry.get('episodeNumber') or 0),\n"
        "        'title': entry.get('title') or f\"Episode {int(entry.get('episodeNumber') or 0)}\",\n",
        "    episode_sonarrpath = os.path.dirname(sonarr_filepath) if sonarr_filepath else season_folder\n"
        "    _ep_title, _ep_ov = _localize_episode(\n"
        "        getattr(series, 'sonarr_tmdbid', None),\n"
        "        getattr(season, 'season_number', None),\n"
        "        entry.get('episodeNumber'),\n"
        "        entry.get('title'),\n"
        "        entry.get('overview'),\n"
        "    )\n"
        "    return {\n"
        "        'season_id': season.id,\n"
        "        'episode_number': int(entry.get('episodeNumber') or 0),\n"
        "        'title': _ep_title or f\"Episode {int(entry.get('episodeNumber') or 0)}\",\n", 1)
    s = s.replace(
        "        'sonarr_episode_overview': entry.get('overview'),",
        "        'sonarr_episode_overview': _ep_ov,", 1)
    if s.count("_ph_genres") < 4 or "_localize_episode(" not in s or "'sonarr_episode_overview': _ep_ov," not in s:
        raise SystemExit("patch_placeholdarr patch 7: sync_runner.py call sites not all found - upstream changed")
    ast.parse(s)
    sr.write_text(s, encoding="utf-8")
    print(" * sync_runner.py: FR episode titles/overviews + localised genres")
PYEOF
say "patch 7 (French episodes + genres) applied"

# --- patch 8: episode still in NFO + plain .jpg sidecar ------------------
# Placeholder episodes showed a grey frame from the dummy .mp4 instead of a
# still. The episode NFO carried no <thumb>, and the still sidecar was only
# written as <basename>-thumb.jpg (Kodi convention). Emit <thumb>URL</thumb>
# and also copy the still to <basename>.jpg (Plex/Jellyfin convention).
# (Plex's own tv.plex.agents.nfo.series still ignores both for episodes — this
#  helps Jellyfin/Emby + a direct API push if one is added later.)
python3 - "${SRC}" <<'PYEOF'
import sys, pathlib
src = pathlib.Path(sys.argv[1])
pl = src / "services/placeholders.py"
p = pl.read_text(encoding="utf-8")
if '<thumb>{escape(_ep_still)}</thumb>' not in p:
    OLD = ("        lines.append(f\"  <plot>{plot}</plot>\")\n"
           "    else:\n"
           "        lines.append(f\"  <plot>{escape(project_summary('', status, runtime_minutes=rm, media_context=media_ctx))}</plot>\")\n"
           "    if tvdbid:\n")
    NEW = ("        lines.append(f\"  <plot>{plot}</plot>\")\n"
           "    else:\n"
           "        lines.append(f\"  <plot>{escape(project_summary('', status, runtime_minutes=rm, media_context=media_ctx))}</plot>\")\n"
           "    _ep_still = str(getattr(episode, \"sonarr_episode_still\", \"\") or \"\").strip()\n"
           "    if _ep_still:\n"
           "        lines.append(f\"  <thumb>{escape(_ep_still)}</thumb>\")\n"
           "    if tvdbid:\n")
    if OLD not in p:
        raise SystemExit("patch_placeholdarr patch 8: _episode_nfo_xml plot block not found - upstream changed")
    pl.write_text(p.replace(OLD, NEW, 1), encoding="utf-8")
    print(" * placeholders.py: episode NFO <thumb>")

pa = src / "services/placeholder_poster_art.py"
a = pa.read_text(encoding="utf-8")
if "Plex/Kodi/Jellyfin\n" not in a and '_plain = os.path.splitext' not in a:
    OLD_A = ("        result.local_art.thumb = thumb_name\n"
             "        result.wrote_any = True\n"
             "        result.art_counts[\"episode\"] = 1\n"
             "    return result\n")
    NEW_A = ("        result.local_art.thumb = thumb_name\n"
             "        result.wrote_any = True\n"
             "        result.art_counts[\"episode\"] = 1\n"
             "        try:\n"
             "            _plain = os.path.splitext(os.path.basename(media_path))[0] + \".jpg\"\n"
             "            _plain_path = os.path.join(folder, _plain)\n"
             "            if os.path.isfile(thumb_path):\n"
             "                import shutil as _sh\n"
             "                _sh.copyfile(thumb_path, _plain_path)\n"
             "        except OSError:\n"
             "            pass\n"
             "    return result\n")
    if OLD_A not in a:
        raise SystemExit("patch_placeholdarr patch 8: ensure_episode_still_art tail not found - upstream changed")
    pa.write_text(a.replace(OLD_A, NEW_A, 1), encoding="utf-8")
    print(" * placeholder_poster_art.py: <basename>.jpg episode still sidecar")
PYEOF
say "patch 8 (episode still nfo/jpg) applied"

# --- seed appdata -------------------------------------------------------
mkdir -p "${DATA}/config"
for f in dummy.mp4 coming_soon_dummy.mp4; do
  [ -f "${SRC}/${f}" ] && [ ! -f "${DATA}/config/${f}" ] && cp "${SRC}/${f}" "${DATA}/config/${f}"
done
# carry over the auth session secret from the pre-nativeapp install, if present
OLD="/Users/haldir/placeholdarr/config/.auth_session_secret"
[ -f "${OLD}" ] && [ ! -f "${DATA}/config/.auth_session_secret" ] && cp "${OLD}" "${DATA}/config/.auth_session_secret"
say "appdata seeded at ${DATA}/config"
