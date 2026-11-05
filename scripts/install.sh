#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Розгортання стека на підготовленому хості (після bootstrap-host.sh). Ідемпотентний.
#   - перевірка .env
#   - каталоги бекапів/метрик, self-signed сертифікат, конфіг Alertmanager
#   - systemd: автозапуск стека після перезавантаження + таймер бекапів
#   - pull образів, запуск, очікування healthy
#
# Використання (root):  ./scripts/install.sh
set -Eeuo pipefail
SCRIPT_NAME=install
source "$(dirname "$0")/lib.sh"
require_root
command -v docker >/dev/null || die "Docker не встановлено — спочатку scripts/bootstrap-host.sh"

# --- .env ---------------------------------------------------------------------
[[ -f .env ]] || die "Немає .env — візьміть з менеджера паролів (або cp .env.example .env)"
chmod 600 .env
load_env
if grep -qE '=change-me$' .env; then
  die "У .env залишились значення change-me — заповніть паролі"
fi
[[ "$POSTGRES_PASSWORD" =~ ^[A-Za-z0-9]+$ ]] || die "POSTGRES_PASSWORD має містити лише [A-Za-z0-9]"
r2_enabled || warn "R2_BUCKET не задано — бекапи будуть лише локальні"

# --- Каталоги -------------------------------------------------------------------
install -d -m 700 "${BACKUP_DIR:-/var/backups/ueex}"
install -d -m 755 "${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
mkdir -p "$STATE_DIR"

# --- Конфіги, що генеруються з .env -------------------------------------------
"$REPO_DIR/scripts/gen-cert.sh"
"$REPO_DIR/scripts/render-config.sh"

# --- systemd -------------------------------------------------------------------
for unit in ueex-stack.service ueex-backup.service ueex-backup.timer; do
  sed "s|@REPO_DIR@|${REPO_DIR}|g" "systemd/${unit}" > "/etc/systemd/system/${unit}"
done
systemctl daemon-reload
systemctl enable ueex-stack.service
systemctl enable --now ueex-backup.timer

# --- Запуск ------------------------------------------------------------------------
log "Pull образів"
dc pull -q
log "Запуск стека"
systemctl start ueex-stack.service
dc up -d --remove-orphans   # якщо unit вже був active — застосовуємо зміни явно

for svc in db app nginx prometheus alertmanager grafana; do
  wait_healthy "$svc" 180 || die "Сервіс ${svc} не healthy — docker compose logs ${svc}"
done

curl -ksf -o /dev/null https://127.0.0.1/healthcheck.php && log "HTTPS через nginx: OK"

cat <<MSG

================================================================================
 Стек запущено.
   Kanboard:      https://${SERVER_NAME}/          (новий інстанс: admin / admin — змініть!)
   Grafana:       https://${SERVER_NAME}/grafana/  (${GRAFANA_ADMIN_USER:-admin} / пароль з .env)
   Prometheus:    ssh -L 9090:127.0.0.1:9090 root@${SERVER_NAME}  ->  http://localhost:9090
   Alertmanager:  ssh -L 9093:127.0.0.1:9093 root@${SERVER_NAME}  ->  http://localhost:9093
   Бекапи:        systemctl list-timers ueex-backup.timer
================================================================================
MSG
dc ps --format 'table {{.Service}}\t{{.Status}}'
