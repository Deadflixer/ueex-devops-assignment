#!/usr/bin/env bash
# Спільні функції для скриптів. Підключається через: source "$(dirname "$0")/lib.sh"
# shellcheck disable=SC2034

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR" || exit 1

COMPOSE_PROJECT=ueex
APP_IMAGE=kanboard/kanboard
APP_DATA_VOLUME="${COMPOSE_PROJECT}_kanboard_data"
RCLONE_IMAGE=rclone/rclone:1.75
STATE_DIR="$REPO_DIR/.deploy"

log()  { echo "[$(date '+%F %T')] [${SCRIPT_NAME:-ueex}] $*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "ERROR: $*" >&2; exit 1; }

dc() { docker compose "$@"; }

load_env() {
  [[ -f "$REPO_DIR/.env" ]] || die ".env не знайдено в $REPO_DIR (див. .env.example)"
  set -a
  # shellcheck source=/dev/null
  source "$REPO_DIR/.env"
  set +a
}

# Змінити значення KEY=... у .env (ключ має існувати)
set_env_var() {
  local key=$1 value=$2
  grep -q "^${key}=" .env || die "Ключ ${key} відсутній у .env"
  sed -i "s|^${key}=.*|${key}=${value}|" .env
  export "${key}=${value}"
}

# Чекати, поки сервіс стане healthy. $1 - сервіс, $2 - таймаут у секундах
wait_healthy() {
  local svc=$1 timeout=${2:-180} waited=0 cid status
  log "Очікую healthy для '${svc}' (до ${timeout}s)..."
  while (( waited < timeout )); do
    cid=$(dc ps -q "$svc" 2>/dev/null || true)
    if [[ -n "$cid" ]]; then
      status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || echo unknown)
      if [[ "$status" == "healthy" ]]; then
        log "'${svc}' healthy (${waited}s)"
        return 0
      fi
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done
  warn "'${svc}' не став healthy за ${timeout}s (останній статус: ${status:-none})"
  return 1
}

r2_enabled() { [[ -n "${R2_BUCKET:-}" ]]; }

r2_remote() { echo "r2:${R2_BUCKET}/${R2_PREFIX:-ueex}"; }

# rclone у контейнері; секрети передаються через змінні середовища (не видно в ps)
rclone_r2() {
  RCLONE_CONFIG_R2_TYPE=s3 \
  RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
  RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
  RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
  RCLONE_CONFIG_R2_ENDPOINT="${R2_ENDPOINT:-https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com}" \
  RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true \
  docker run --rm \
    -e RCLONE_CONFIG_R2_TYPE -e RCLONE_CONFIG_R2_PROVIDER \
    -e RCLONE_CONFIG_R2_ACCESS_KEY_ID -e RCLONE_CONFIG_R2_SECRET_ACCESS_KEY \
    -e RCLONE_CONFIG_R2_ENDPOINT -e RCLONE_CONFIG_R2_NO_CHECK_BUCKET \
    -v "${BACKUP_DIR}:/data" \
    "$RCLONE_IMAGE" "$@"
}

require_root() { [[ $EUID -eq 0 ]] || die "Запустіть від root (sudo)"; }
