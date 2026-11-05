#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Підготовка чистого Debian-хоста (12 bookworm / 13 trixie). Ідемпотентний.
#   - пакети, Docker Engine + Compose plugin з офіційного репозиторію Docker
#   - /etc/docker/daemon.json (ротація логів контейнерів, live-restore)
#   - ліміт journald, swap 2G (якщо swap відсутній), часовий пояс, UFW (22/80/443)
#
# Використання (root):  ./scripts/bootstrap-host.sh
set -Eeuo pipefail
SCRIPT_NAME=bootstrap
source "$(dirname "$0")/lib.sh"
require_root

# shellcheck source=/dev/null
. /etc/os-release
[[ "$ID" == "debian" ]] || die "Очікується Debian, знайдено: $ID"
log "Debian ${VERSION_ID} (${VERSION_CODENAME})"

export DEBIAN_FRONTEND=noninteractive

# --- Пакети ----------------------------------------------------------------
apt-get update -q
apt-get upgrade -yq
apt-get install -yq ca-certificates curl gnupg git openssl ufw jq

# --- Docker Engine -----------------------------------------------------------
if ! command -v docker >/dev/null; then
  log "Встановлюю Docker Engine"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get install -yq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  log "Docker вже встановлено: $(docker --version)"
fi
systemctl enable --now docker containerd

# Ротація логів контейнерів; рестарт Docker лише якщо конфіг змінився
if ! cmp -s "$REPO_DIR/host/docker-daemon.json" /etc/docker/daemon.json; then
  log "Оновлюю /etc/docker/daemon.json і перезапускаю Docker"
  install -m 0644 "$REPO_DIR/host/docker-daemon.json" /etc/docker/daemon.json
  systemctl restart docker
fi
log "Docker: $(docker --version); $(docker compose version)"

# --- journald: обмеження розміру системних логів ------------------------------
install -d /etc/systemd/journald.conf.d
if ! cmp -s "$REPO_DIR/host/journald-ueex.conf" /etc/systemd/journald.conf.d/ueex.conf; then
  install -m 0644 "$REPO_DIR/host/journald-ueex.conf" /etc/systemd/journald.conf.d/ueex.conf
  systemctl restart systemd-journald
fi

# --- Swap (на 2 GB RAM Prometheus+Grafana без swap ризикують OOM) -------------
if ! swapon --show | grep -q .; then
  log "Swap відсутній — створюю /swapfile 2G"
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-ueex-swap.conf
  sysctl -q --system
else
  log "Swap вже є: $(swapon --show --noheadings | awk '{print $1, $3}' | paste -sd ' ')"
fi

# --- Час ----------------------------------------------------------------------
timedatectl set-timezone Europe/Kyiv || warn "Не вдалося встановити часовий пояс"

# --- Firewall ------------------------------------------------------------------
# Docker публікує порти через власні правила iptables в обхід UFW, тому в compose.yaml
# публічно відкриті лише 80/443, а Prometheus/Alertmanager привʼязані до 127.0.0.1.
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
ufw status

log "Хост підготовлено. Далі: .env (з менеджера паролів) -> ./scripts/install.sh"
