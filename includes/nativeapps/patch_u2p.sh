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
PYEOF
echo -e " ${GREEN}* [patch_u2p] curator crash-loop guard applied${NC}"
