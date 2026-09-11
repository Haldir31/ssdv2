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

# --- patch 8: strip ALL placeholder art / sidecar files -----------------
# User wants placeholder folders to hold ONLY the dummy .mp4 and let Plex's
# optimised official agents (tv.plex.agents.movie / .series) fetch every poster,
# still, fanart and metadata themselves. No-op the three low-level writers that
# produce poster.jpg / folder.jpg / seasonNN-poster.jpg / *-thumb.jpg /
# poster-grid.jpg / .poster-overlay.json. The dashboard falls back to the stored
# remote_poster TMDB URLs. (NFO already off via patch 9.)
python3 - "${SRC}" <<'PYEOF'
import sys, pathlib, ast
p = pathlib.Path(sys.argv[1]) / "services/placeholder_poster_art.py"
s = p.read_text(encoding="utf-8")
MARK = "# patch_placeholdarr: placeholder art/sidecars disabled"
if MARK not in s:
    repls = [
      ('def _write_art_file(\n    output_path: str,\n    source_url: str | None,\n    *,\n    mode: str,\n    landscape: bool,\n    meta_key: str,\n    source_kind: str = "",\n) -> bool:\n    url = _normalize_art_url(source_url)\n',
       'def _write_art_file(\n    output_path: str,\n    source_url: str | None,\n    *,\n    mode: str,\n    landscape: bool,\n    meta_key: str,\n    source_kind: str = "",\n) -> bool:\n    ' + MARK + '\n    return False\n    url = _normalize_art_url(source_url)\n'),
      ('def write_library_grid_poster(folder: str, source_url: str | None) -> bool:\n    """Write ``poster-grid.jpg`` (raw catalog art) beside composited ``poster.jpg``."""\n',
       'def write_library_grid_poster(folder: str, source_url: str | None) -> bool:\n    """Write ``poster-grid.jpg`` (raw catalog art) beside composited ``poster.jpg``."""\n    ' + MARK + '\n    return False\n'),
      ('def _publish_series_folder_poster(poster_path: str) -> None:\n    """Plex/Jellyfin often prefer folder.jpg for TV show posters in the series root."""\n',
       'def _publish_series_folder_poster(poster_path: str) -> None:\n    """Plex/Jellyfin often prefer folder.jpg for TV show posters in the series root."""\n    ' + MARK + '\n    return\n'),
    ]
    for old, new in repls:
        if old not in s:
            raise SystemExit("patch 8: art writer anchor not found - upstream changed")
        s = s.replace(old, new, 1)
    ast.parse(s)
    p.write_text(s, encoding="utf-8")
    print(" * placeholder_poster_art.py: all art / sidecar writers disabled")
PYEOF
say "patch 8 (no art / sidecars) applied"

# --- patch 9: disable placeholder .nfo creation -------------------------
# User runs Plex-only with the official agents (tv.plex.agents.movie/series),
# which ignore NFO entirely. PLACEHOLDER_CREATE_NFO is force-True by a validator
# so it can't be turned off in-app -> no-op the three writers. Nothing gates on
# NFO existence (materializer only reports a counter; cleanup markers use the DB
# + dummy-file name pattern).
python3 - "${SRC}" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]) / "services/placeholders.py"
s = p.read_text(encoding="utf-8")
MARK = "# patch_placeholdarr: NFO creation disabled"
if MARK not in s:
    OLD = ('def ensure_movie_nfo(media_path: str, movie: Any) -> bool:\n'
           '    return _atomic_write_text(nfo_sidecar_path(media_path), _movie_nfo_xml(movie))\n\n\n'
           'def ensure_episode_nfo(media_path: str, episode: Any, season: Any, series: Any) -> bool:\n'
           '    return _atomic_write_text(\n'
           '        nfo_sidecar_path(media_path),\n'
           '        _episode_nfo_xml(episode, season, series),\n'
           '    )\n')
    NEW = ('def ensure_movie_nfo(media_path: str, movie: Any) -> bool:\n'
           '    ' + MARK + ' (user request; Plex official agents ignore NFO)\n'
           '    return True\n\n\n'
           'def ensure_episode_nfo(media_path: str, episode: Any, season: Any, series: Any) -> bool:\n'
           '    ' + MARK + '\n'
           '    return True\n')
    if OLD not in s:
        raise SystemExit("patch 9: movie/episode nfo anchor not found - upstream changed")
    s = s.replace(OLD, NEW, 1)
    OLD2 = ('    nfo_path = os.path.join(target_folder, "tvshow.nfo")\n'
            '    return _atomic_write_text(nfo_path, _series_nfo_xml(series))\n')
    NEW2 = ('    ' + MARK + ' (skip tvshow.nfo write)\n'
            '    _ = target_folder\n'
            '    return True\n')
    if OLD2 not in s:
        raise SystemExit("patch 9: series nfo anchor not found - upstream changed")
    s = s.replace(OLD2, NEW2, 1)
    import ast; ast.parse(s)
    p.write_text(s, encoding="utf-8")
    print(" * placeholders.py: NFO creation disabled")
