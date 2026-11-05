#!/usr/bin/env bash
# Статична перевірка репозиторію (локально або в CI). Потрібен лише Docker.
#   - shellcheck усіх скриптів
#   - docker compose config з .env.example
#   - promtool: конфіг Prometheus, правила алертів, юніт-тести алертів
set -Eeuo pipefail
cd "$(dirname "$0")/.."

PROM_IMAGE=prom/prometheus:v3.15.1

echo "== shellcheck"
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x scripts/*.sh

echo "== docker compose config"
docker compose --env-file .env.example config -q

echo "== promtool"
docker run --rm --entrypoint sh -v "$PWD/monitoring/prometheus:/etc/prometheus:ro" "$PROM_IMAGE" -c '
  promtool check config /etc/prometheus/prometheus.yml &&
  promtool check rules  /etc/prometheus/rules/alerts.yml &&
  cd /etc/prometheus/tests && promtool test rules alerts_test.yml'

echo "OK: усі перевірки пройдено"
