#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Відновлення Kanboard з бекапу (БД + файли).
#
# Використання:
#   scripts/restore.sh --list                    # список локальних і R2-бекапів
#   scripts/restore.sh latest                    # останній локальний бекап
#   scripts/restore.sh latest --from-r2          # останній бекап з R2 (новий хост)
#   scripts/restore.sh <NAME> [--from-r2] [--yes]
#     NAME — імʼя без розширення, напр. kanboard_20261105-030000_v1.2.56_scheduled
#
# ДЕСТРУКТИВНО: поточна БД і файли Kanboard замінюються вмістом бекапу.
set -Eeuo pipefail
SCRIPT_NAME=restore
source "$(dirname "$0")/lib.sh"
load_env

BACKUP_DIR=${BACKUP_DIR:-/var/backups/ueex}
NAME="" FROM_R2=0 YES=0 LIST=0
for arg in "$@"; do
  case "$arg" in
    --from-r2) FROM_R2=1 ;;
    --yes|-y)  YES=1 ;;
    --list)    LIST=1 ;;
    -h|--help) sed -n '3,12p' "$0"; exit 0 ;;
    *)         NAME=$arg ;;
  esac
done

install -d -m 700 "$BACKUP_DIR"

if (( LIST )); then
  echo "== Локальні бекапи ($BACKUP_DIR):"
  find "$BACKUP_DIR" -maxdepth 1 -name 'kanboard_*.dump' -printf '%f\n' | sed 's/\.dump$//' | sort
  if r2_enabled; then
    echo "== R2 ($(r2_remote)):"
    rclone_r2 lsf "$(r2_remote)" --include 'kanboard_*.dump' 2>/dev/null | sed 's/\.dump$//' | sort
  fi
  exit 0
fi

[[ -n "$NAME" ]] || die "Вкажіть імʼя бекапу або 'latest' (див. --help)"

# --- 1. Визначаємо і за потреби завантажуємо бекап ----------------------------
if [[ "$NAME" == "latest" ]]; then
  if (( FROM_R2 )); then
    r2_enabled || die "R2_BUCKET не задано в .env"
    NAME=$(rclone_r2 lsf "$(r2_remote)" --include 'kanboard_*.dump' 2>/dev/null | sort | tail -n1 | sed 's/\.dump$//')
  else
    NAME=$(cat "$BACKUP_DIR/LATEST" 2>/dev/null || true)
  fi
  [[ -n "$NAME" ]] || die "Не знайдено жодного бекапу"
fi

if (( FROM_R2 )); then
  log "Завантажую ${NAME}.* з R2..."
  rclone_r2 copy "$(r2_remote)" /data --include "${NAME}.*"
fi

DUMP="$BACKUP_DIR/${NAME}.dump"
FILES="$BACKUP_DIR/${NAME}.files.tar.gz"
[[ -f "$DUMP" ]] || die "Файл $DUMP не знайдено"

if [[ -f "$BACKUP_DIR/${NAME}.sha256" ]]; then
  ( cd "$BACKUP_DIR" && sha256sum --quiet -c "${NAME}.sha256" ) || die "Контрольна сума не збігається!"
  log "Контрольні суми OK"
else
  warn "Файл контрольних сум відсутній — пропускаю перевірку"
fi

# Версія застосунку, на якій зроблено бекап (частина імені)
BACKUP_TAG=$(sed -E 's/^kanboard_[0-9]{8}-[0-9]{6}_(v[0-9.]+)_.*/\1/' <<<"$NAME")
if [[ "$BACKUP_TAG" != "$APP_TAG" ]]; then
  warn "Бекап зроблено на ${BACKUP_TAG}, а зараз APP_TAG=${APP_TAG}."
  warn "Відновлення на старішу версію застосунку, ніж у бекапі, може не спрацювати."
  warn "За потреби: sed -i 's/^APP_TAG=.*/APP_TAG=${BACKUP_TAG}/' .env"
fi

if (( ! YES )); then
  read -r -p "Поточні дані Kanboard буде ЗАМІНЕНО бекапом ${NAME}. Продовжити? [yes/N] " ans
  [[ "$ans" == "yes" ]] || die "Скасовано"
fi

# --- 2. Зупиняємо застосунок, відновлюємо БД ---------------------------------
log "Зупиняю app"
dc stop app
dc up -d db
wait_healthy db 120

log "Перестворюю БД ${POSTGRES_DB}"
dc exec -T db psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres <<SQL
DROP DATABASE IF EXISTS "${POSTGRES_DB}" WITH (FORCE);
CREATE DATABASE "${POSTGRES_DB}" OWNER "${POSTGRES_USER}";
SQL

log "pg_restore ${NAME}.dump"
dc exec -T db pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  --no-owner --no-acl --exit-on-error < "$DUMP"

# --- 3. Файли ----------------------------------------------------------------
if [[ -f "$FILES" ]]; then
  log "Відновлюю файли Kanboard у volume ${APP_DATA_VOLUME}"
  docker run --rm -i --entrypoint sh \
    -v "${APP_DATA_VOLUME}:/data" \
    "${APP_IMAGE}:${APP_TAG}" -c 'find /data -mindepth 1 -delete && tar xzf - -C /data' < "$FILES"
else
  warn "Архів файлів відсутній — відновлено лише БД"
fi

# --- 4. Запуск і перевірка ----------------------------------------------------
dc up -d app
wait_healthy app 180 || die "app не піднявся після відновлення — дивіться: docker compose logs app"

log "Перевірка даних:"
dc exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -F ' | ' -c \
  "SELECT 'projects', count(*) FROM projects UNION ALL
   SELECT 'tasks',    count(*) FROM tasks    UNION ALL
   SELECT 'users',    count(*) FROM users;"
log "Відновлення з ${NAME} завершено"
