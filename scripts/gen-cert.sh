#!/usr/bin/env bash
# Генерує self-signed сертифікат для nginx (nginx/certs/server.{crt,key}).
# SAN = SERVER_NAME з .env (IP або DNS-імʼя). Існуючий не перезаписується без --force.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source .env

CERT_DIR=nginx/certs
if [[ -f "$CERT_DIR/server.crt" && "${1:-}" != "--force" ]]; then
  echo "[gen-cert] Сертифікат вже існує. Для перевипуску: $0 --force"
  exit 0
fi

if [[ "$SERVER_NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  SAN="IP:${SERVER_NAME}"
else
  SAN="DNS:${SERVER_NAME}"
fi

mkdir -p "$CERT_DIR"
openssl req -x509 -quiet -nodes -newkey rsa:2048 -days 365 \
  -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.crt" \
  -subj "/CN=${SERVER_NAME}" -addext "subjectAltName=${SAN}"
chmod 600 "$CERT_DIR/server.key"
chmod 644 "$CERT_DIR/server.crt"

echo "[gen-cert] Готово (SAN=${SAN}, 365 днів)"
openssl x509 -in "$CERT_DIR/server.crt" -noout -subject -enddate
