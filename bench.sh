#!/bin/bash
set -euo pipefail

AUTH_HEADER="Proxy-Authorization: Basic $(echo -n 'username:password' | base64)"
TARGET="http://127.0.0.1:8888"
PAYLOAD_SIZES=(1 16 128 1024) # KB

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
  wrk -t1 -c100 -d30 --latency -H "$AUTH_HEADER" "${TARGET}${path}"
  siege -b -c100 -t30s --header="$AUTH_HEADER" "${TARGET}${path}"
}

prepare_payloads

run_case "/index.html" "small (HTML)"
for sz in "${PAYLOAD_SIZES[@]}"; do
  run_case "/payload_${sz}k.bin" "${sz}KB binary"
done