PYEOF
say "patch 9 (no NFO) applied"

# --- patch 10: clear Plex watched flag when the real file is imported ------
# The tiny (~4s) dummy: a few seconds of playback pushes Plex past its
# ~90%-of-duration watched threshold, and that flag then sticks on the real
# episode/movie after the swap. Fix: on import_grace finalize, call Plex
# /:/unscrobble for the item (uses the ratingKey placeholdarr already stores).
python3 - "$SRC" <<'PYEOF'
import sys, pathlib
src = pathlib.Path(sys.argv[1])
MARK = "# patch_placeholdarr: reset watched state after a real file is imported"

# 1) plex.py — append the unscrobble helper
p = src / "services/media_servers/plex.py"
s = p.read_text(encoding="utf-8")
if MARK not in s:
    s += '''

''' + MARK + ''' ---------
def set_plex_item_unwatched(rating_key: str | int) -> str:
    """Mark a Plex library item unwatched (clears watched flag + view offset)."""
    if not getattr(settings, "plex_enabled", False):
        return "skipped"
    key = str(rating_key or "").strip()
    if not key:
        return "skipped"
    plex_url, plex_token = _plex_base_and_token()
    if not plex_url or not plex_token:
        return "skipped"
    try:
        response = requests.get(
            f"{plex_url}/:/unscrobble",
            params={"identifier": "com.plexapp.plugins.library", "key": key},
            headers={"X-Plex-Token": plex_token},
            timeout=15,
        )
        response.raise_for_status()
        logger.info(f"Plex item marked unwatched after import rating_key={key}", extra={"emoji_type": "refresh"})
        return "ok"
    except Exception as ex:
        logger.warning(f"Plex unwatch failed rating_key={key}: {ex}", extra={"emoji_type": "warning"})
        return "failed"
'''
    import ast; ast.parse(s)
    p.write_text(s, encoding="utf-8")
    print(" * plex.py: set_plex_item_unwatched added")

# 2) import_grace.py — helper + 2 call sites
p = src / "services/source_of_truth/import_grace.py"
s = p.read_text(encoding="utf-8")
if MARK not in s:
    anchor = "from services.status_projection import projected_status_display\n"
    helper = anchor + '''

''' + MARK + '''
def _unmark_watched_after_import(row) -> None:
    if not bool(getattr(settings, "PLACEHOLDER_UNMARK_WATCHED_ON_IMPORT", True)):
        return
    rk = str(getattr(row, "plex_id", "") or getattr(row, "plex_dummy_id", "") or "").strip()
    if not rk:
        return
    try:
        from services.media_servers.plex import set_plex_item_unwatched
        set_plex_item_unwatched(rk)
    except Exception:
        pass
'''
    if anchor not in s:
        raise SystemExit("patch 10: import_grace anchor not found - upstream changed")
    s = s.replace(anchor, helper, 1)
    mv_old = "            movie_ref = session.query(Movie).filter(Movie.id == entity_id).first()\n"
    mv_new = mv_old + "            if movie_ref is not None:\n                _unmark_watched_after_import(movie_ref)\n"
    ep_old = "            if ctx:\n                ep, season, series = ctx\n"
    ep_new = "            if ctx:\n                ep, season, series = ctx\n                _unmark_watched_after_import(ep)\n"
    for o, n in ((mv_old, mv_new), (ep_old, ep_new)):
        if o not in s:
            raise SystemExit("patch 10: import_grace call-site not found - upstream changed")
        s = s.replace(o, n, 1)
    import ast; ast.parse(s)
    p.write_text(s, encoding="utf-8")
    print(" * import_grace.py: unmark-watched on finalize")

# 3) config.py — the toggle
p = src / "core/config.py"
s = p.read_text(encoding="utf-8")
if "PLACEHOLDER_UNMARK_WATCHED_ON_IMPORT" not in s:
    a = '    IMPORT_GRACE_ACCELERATED_STEP_SECONDS: int = int(os.getenv("IMPORT_GRACE_ACCELERATED_STEP_SECONDS", "5").split(\'#\')[0].strip())\n'
    if a not in s:
        raise SystemExit("patch 10: config.py anchor not found - upstream changed")
    s = s.replace(a, a + '    PLACEHOLDER_UNMARK_WATCHED_ON_IMPORT: bool = os.getenv("PLACEHOLDER_UNMARK_WATCHED_ON_IMPORT", "true").split(\'#\')[0].strip().lower() == "true"\n', 1)
    import ast; ast.parse(s)
    p.write_text(s, encoding="utf-8")
    print(" * config.py: PLACEHOLDER_UNMARK_WATCHED_ON_IMPORT toggle")
