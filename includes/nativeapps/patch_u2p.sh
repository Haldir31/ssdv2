#!/bin/bash
# post_fetch hook for u2p / athanor (see vars/u2p.yml).
#
# Patch 1 — Nil-guards the curator CircuitBreaker: with the curator disabled
#   (ATHANOR_CURATOR_ENABLED=false) the /api/v1/curation/stats handler deref'd a
#   nil breaker -> panic -> KeepAlive crash-loop whenever the UI/dashboard polled it.
# Patch 2 — CuratorGate.ShouldIndex passthrough when the curator is disabled.
#   Upstream is "fail-closed": curator nil/disabled -> ShouldIndex returns false
#   for EVERY torrent, so the indexer writes nothing to `content` (Meili stays 0)
#   even though NIP-77 sync fills relay_events. With curator.enabled=false we run
#   a whitelist-gated personal indexer; the trust/blacklist/tag gates upstream of
#   the curator gate still apply. Passthrough instead of fail-closed.
# Idempotent. Usage: patch_u2p.sh <src_dir> <data_dir>
set -euo pipefail
SRC="${1:?}"; cd "${SRC}"
GREEN="${GREEN:-\033[0;32m}"; NC="${NC:-\033[0m}"

python3 - <<'PYEOF'
import pathlib
cb = pathlib.Path("internal/curator/circuit_breaker.go")
s = cb.read_text()
if "if c == nil || c.cb == nil" not in s:
    s = s.replace("func (c *CircuitBreaker) IsOpen() bool {\n\tc.mu.RLock()",
        "func (c *CircuitBreaker) IsOpen() bool {\n\tif c == nil || c.cb == nil {\n\t\treturn false\n\t}\n\tc.mu.RLock()", 1)
    s = s.replace("func (c *CircuitBreaker) IsHealthy() bool {\n\tc.mu.RLock()",
        "func (c *CircuitBreaker) IsHealthy() bool {\n\tif c == nil || c.cb == nil {\n\t\treturn true\n\t}\n\tc.mu.RLock()", 1)
    s = s.replace("func (c *CircuitBreaker) State() CircuitState {\n\tc.mu.RLock()",
        "func (c *CircuitBreaker) State() CircuitState {\n\tif c == nil || c.cb == nil {\n\t\treturn StateClosed\n\t}\n\tc.mu.RLock()", 1)
    s = s.replace("func (c *CircuitBreaker) Stats() CircuitBreakerStats {\n\tc.mu.RLock()",
        "func (c *CircuitBreaker) Stats() CircuitBreakerStats {\n\tif c == nil || c.cb == nil {\n\t\treturn CircuitBreakerStats{}\n\t}\n\tc.mu.RLock()", 1)
    cb.write_text(s); print(" * circuit_breaker.go nil-guarded")

cg = pathlib.Path("internal/api/handlers/curator.go")
g = cg.read_text()
if "GetCircuitBreaker() == nil ||" not in g:
    g = g.replace("\t\tHealthy:         !service.GetCircuitBreaker().IsOpen(),",
        "\t\tHealthy:         service.GetCircuitBreaker() == nil || !service.GetCircuitBreaker().IsOpen(),", 1)
    cg.write_text(g); print(" * curator.go handler nil-guarded")

# --- patch 3: NIP-01 multi-value tag filter must be OR, not AND ---
# storage_helpers.go appendTagFilters emits one `AND tags_json @> …` per value,
# so `#l: [A,B,C]` requires the event to carry ALL of A,B,C. NIP-01 says a tag
# filter's values are a logical OR. Breaks reborn's u2p_sync (9 `#l` categories
# in one REQ -> 0 events from the Khatru relay). Wrap the per-value conditions
# in ( … OR … ). Regex-based (whitespace-insensitive) on the default: case body.
import re as _re
sh_helpers = pathlib.Path("internal/relay/storage_helpers.go")
h = sh_helpers.read_text()
if "logical OR. (patch_u2p.sh)" not in h:
    pat = _re.compile(
        r"\t\tdefault:\n"
        r"\t\t\tfor _, v := range values \{\n"
        r"(?:.*\n)*?"                      # inner body (non-greedy)
        r"\t\t\t\}\n"
        r"\t\t\}\n"
    )
    NEW_TF = (
        "\t\tdefault:\n"
        "\t\t\t// NIP-01: a tag filter's values are a logical OR. (patch_u2p.sh)\n"
        "\t\t\tors := make([]string, 0, len(values))\n"
        "\t\t\tfor _, v := range values {\n"
        "\t\t\t\tif isPostgres {\n"
        "\t\t\t\t\tors = append(ors, \"tags_json @> ?::jsonb\")\n"
        "\t\t\t\t\tcontainment, _ := json.Marshal([][]string{{tagName, v}})\n"
        "\t\t\t\t\targs = append(args, string(containment))\n"
        "\t\t\t\t} else {\n"
        "\t\t\t\t\tors = append(ors, `tags_json LIKE ? ESCAPE '\\\\'`)\n"
        "\t\t\t\t\targs = append(args, fmt.Sprintf(`%%[\"%s\",\"%s\"%%`, dbconn.EscapeLike(tagName), dbconn.EscapeLike(v)))\n"
        "\t\t\t\t}\n"
        "\t\t\t}\n"
        "\t\t\tif len(ors) > 0 {\n"
        "\t\t\t\tquery += \" AND (\" + strings.Join(ors, \" OR \") + \")\"\n"
        "\t\t\t}\n"
        "\t\t}\n"
    )
    h2, n = pat.subn(NEW_TF, h, count=1)
    if n != 1:
        raise SystemExit("patch_u2p patch 3: appendTagFilters default case not found - upstream changed")
    sh_helpers.write_text(h2)
    print(" * storage_helpers.go: multi-value tag filter -> OR")

