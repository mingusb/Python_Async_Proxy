#!/bin/bash
set -euo pipefail

# Run benchmark matrix across available modes and pick the fastest small HTML wrk rps.
# Modes: baseline (default), splice, zerocopy, batch, busy-poll, multi-worker.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WORKER_COUNT="${WORKERS_BENCH:-4}"
CRELAY_THREADS="${CRELAY_THREADS:-256}"
NAMES=(baseline splice zerocopy batch bp50 workers crelay)
ENVS=("" "USE_SPLICE=1" "USE_ZEROCOPY=1" "USE_BATCH=1" "BUSY_POLL_US=50" "WORKERS=${WORKER_COUNT}" "USE_C_RELAY=1 CRELAY_THREADS=${CRELAY_THREADS}")

BEST_MODE=""
BEST_RPS=0.0

for i in "${!NAMES[@]}"; do
  mode="${NAMES[$i]}"
  envvars="${ENVS[$i]}"
  echo ">>> Running $mode..."
  env $envvars make bench >/tmp/bench_matrix_${mode}.out 2>&1 || true
  cp bench.log "bench_${mode}.log" 2>/dev/null || true
  cp bench_connect.log "bench_connect_${mode}.log" 2>/dev/null || true

  rps=$(python - "$mode" <<'PY'
import sys, re
from pathlib import Path
mode = sys.argv[1]
log = Path(f"bench_{mode}.log")
if not log.exists():
    print("0")
    sys.exit(0)
text = log.read_text(errors="ignore")
m = re.search(r"Requests/sec:\s*([0-9.]+)", text)
print(m.group(1) if m else "0")
PY
)
  echo "Mode $mode wrk rps: $rps"
  rps_val=$(python - "$rps" <<'PY'
import sys
try:
    print(float(sys.argv[1]))
except Exception:
    print(0.0)
PY
)
  if (( $(echo "$rps_val > $BEST_RPS" | bc -l) )); then
    BEST_RPS=$rps_val
    BEST_MODE=$mode
  fi
done

if [ -z "$BEST_MODE" ]; then
  echo "No successful benchmark runs found."
  exit 1
fi

echo ">>> Best mode: $BEST_MODE (wrk small rps ~${BEST_RPS})"
cp "bench_${BEST_MODE}.log" bench.log
cp "bench_connect_${BEST_MODE}.log" bench_connect.log
python scripts/update_readme_results.py bench.log bench_connect.log README.md
