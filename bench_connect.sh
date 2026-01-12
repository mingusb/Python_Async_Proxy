#!/bin/bash
set -euo pipefail

AUTH_HEADER="Proxy-Authorization: Basic $(echo -n 'username:password' | base64)"
CONC="${CONC:-50}"
TOTAL="${TOTAL:-400}"
PAYLOAD_SIZES=(1 16 128 1024) # KB
TARGET_HOST=127.0.0.1
TARGET_PORT=8443

CERT_DIR="/tmp/proxy_bench_tls"
NGINX_PREFIX="/tmp/nginx-ssl-bench"
NGINX_CONF="$NGINX_PREFIX/nginx.conf"

prepare_cert() {
  mkdir -p "$CERT_DIR"
  if [ ! -f "$CERT_DIR/cert.pem" ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
      -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
      -subj "/CN=127.0.0.1" >/dev/null 2>&1
  fi
}

start_nginx_ssl() {
  mkdir -p "$NGINX_PREFIX/logs"
  cat >"$NGINX_CONF" <<EOF
worker_processes 1;
pid logs/nginx.pid;
events { worker_connections 2048; }
http {
    access_log logs/access.log;
    error_log logs/error.log;
    server {
        listen ${TARGET_PORT} ssl;
        ssl_certificate ${CERT_DIR}/cert.pem;
        ssl_certificate_key ${CERT_DIR}/key.pem;
        location / {
            root /var/www/html;
            index index.html;
        }
    }
}
EOF
  nginx -c "$NGINX_CONF" -p "$NGINX_PREFIX"
}

stop_nginx_ssl() {
  nginx -c "$NGINX_CONF" -p "$NGINX_PREFIX" -s stop >/dev/null 2>&1 || true
}

prepare_payloads() {
  for sz in "${PAYLOAD_SIZES[@]}"; do
    path="/var/www/html/payload_${sz}k.bin"
    if [ ! -f "$path" ]; then
      echo "Creating ${sz}KB payload at ${path}"
      echo b | sudo -S dd if=/dev/urandom of="$path" bs=1024 count="$sz" status=none
    fi
  done
}

prepare_cert
prepare_payloads
stop_nginx_ssl
start_nginx_ssl

python -u -c "import proxy" >/tmp/proxy.log 2>&1 &
PROXY_PID=$!
trap 'kill "$PROXY_PID" >/dev/null 2>&1 || true; stop_nginx_ssl' EXIT
sleep 1

run_case() {
  local path="$1"
  local label="$2"
  local filesize
  if ! filesize=$(stat -c%s "/var/www/html${path}" 2>/dev/null); then
    filesize=0
  fi
  echo "=== CONNECT ${label} (${path}) ==="
  local elapsed rps tp
  TIMEFORMAT=%R
  elapsed=$({ time seq "${TOTAL}" | xargs -P "${CONC}" -I{} curl -s -k \
    --proxy "http://127.0.0.1:8888" \
    --proxy-header "$AUTH_HEADER" \
    "https://${TARGET_HOST}:${TARGET_PORT}${path}" >/dev/null; } 2>&1)
  rps=$(python - "$TOTAL" "$elapsed" <<'PY'
import sys
n=int(sys.argv[1]); t=float(sys.argv[2]) if sys.argv[2] else 0.0
print(n/t if t>0 else 0)
PY
)
  tp=$(python - "$filesize" "$TOTAL" "$elapsed" <<'PY'
import sys
size=int(sys.argv[1]); n=int(sys.argv[2]); t=float(sys.argv[3]) if sys.argv[3] else 0.0
bps=(size*n)/t if t>0 else 0
print(f"{bps/1024/1024:.2f} MB/s")
PY
)
  echo "Requests/sec: ${rps}"
  echo "Transfer/sec: ${tp}"
}

run_case "/index.html" "HTML"
for sz in "${PAYLOAD_SIZES[@]}"; do
  run_case "/payload_${sz}k.bin" "${sz}KB binary"
done
