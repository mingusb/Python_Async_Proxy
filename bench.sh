#!/bin/bash
set -euo pipefail

AUTH_HEADER="Proxy-Authorization: Basic $(echo -n 'username:password' | base64)"
TARGET="http://127.0.0.1:8888"
PAYLOAD_SIZES=(1 16 128 1024) # KB
CONC="${CONC:-100}"
DURATION="${DURATION:-8}" # seconds per tool per payload

prepare_payloads() {
  for sz in "${PAYLOAD_SIZES[@]}"; do
    path="/var/www/html/payload_${sz}k.bin"
    if [ ! -f "$path" ]; then
      echo "Creating ${sz}KB payload at ${path}"
      echo b | sudo -S dd if=/dev/urandom of="$path" bs=1024 count="$sz" status=none
    fi
  done
}

run_case() {
  local path="$1"
  local label="$2"
  echo "=== ${label} (${path}) ==="
  wrk -t1 -c"${CONC}" -d"${DURATION}s" --latency -H "$AUTH_HEADER" "${TARGET}${path}"
  siege -b -c"${CONC}" -t"${DURATION}s" --header="$AUTH_HEADER" "${TARGET}${path}" | tail -n 15
}

prepare_payloads

python -u -c "import proxy" >/tmp/proxy.log 2>&1 &
PROXY_PID=$!
trap 'kill "$PROXY_PID" >/dev/null 2>&1 || true' EXIT
sleep 1

run_case "/index.html" "small (HTML)"
for sz in "${PAYLOAD_SIZES[@]}"; do
  run_case "/payload_${sz}k.bin" "${sz}KB binary"
done

kill "$PROXY_PID" >/dev/null 2>&1 || true
