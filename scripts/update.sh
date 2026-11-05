#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Оновлення Kanboard на нову версію образу без втрати даних.
#
# Використання:  scripts/update.sh <new_tag>        напр.  scripts/update.sh v1.2.57
#
# Кроки:
#   1. pull нового образу (до будь-якого простою)
#   2. бекап БД+файлів з міткою pre-update
#   3. запис стану для відкату (.deploy/previous_tag, .deploy/pre_update_backup)
#   4. перестворення ЛИШЕ контейнера app з новим тегом (БД і volumes не чіпаються)
#   5. перевірка healthcheck + запит через nginx
#   6. якщо перевірка не пройшла — автоматичний відкат образу (scripts/rollback.sh)
set -Eeuo pipefail
SCRIPT_NAME=update
source "$(dirname "$0")/lib.sh"
load_env

NEW_TAG=${1:-}
[[ "$NEW_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Використання: $0 vX.Y.Z"
CUR_TAG=$APP_TAG
[[ "$NEW_TAG" != "$CUR_TAG" ]] || die "Вже на версії ${CUR_TAG}"

log "Оновлення ${APP_IMAGE}: ${CUR_TAG} -> ${NEW_TAG}"

# 1. Pull заздалегідь — якщо тегу не існує, падаємо до будь-яких змін
docker pull "${APP_IMAGE}:${NEW_TAG}"

# 2. Бекап перед оновленням (міграції схеми БД незворотні)
"$REPO_DIR/scripts/backup.sh" pre-update
BACKUP_NAME=$(cat "${BACKUP_DIR:-/var/backups/ueex}/LATEST")

# 3. Стан для відкату
mkdir -p "$STATE_DIR"
echo "$CUR_TAG"     > "$STATE_DIR/previous_tag"
echo "$BACKUP_NAME" > "$STATE_DIR/pre_update_backup"
echo "$(date -Is) update ${CUR_TAG} -> ${NEW_TAG} backup=${BACKUP_NAME}" >> "$STATE_DIR/history.log"

# 4. Перемикаємо тег і перестворюємо лише app
set_env_var APP_TAG "$NEW_TAG"
dc up -d --no-deps app

# 5. Перевірка
if wait_healthy app 180 && curl -ksf -o /dev/null https://127.0.0.1/healthcheck.php; then
  RUNNING=$(docker inspect -f '{{.Config.Image}}' "$(dc ps -q app)")
  log "Оновлення успішне: працює ${RUNNING}"
  log "Відкат за потреби:  scripts/rollback.sh   (або з даними: scripts/rollback.sh --restore-db)"
else
  warn "Нова версія не пройшла перевірку — виконую автоматичний відкат"
  dc logs --tail 50 app || true
  "$REPO_DIR/scripts/rollback.sh" --yes
  die "Оновлення на ${NEW_TAG} скасовано, повернуто ${CUR_TAG}"
fi
