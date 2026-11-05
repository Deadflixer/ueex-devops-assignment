# Експлуатація стека

Усі команди — від `root` у каталозі `/opt/ueex-stack`.

## Зміст
1. [Стан і логи](#1-стан-і-логи)
2. [Запуск, зупинка, автозапуск](#2-запуск-зупинка-автозапуск)
3. [Резервне копіювання](#3-резервне-копіювання)
4. [Відновлення з бекапу](#4-відновлення-з-бекапу)
5. [Оновлення і відкат застосунку](#5-оновлення-і-відкат-застосунку)
6. [Моніторинг і алерти](#6-моніторинг-і-алерти)
7. [Ротація логів](#7-ротація-логів)
8. [TLS-сертифікат](#8-tls-сертифікат)
9. [Налаштування інтеграцій: Telegram і Cloudflare R2](#9-налаштування-інтеграцій-telegram-і-cloudflare-r2)

---

## 1. Стан і логи

```bash
docker compose ps                         # стан і health усіх сервісів
docker compose logs -f --tail 100 app     # логи сервісу (app, db, nginx, prometheus, ...)
docker stats --no-stream                  # CPU / RAM контейнерів
systemctl status ueex-stack.service       # unit автозапуску
journalctl -u ueex-backup.service -n 50   # логи бекапів
cat .deploy/history.log                   # історія оновлень/відкатів
```

Health-check кожного сервісу:

| Сервіс | Перевірка |
|---|---|
| db | `pg_isready` |
| app | `GET /healthcheck.php` — Kanboard виконує `SELECT 1` у БД |
| nginx | `GET /healthz` на :80 |
| prometheus / alertmanager / blackbox | `GET /-/healthy` |
| grafana | `GET /api/health` |
| node-exporter / postgres-exporter | `GET /metrics` |

## 2. Запуск, зупинка, автозапуск

```bash
systemctl start ueex-stack.service     # = docker compose up -d
systemctl stop ueex-stack.service      # = docker compose stop (дані зберігаються)
docker compose restart nginx           # перезапуск окремого сервісу
```

Автозапуск після перезавантаження хоста забезпечується двома механізмами:
- `docker.service` enabled + `restart: unless-stopped` у кожного контейнера;
- `ueex-stack.service` (enabled) виконує `docker compose up -d` після старту Docker — стек
  піднімається, навіть якщо його перед цим зупинили через `docker compose down`/`stop`.

Перевірка: `reboot`, через 1–2 хв `docker compose ps` — усі сервіси `Up (healthy)`.

> ⚠️ `docker compose down -v` **видаляє volumes з даними**. Ніколи не використовуйте `-v` на робочому сервері.

## 3. Резервне копіювання

**Що:** дамп БД (`pg_dump -Fc`) + архів volume `kanboard_data` (вкладення) + `sha256`.
**Коли:** щодня о 03:00 (`ueex-backup.timer`, `Persistent=true` — пропущений запуск виконується після старту), а також автоматично перед кожним `update.sh`.
**Куди:** `/var/backups/ueex` (зберігається `BACKUP_RETENTION_DAYS`, за замовч. 7 днів) і Cloudflare R2 (`R2_RETENTION_DAYS`, 30 днів).

```bash
./scripts/backup.sh manual                 # бекап вручну
systemctl start ueex-backup.service        # або через systemd, як за розкладом
systemctl list-timers ueex-backup.timer    # наступний запуск
ls -lh /var/backups/ueex/                  # локальні бекапи
cat /var/lib/node_exporter/textfile/ueex_backup.prom   # метрики останнього бекапу
```

Імʼя бекапу: `kanboard_<YYYYmmdd-HHMMSS>_<APP_TAG>_<label>` — з нього видно час і версію застосунку.

Контроль: алерти `BackupTooOld` / `BackupOffsiteTooOld` (немає успішного бекапу / копії в R2 понад 26 год),
панель «Вік останнього бекапу» в Grafana.

Змінити розклад: `systemctl edit ueex-backup.timer` →
```ini
[Timer]
OnCalendar=
OnCalendar=*-*-* 00/6:00:00
```

## 4. Відновлення з бекапу

```bash
./scripts/restore.sh --list                         # локальні та R2-бекапи
./scripts/restore.sh latest                         # останній локальний
./scripts/restore.sh latest --from-r2               # останній з R2
./scripts/restore.sh kanboard_20261105-030012_v1.2.56_scheduled [--from-r2] [--yes]
```
Підтвердження деструктивних дій (`restore.sh`, `rollback.sh`): `y` / `yes`; для автоматизації — `--yes`.

Що відбувається: перевірка sha256 → зупинка `app` → `DROP/CREATE DATABASE` → `pg_restore` →
відновлення файлів → запуск `app` → очікування healthy → вивід кількості проєктів/задач/користувачів.

## 5. Оновлення і відкат застосунку

Версія застосунку задається єдиною змінною `APP_TAG` у `.env`. Скрипти змінюють її самі.

```bash
./scripts/update.sh v1.2.57
```
1. `docker pull` нового образу (до будь-якого простою; неіснуючий тег — помилка без змін);
2. бекап з міткою `pre-update`;
3. збереження стану для відкату в `.deploy/` (`previous_tag`, `pre_update_backup`);
4. `APP_TAG=v1.2.57` у `.env`, перестворення **лише** контейнера `app` (`--no-deps`).
   БД і volumes не зачіпаються — дані зберігаються; міграції схеми Kanboard виконує сам при старті;
5. очікування `healthy` + запит через nginx;
6. якщо перевірка не пройшла — **автоматичний відкат** образу.

Відкат вручну:
```bash
./scripts/rollback.sh               # повернути попередній образ; дані, створені після оновлення, зберігаються
./scripts/rollback.sh --restore-db  # образ + БД/файли з бекапу pre-update
```
`--restore-db` потрібен, якщо нова версія змінила схему БД несумісно зі старою
(стара версія після простого відкату не стає healthy). Ціна — втрата змін, зроблених після оновлення.
Повторний `rollback.sh` повертає вперед (стан міняється місцями).

## 6. Моніторинг і алерти

| Інтерфейс | Адреса |
|---|---|
| Grafana | `https://<SERVER_NAME>/grafana/` → папка **UEEX** → «UEEX — огляд стека» |
| Prometheus | `ssh -L 9090:127.0.0.1:9090 root@<SERVER_NAME>` → http://localhost:9090 |
| Alertmanager | `ssh -L 9093:127.0.0.1:9093 root@<SERVER_NAME>` → http://localhost:9093 |

Алерти (`monitoring/prometheus/rules/alerts.yml`):

| Алерт | Умова | Severity |
|---|---|---|
| **ApplicationDown** | `probe_success == 0` 1 хв (через nginx або напряму в app) | critical |
| **PostgresDown** | `pg_up == 0` 1 хв | critical |
| ScrapeTargetDown | будь-яка ціль Prometheus недоступна 2 хв | warning |
| BackupTooOld / BackupOffsiteTooOld | немає успішного бекапу / копії в R2 понад 26 год | warning |
| BackupMetricMissing | метрики бекапу немає 30 год | warning |
| HostDiskSpaceLow | на `/` < 15% місця | warning |
| TLSCertExpiringSoon | сертифікат спливає < 14 днів | warning |

Inhibit: поки активний `PostgresDown`, `ApplicationDown` не надсилається (першопричина — БД).

Зміни правил: відредагувати `alerts.yml`, перевірити і перечитати без рестарту:
```bash
./scripts/validate.sh                                # promtool check + юніт-тести алертів
curl -X POST http://127.0.0.1:9090/-/reload
```

## 7. Ротація логів

- Контейнери: драйвер `json-file`, `max-size: 10m`, `max-file: 5` (≤ 50 MB на контейнер).
  Задано і в `compose.yaml` (`x-logging`), і глобально в `/etc/docker/daemon.json`.
- systemd-журнал (бекапи, docker.service): `SystemMaxUse=500M`, `MaxRetentionSec=30day`
  (`/etc/systemd/journald.conf.d/ueex.conf`).

Перевірка:
```bash
docker inspect -f '{{.HostConfig.LogConfig}}' $(docker compose ps -q app)
# {json-file map[max-file:5 max-size:10m]}
journalctl --disk-usage
```

## 8. TLS-сертифікат

Self-signed, 365 днів, SAN = `SERVER_NAME`. Строк контролює алерт `TLSCertExpiringSoon`.
```bash
openssl x509 -in nginx/certs/server.crt -noout -subject -enddate -ext subjectAltName
./scripts/gen-cert.sh --force && docker compose restart nginx     # перевипуск
```

## 9. Налаштування інтеграцій: Telegram і Cloudflare R2

### Telegram (доставка алертів)
1. У Telegram: `@BotFather` → `/newbot` → отримати токен.
2. Написати боту будь-яке повідомлення (або додати його в групу).
3. Дізнатись `chat_id`:
   `curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | jq '.result[].message.chat.id'`
4. Заповнити `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` у `.env`, застосувати:
   `./scripts/render-config.sh && docker compose restart alertmanager`

### Cloudflare R2 (позахостові бекапи)
1. Cloudflare Dashboard → **R2** → **Create bucket** (напр. `ueex-backups`).
2. **R2 → Manage API tokens → Create API token**: права **Object Read & Write**, лише на цей бакет.
3. Заповнити в `.env`: `R2_ACCOUNT_ID` (R2 → Overview), `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET`.
   Для бакета з jurisdiction (EU) додатково `R2_ENDPOINT=https://<account_id>.eu.r2.cloudflarestorage.com`.
4. Перевірити: `./scripts/backup.sh manual` → у виводі `R2: завантажено`; `./scripts/restore.sh --list`.
