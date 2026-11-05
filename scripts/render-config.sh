#!/usr/bin/env bash
# Генерує monitoring/alertmanager/alertmanager.yml з .env.
# Файл містить токен Telegram-бота, тому він у .gitignore і створюється на хості.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source .env

OUT=monitoring/alertmanager/alertmanager.yml
umask 022

if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
  RECEIVER=telegram
  RECEIVER_BLOCK=$(cat <<EOT
  - name: telegram
    telegram_configs:
      - bot_token: '${TELEGRAM_BOT_TOKEN}'
        chat_id: ${TELEGRAM_CHAT_ID}
        parse_mode: HTML
        send_resolved: true
EOT
)
else
  echo "[render-config] TELEGRAM_* не задані — алерти будуть видні лише в UI Alertmanager"
  RECEIVER=ui-only
  RECEIVER_BLOCK="  - name: ui-only"
fi

cat > "$OUT" <<EOT
# ЗГЕНЕРОВАНО scripts/render-config.sh — не редагувати вручну.
route:
  receiver: ${RECEIVER}
  group_by: [alertname, job]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:
${RECEIVER_BLOCK}

inhibit_rules:
  # Якщо лежить БД, застосунок теж лежить — шлемо лише першопричину
  - source_matchers: [alertname="PostgresDown"]
    target_matchers: [alertname="ApplicationDown"]
EOT
echo "[render-config] Записано $OUT (receiver=${RECEIVER})"