PYEOF
say "patch 10 (unmark watched on import) applied"

# --- patch 11: episode play — resolve localised-title shows via Plex grandparent -
# tracearr episode webhooks carry only the Plex show title + a per-episode tmdb id.
# When the Plex agent localised the title (e.g. "Cauchemar en cuisine…" vs Sonarr's
# "Kitchen Nightmares (FR)"), the title ilike match fails -> unresolved_episode_playback_kind.
# Fix: look up grandparentRatingKey in Plex, pull the show's real tvdb id from <Guid>.
python3 - "$SRC" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]) / "services/source_of_truth/event_playback.py"
s = p.read_text(encoding="utf-8")
MARK = "def _plex_grandparent_tvdb_id("
if MARK not in s:
    HELPER = '''def _plex_grandparent_tvdb_id(payload: dict[str, Any]) -> int | None:
    """patch_placeholdarr: resolve a localised-title show's real tvdb id from Plex."""
    data = payload.get('data') if isinstance(payload.get('data'), dict) else {}
    dm = data.get('media') if isinstance(data.get('media'), dict) else {}
    rk = (payload.get('grandparentRatingKey') or dm.get('grandparentRatingKey')
          or (payload.get('media') or {}).get('grandparentRatingKey'))
    rk = str(rk or '').strip()
    if not rk:
        return None
    try:
        import requests
        import xml.etree.ElementTree as ET
        from services.media_servers.plex import _plex_base_and_token
        base, token = _plex_base_and_token()
        if not base or not token:
            return None
        resp = requests.get(f"{base}/library/metadata/{rk}",
                            headers={"X-Plex-Token": token, "Accept": "application/xml"}, timeout=8)
        resp.raise_for_status()
        for guid in ET.fromstring(resp.text).iter('Guid'):
            gid = str(guid.get('id') or '')
            if gid.startswith('tvdb://'):
                return _as_int(gid.split('tvdb://', 1)[1].split('?')[0])
    except Exception as exc:
        logger.debug(f"plex grandparent tvdb lookup failed rk={rk}: {exc}", extra={'emoji_type': 'debug'})
    return None


def _resolve_playback_context('''
    s = s.replace("def _resolve_playback_context(", HELPER, 1)
    OLD = ("    declared_media_type = _extract_declared_media_type(payload)\n"
           "    series_title = _extract_series_title(payload)\n"
           "    path_info = _resolve_media_from_path(session, file_path)\n")
    NEW = ("    declared_media_type = _extract_declared_media_type(payload)\n"
           "    series_title = _extract_series_title(payload)\n"
           "    if (declared_media_type == 'episode' and tvdb_id is None and sonarr_series_id is None\n"
           "            and season_number is not None and episode_number is not None):\n"
           "        _gp_tvdb = _plex_grandparent_tvdb_id(payload)\n"
           "        if _gp_tvdb:\n"
           "            tvdb_id = _gp_tvdb\n"
           "            logger.info(f\"playback: resolved series tvdb={tvdb_id} via Plex grandparent lookup\", extra={'emoji_type': 'playback'})\n"
           "    path_info = _resolve_media_from_path(session, file_path)\n")
    if OLD not in s:
        raise SystemExit("patch 11: _resolve_playback_context anchor not found - upstream changed")
    s = s.replace(OLD, NEW, 1)
    import ast; ast.parse(s)
    p.write_text(s, encoding="utf-8")
    print(" * event_playback.py: Plex grandparent tvdb resolution for localised shows")
PYEOF
say "patch 11 (episode grandparent resolution) applied"

