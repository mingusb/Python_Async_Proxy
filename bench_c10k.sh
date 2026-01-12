#!/bin/bash
set -euo pipefail

# Sweep high-concurrency wrk runs to locate the peak throughput around/above 10K connections.
# Configure via env:
#   CONC_LIST="1000 5000 10000 15000"   # space-separated wrk -c values (10k must be present)
#   DURATION=5                         # seconds per run
#   TARGET=http://127.0.0.1:8888/index.html
#   AUTH_HEADER="Proxy-Authorization: Basic ..."
#   PROXY_ENV="WORKERS=4 PIN_WORKERS=1" # extra env for proxy process

AUTH_HEADER="${AUTH_HEADER:-Proxy-Authorization: Basic $(echo -n 'username:password' | base64)}"
TARGET="${TARGET:-http://127.0.0.1:8888/index.html}"
CONC_LIST=(${CONC_LIST:-"1000 5000 10000 15000"})
DURATION="${DURATION:-5}"
PROXY_ENV="${PROXY_ENV:-}"
WRK_THREADS="${WRK_THREADS:-4}"
SYSCTL_TUNE="${SYSCTL_TUNE:-0}"

if ! printf '%s\n' "${CONC_LIST[@]}" | grep -q "^10000$"; then
  CONC_LIST+=("10000")
fi

ulimit -n 200000 >/dev/null 2>&1 || true

prepare_payloads() {
  for sz in 1 16 128 1024; do
    path="/var/www/html/payload_${sz}k.bin"
    if [ ! -f "$path" ]; then
      echo "Creating ${sz}KB payload at ${path}"
      echo b | sudo -S dd if=/dev/urandom of="$path" bs=1024 count="$sz" status=none
    fi
  done
}

prepare_payloads

if [ "$SYSCTL_TUNE" = "1" ]; then
  echo b | sudo -S sysctl -w net.core.somaxconn=65535 >/dev/null 2>&1 || true
  echo b | sudo -S sysctl -w net.core.netdev_max_backlog=16384 >/dev/null 2>&1 || true
  echo b | sudo -S sysctl -w net.ipv4.tcp_max_syn_backlog=16384 >/dev/null 2>&1 || true
fi

env $PROXY_ENV python -u -c "import proxy" >/tmp/proxy.log 2>&1 &
PROXY_PID=$!
trap 'kill "$PROXY_PID" >/dev/null 2>&1 || true' EXIT
sleep 1

best_c=0
best_rps=0
c10k_rps="n/a"

run_case() {
  local c="$1"
  echo "=== C=${c} ==="
  wrk -t"${WRK_THREADS}" -c"${c}" -d"${DURATION}s" --latency -H "$AUTH_HEADER" "$TARGET"
}

for c in "${CONC_LIST[@]}"; do
  out=$(run_case "$c")
  echo "$out"
  rps=$(python - "$out" <<'PY'
import sys,re
text=sys.argv[1]
m=re.search(r"Requests/sec:\s*([0-9.]+)", text)
print(m.group(1) if m else "0")
PY
)
  if [ "$c" -eq 10000 ]; then
    c10k_rps="$rps"
  fi
  rps_val=$(python - "$rps" <<'PY'
import sys
try:
    print(float(sys.argv[1]))
except Exception:
    print(0.0)
PY
)
  if (( $(echo "$rps_val > $best_rps" | bc -l) )); then
    best_rps="$rps_val"
    best_c="$c"
  fi
done

echo "=== SUMMARY ==="
echo "Best wrk Requests/sec: ${best_rps} at concurrency ${best_c}"
echo "C=10000 Requests/sec: ${c10k_rps}"
