#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Резервне копіювання Kanboard:
#   1) дамп PostgreSQL (pg_dump, custom format) + перевірка читабельності дампу
#   2) архів volume з вкладеннями Kanboard (/var/www/app/data)
#   3) контрольні суми sha256
#   4) копія в Cloudflare R2 (якщо задано R2_BUCKET) + ротація там
#   5) локальна ротація + метрики для Prometheus (node-exporter textfile collector)
#
# Використання:  scripts/backup.sh [label]      label: scheduled | manual | pre-update ...
# За розкладом запускається systemd-таймером ueex-backup.timer.
set -Eeuo pipefail
SCRIPT_NAME=backup
source "$(dirname "$0")/lib.sh"
load_env

LABEL=${1:-manual}
[[ "$LABEL" =~ ^[a-z0-9-]+$ ]] || die "label має містити лише [a-z0-9-]"

BACKUP_DIR=${BACKUP_DIR:-/var/backups/ueex}
TEXTFILE_DIR=${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}
RETENTION=${BACKUP_RETENTION_DAYS:-7}

# Не допускаємо двох паралельних бекапів
exec 9>/run/lock/ueex-backup.lock
flock -n 9 || die "Інший бекап вже виконується"

START=$(date +%s)
TS=$(date +%Y%m%d-%H%M%S)
NAME="kanboard_${TS}_${APP_TAG}_${LABEL}"
DUMP="$BACKUP_DIR/${NAME}.dump"
FILES="$BACKUP_DIR/${NAME}.files.tar.gz"

write_metrics() {   # $1 = 1 (успіх) | 0 (помилка)
  mkdir -p "$TEXTFILE_DIR"
  local tmp="$TEXTFILE_DIR/ueex_backup.prom.$$" now
  now=$(date +%s)
  # попередні значення успіху зберігаємо, щоб помилка не «обнуляла» метрику
  local last_ok last_size last_offsite
  last_ok=$(awk '/^ueex_backup_last_success_timestamp_seconds /{print $2}' "$TEXTFILE_DIR/ueex_backup.prom" 2>/dev/null || true)
  last_size=$(awk '/^ueex_backup_last_size_bytes /{print $2}' "$TEXTFILE_DIR/ueex_backup.prom" 2>/dev/null || true)
  last_offsite=$(awk '/^ueex_backup_offsite_last_success_timestamp_seconds /{print $2}' "$TEXTFILE_DIR/ueex_backup.prom" 2>/dev/null || true)
  if [[ "$1" == 1 ]]; then
    last_ok=$now
    last_size=$(( $(stat -c %s "$DUMP") + $(stat -c %s "$FILES") ))
    [[ "${OFFSITE_OK:-0}" == 1 ]] && last_offsite=$now
  fi
  {
    echo "# HELP ueex_backup_last_run_timestamp_seconds Час останнього запуску бекапу"
    echo "# TYPE ueex_backup_last_run_timestamp_seconds gauge"
    echo "ueex_backup_last_run_timestamp_seconds $now"
    echo "# HELP ueex_backup_last_run_success 1 якщо останній запуск успішний"
    echo "# TYPE ueex_backup_last_run_success gauge"
    echo "ueex_backup_last_run_success $1"
    [[ -n "$last_ok" ]] && {
      echo "# HELP ueex_backup_last_success_timestamp_seconds Час останнього успішного бекапу"
      echo "# TYPE ueex_backup_last_success_timestamp_seconds gauge"
      echo "ueex_backup_last_success_timestamp_seconds $last_ok"
    }
    [[ -n "$last_size" ]] && {
      echo "# HELP ueex_backup_last_size_bytes Розмір останнього успішного бекапу"
      echo "# TYPE ueex_backup_last_size_bytes gauge"
      echo "ueex_backup_last_size_bytes $last_size"
    }
    [[ -n "$last_offsite" ]] && {
      echo "# HELP ueex_backup_offsite_last_success_timestamp_seconds Час останнього завантаження в R2"
      echo "# TYPE ueex_backup_offsite_last_success_timestamp_seconds gauge"
      echo "ueex_backup_offsite_last_success_timestamp_seconds $last_offsite"
    }
    echo "# HELP ueex_backup_last_duration_seconds Тривалість останнього запуску"
    echo "# TYPE ueex_backup_last_duration_seconds gauge"
    echo "ueex_backup_last_duration_seconds $(( now - START ))"
  } > "$tmp"
  chmod 644 "$tmp"
  mv "$tmp" "$TEXTFILE_DIR/ueex_backup.prom"   # атомарна заміна
}

DONE=0
on_exit() {
  local rc=$?
  if [[ "$DONE" != 1 ]]; then
    warn "Бекап завершився з помилкою (код $rc), прибираю неповні файли"
    rm -f "$DUMP.part" "$FILES.part"
    write_metrics 0 || true
  fi
}
trap on_exit EXIT

install -d -m 700 "$BACKUP_DIR"
log "Старт бекапу ${NAME}"

# --- 1. PostgreSQL -----------------------------------------------------------
dc exec -T db pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  --format=custom --compress=6 --no-owner --no-acl > "$DUMP.part"
# Перевірка: дамп читається pg_restore і містить дані таблиць
TABLES=$(dc exec -T db pg_restore --list < "$DUMP.part" | grep -c ' TABLE DATA ' || true)
(( TABLES > 0 )) || die "Дамп не містить даних таблиць — щось не так"
mv "$DUMP.part" "$DUMP"
log "БД: $(du -h "$DUMP" | cut -f1), таблиць з даними: ${TABLES}"

# --- 2. Файли Kanboard (вкладення) -------------------------------------------
# Використовуємо вже завантажений образ застосунку -> працює навіть якщо app зупинений
docker run --rm --entrypoint tar \
  -v "${APP_DATA_VOLUME}:/data:ro" \
  "${APP_IMAGE}:${APP_TAG}" czf - -C /data . > "$FILES.part"
mv "$FILES.part" "$FILES"
log "Файли: $(du -h "$FILES" | cut -f1)"

# --- 3. Контрольні суми --------------------------------------------------------
( cd "$BACKUP_DIR" && sha256sum "${NAME}.dump" "${NAME}.files.tar.gz" > "${NAME}.sha256" )
echo "$NAME" > "$BACKUP_DIR/LATEST"

# --- 4. Позахостова копія в R2 -----------------------------------------------
OFFSITE_OK=0
if r2_enabled; then
  log "Завантаження в $(r2_remote)/ ..."
  if rclone_r2 copy /data "$(r2_remote)" --include "${NAME}.*"; then
    OFFSITE_OK=1
    log "R2: завантажено; видаляю обʼєкти старші ${R2_RETENTION_DAYS:-30} днів"
    rclone_r2 delete "$(r2_remote)" --min-age "${R2_RETENTION_DAYS:-30}d" --include "kanboard_*" || warn "Ротація в R2 не вдалася"
  else
    warn "Завантаження в R2 не вдалося — локальна копія збережена"
  fi
else
  warn "R2_BUCKET не задано — бекап лише локальний (не переживе втрату хоста!)"
fi

# --- 5. Локальна ротація + метрики --------------------------------------------
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'kanboard_*' -mtime +"$RETENTION" -print -delete \
  | sed 's/^/[rotate] видалено /' || true

write_metrics 1
DONE=1
log "Готово: ${NAME} (за $(( $(date +%s) - START ))s)"