# --- patch 12: collapse import-grace countdown when status updates are OFF ----
# The import-grace flow schedules 6 countdown ticks (5/4/3/2/1/<1min) then a
# finalize step at 6*step (finalize = delete placeholder .mp4 + unmark-watched +
# Plex library refresh). The ticks only write a display_status string; with
# PLACEHOLDER_STATUS_UPDATES=OFF that text is shown nowhere, so they are pure
# delay. When OFF, emit just [noop, finalize] -> finalize one step after import.
python3 - "$SRC" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]) / "services/source_of_truth/import_grace.py"
s = p.read_text(encoding="utf-8")
if "_status_updates_off" not in s:
    OLD = ("    countdown_texts = _all_countdown_status_texts()\n"
           "    scheduled: list[dict[str, Any]] = []\n")
    NEW = ('    countdown_texts = _all_countdown_status_texts()\n\n'
           '    # patch_placeholdarr: when status updates are OFF the countdown text is never\n'
           '    # shown anywhere (Plex or elsewhere), so the 5/4/3/2/1-minute ticks are dead\n'
           '    # weight that only delay the real work. Collapse them: run finalize\n'
           '    # (placeholder cleanup + unmark-watched + library refresh) one step after\n'
           '    # import instead of six.\n'
           '    try:\n'
           '        from services.status_projection import _updates_scope\n'
           '        _status_updates_off = _updates_scope() == "OFF"\n'
           '    except Exception:\n'
           '        _status_updates_off = False\n'
           '    if _status_updates_off:\n'
           '        return [\n'
           '            {\n'
           '                "step_index": 0,\n'
           '                "run_after": now,\n'
           '                "status_text": countdown_texts[0] if countdown_texts else None,\n'
           '                "finalize": False,\n'
           '            },\n'
           '            {\n'
           '                "step_index": 1,\n'
           '                "run_after": now + timedelta(seconds=step),\n'
           '                "status_text": None,\n'
           '                "finalize": True,\n'
           '            },\n'
           '        ]\n\n'
           '    scheduled: list[dict[str, Any]] = []\n')
    if OLD not in s:
        raise SystemExit("patch 12: build_import_grace_schedule anchor not found - upstream changed")
    s = s.replace(OLD, NEW, 1)
    import ast; ast.parse(s)
    p.write_text(s, encoding="utf-8")
    print(" * import_grace.py: collapse countdown to a single finalize step when status updates OFF")
PYEOF
say "patch 12 (import-grace countdown collapse) applied"

# --- patch 13: don't push player title/summary when status updates are OFF ----
# player_metadata_refresh pushes the DB episode/movie title+summary onto Plex/
# Jellyfin/Emby for every placeholder. With PLACEHOLDER_STATUS_UPDATES=OFF there
# is no status line to add, so this only clobbers the media server agent's own
# (localised) title/summary with Sonarr/Radarr's (often English) text. When OFF,
# no-op the push entirely and let the agent own the text.
python3 - "$SRC" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]) / "services/media_servers/player_metadata_refresh.py"
s = p.read_text(encoding="utf-8")
if 'PLACEHOLDER_STATUS_UPDATES=OFF; agent owns text' not in s:
    OLD = ('    if getattr(settings, "REFRESH_TRIGGER_SUPPRESSED", False):\n'
           '        logger.debug(\n'
           '            "Skipping player metadata refresh (REFRESH_TRIGGER_SUPPRESSED)",\n'
           '            extra={"emoji_type": "debug"},\n'
           '        )\n'
           '        return acc\n')
    NEW = OLD + ('\n'
           '    # patch_placeholdarr: when status updates are OFF there is no status line to\n'
           '    # project, so pushing the bare DB title/summary onto the player only serves to\n'
           '    # clobber whatever the media server\'s own (localised) agent set. Leave the\n'
           '    # agent in charge - no-op the push entirely.\n'
           '    try:\n'
           '        from services.status_projection import _updates_scope\n'
           '        if _updates_scope() == "OFF":\n'
           '            logger.debug(\n'
           '                "Skipping player metadata push (PLACEHOLDER_STATUS_UPDATES=OFF; agent owns text) "\n'
           '                f"placeholder_id={getattr(placeholder, \'id\', None)}",\n'
           '                extra={"emoji_type": "debug"},\n'
           '            )\n'
           '            return acc\n'
           '    except Exception:\n'
           '        pass\n')
    if OLD not in s:
        raise SystemExit("patch 13: push_placeholder_player_metadata anchor not found - upstream changed")
    s = s.replace(OLD, NEW, 1)
    import ast; ast.parse(s)
    p.write_text(s, encoding="utf-8")
    print(" * player_metadata_refresh.py: no-op player text push when PLACEHOLDER_STATUS_UPDATES=OFF")
PYEOF
say "patch 13 (no player-text push when status OFF) applied"

# --- seed appdata -------------------------------------------------------
mkdir -p "${DATA}/config"
for f in dummy.mp4 coming_soon_dummy.mp4; do
  [ -f "${SRC}/${f}" ] && [ ! -f "${DATA}/config/${f}" ] && cp "${SRC}/${f}" "${DATA}/config/${f}"
done
# carry over the auth session secret from the pre-nativeapp install, if present
OLD="/Users/haldir/placeholdarr/config/.auth_session_secret"
[ -f "${OLD}" ] && [ ! -f "${DATA}/config/.auth_session_secret" ] && cp "${OLD}" "${DATA}/config/.auth_session_secret"
say "appdata seeded at ${DATA}/config"
