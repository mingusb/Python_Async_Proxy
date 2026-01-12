#!/bin/bash
set -euo pipefail

# Quick health check: short duration, lower concurrency.
AUTH_HEADER="Proxy-Authorization: Basic $(echo -n 'username:password' | base64)"
TARGET="http://127.0.0.1:8888/index.html"
DURATION="${DURATION:-2}"
CONC="${CONC:-20}"

python -u -c "import proxy" >/tmp/proxy.log 2>&1 &
PROXY_PID=$!
trap 'kill "$PROXY_PID" >/dev/null 2>&1 || true' EXIT
sleep 1

echo "=== smoke (HTML) ==="
wrk -t1 -c"${CONC}" -d"${DURATION}s" --latency -H "$AUTH_HEADER" "$TARGET"
siege -b -c"${CONC}" -t"${DURATION}s" --header="$AUTH_HEADER" "$TARGET" | tail -n 15