# --- patch 2: curator-disabled -> ShouldIndex passthrough (not fail-closed) ---
ci = pathlib.Path("internal/indexer/curator_integration.go")
t = ci.read_text()
OLD = ('\t// Fail-closed policy: reject all if service not enabled\n'
       '\tif g.service == nil || !g.service.IsEnabled() {\n'
       '\t\tspan.SetStatus(codes.Ok, "service not available")\n'
       '\t\treturn false, "curator service required but not available"\n'
       '\t}\n')
NEW = ('\t// Curator disabled -> passthrough. Upstream trust/blacklist/tag gates\n'
       '\t// still apply; a whitelist-gated personal indexer does not need the\n'
       '\t// Python curator. (patch_u2p.sh)\n'
       '\tif g.service == nil || !g.service.IsEnabled() {\n'
       '\t\tspan.SetStatus(codes.Ok, "curator disabled - passthrough")\n'
       '\t\treturn true, "curator disabled"\n'
       '\t}\n')
if NEW not in t:
    if OLD not in t:
        raise SystemExit("patch_u2p: curator_integration.go ShouldIndex block not found - upstream changed")
    ci.write_text(t.replace(OLD, NEW, 1)); print(" * curator_integration.go ShouldIndex -> passthrough when disabled")

# --- patch 4: hydrate the Postgres id onto Meili search results ---
# The Meili "athanor_torrents" index is keyed by info_hash and its documents carry
# no numeric id, so /api/v1/search results come back with id=0 when Meili is the
# active backend. The SvelteKit UI navigates to /torrent/{id} -> "Invalid torrent
# ID". Backfill the id from info_hash in the Search handler (GetSummariesByInfohash,
# which had no callers, gains an ID field).
ts = pathlib.Path("internal/torrent/types.go")
x = ts.read_text()
if "ID       int64" not in x:
    x = x.replace("type TorrentSummary struct {\n\tName     string\n",
                  "type TorrentSummary struct {\n\tID       int64\n\tName     string\n", 1)
    ts.write_text(x); print(" * types.go: TorrentSummary.ID")
st = pathlib.Path("internal/torrent/storage.go")
y = st.read_text()
if "SELECT info_hash, id, name, category, size" not in y:
    y = y.replace("`SELECT info_hash, name, category, size FROM torrents WHERE info_hash IN `",
                  "`SELECT info_hash, id, name, category, size FROM torrents WHERE info_hash IN `", 1)
    y = y.replace("rows.Scan(&ih, &ts.Name, &ts.Category, &ts.Size)",
                  "rows.Scan(&ih, &ts.ID, &ts.Name, &ts.Category, &ts.Size)", 1)
    st.write_text(y); print(" * storage.go: GetSummariesByInfohash selects id")
sh = pathlib.Path("internal/api/handlers/search.go")
z = sh.read_text()
if "hydrate the Postgres id from info_hash" not in z:
    OLD_S = ("\ttorrents := make([]searchResultResponse, 0, len(result.Items))\n"
             "\tfor _, sr := range result.Items {\n"
             "\t\ttorrents = append(torrents, toSearchResultResponse(sr))\n"
             "\t}\n\n"
             "\thttputil.RespondJSON(w, http.StatusOK, searchResponse{\n")
    NEW_S = ("\ttorrents := make([]searchResultResponse, 0, len(result.Items))\n"
             "\tfor _, sr := range result.Items {\n"
             "\t\ttorrents = append(torrents, toSearchResultResponse(sr))\n"
             "\t}\n\n"
             "\t// Meili hits are keyed by info_hash and carry no numeric id; the UI\n"
             "\t// navigates to /torrent/{id}, so hydrate the Postgres id from info_hash.\n"
             "\tif h.deps.TorrentStorage != nil {\n"
             "\t\tvar missing []string\n"
             "\t\tfor i := range torrents {\n"
             "\t\t\tif torrents[i].ID == 0 && torrents[i].InfoHash != \"\" {\n"
             "\t\t\t\tmissing = append(missing, torrents[i].InfoHash)\n"
             "\t\t\t}\n"
             "\t\t}\n"
             "\t\tif len(missing) > 0 {\n"
             "\t\t\tif summaries, sErr := h.deps.TorrentStorage.GetSummariesByInfohash(ctx, missing); sErr == nil {\n"
             "\t\t\t\tfor i := range torrents {\n"
             "\t\t\t\t\tif torrents[i].ID == 0 {\n"
             "\t\t\t\t\t\tif s, ok := summaries[torrents[i].InfoHash]; ok {\n"
             "\t\t\t\t\t\t\ttorrents[i].ID = s.ID\n"
             "\t\t\t\t\t\t}\n"
             "\t\t\t\t\t}\n"
             "\t\t\t\t}\n"
             "\t\t\t}\n"
             "\t\t}\n"
             "\t}\n\n"
             "\thttputil.RespondJSON(w, http.StatusOK, searchResponse{\n")
    if OLD_S not in z:
        raise SystemExit("patch_u2p patch 4: Search handler response block not found - upstream changed")
    sh.write_text(z.replace(OLD_S, NEW_S, 1)); print(" * search.go: hydrate id on meili results")
PYEOF
echo -e " ${GREEN}* [patch_u2p] curator crash-loop guard applied${NC}"
