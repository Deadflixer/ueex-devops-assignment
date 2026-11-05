#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Відкат Kanboard на попередню версію образу (збережену scripts/update.sh).
#
# Використання:
#   scripts/rollback.sh                 # лише образ; дані, створені після оновлення, зберігаються
#   scripts/rollback.sh --restore-db    # образ + БД/файли з бекапу pre-update
#                                       # (якщо міграція схеми несумісна зі старою версією;
#                                       #  дані, створені після оновлення, буде втрачено)
#   --yes                               # без підтвердження
set -Eeuo pipefail
SCRIPT_NAME=rollback
source "$(dirname "$0")/lib.sh"
load_env

RESTORE_DB=0 YES=0
for arg in "$@"; do
  case "$arg" in
    --restore-db) RESTORE_DB=1 ;;
    --yes|-y)     YES=1 ;;
    -h|--help)    sed -n '3,10p' "$0"; exit 0 ;;
    *)            die "Невідомий аргумент: $arg" ;;
  esac
done

[[ -f "$STATE_DIR/previous_tag" ]] || die "Немає $STATE_DIR/previous_tag — оновлень через update.sh не було"
PREV_TAG=$(cat "$STATE_DIR/previous_tag")
CUR_TAG=$APP_TAG
[[ "$PREV_TAG" != "$CUR_TAG" ]] || die "Поточна версія вже ${CUR_TAG}"

log "Відкат: ${CUR_TAG} -> ${PREV_TAG} (restore-db=${RESTORE_DB})"
if (( ! YES )); then
  confirm "Продовжити?" || die "Скасовано"
fi

set_env_var APP_TAG "$PREV_TAG"

if (( RESTORE_DB )); then
  BACKUP_NAME=$(cat "$STATE_DIR/pre_update_backup")
  log "Відновлюю дані з ${BACKUP_NAME}"
  # restore.sh сам зупинить app і запустить його з APP_TAG (вже попередній)
  "$REPO_DIR/scripts/restore.sh" "$BACKUP_NAME" --yes
else
  dc up -d --no-deps app
  wait_healthy app 180 || die "Попередня версія теж не піднялась — спробуйте: $0 --restore-db"
fi

# Міняємо місцями, щоб можна було «відкотити відкат» (повернутись вперед)
echo "$CUR_TAG" > "$STATE_DIR/previous_tag"
echo "$(date -Is) rollback ${CUR_TAG} -> ${PREV_TAG} restore_db=${RESTORE_DB}" >> "$STATE_DIR/history.log"
log "Відкат завершено: APP_TAG=${PREV_TAG}"
