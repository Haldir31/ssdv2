#!/bin/bash
# post_fetch hook for u2p / athanor (see vars/u2p.yml).
# Nil-guards the curator CircuitBreaker: with the curator disabled
# (ATHANOR_CURATOR_ENABLED=false) the /api/v1/curation/stats handler deref'd a
# nil breaker -> panic -> KeepAlive crash-loop whenever the UI/dashboard polled it.
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
PYEOF
echo -e " ${GREEN}* [patch_u2p] curator crash-loop guard applied${NC}"
