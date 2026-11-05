# Демонстрація виконання завдання

Сценарій, що показує кожен пункт завдання, з очікуваним результатом.
Передумова: стек розгорнуто за [RUNBOOK.md](RUNBOOK.md) (кроки 2–6), Telegram і R2 налаштовані
([OPERATIONS.md §9](OPERATIONS.md#9-налаштування-інтеграцій-telegram-і-cloudflare-r2)),
у Kanboard змінено пароль `admin`. Команди — від `root` у `/opt/ueex-stack`.

Для зручності:
```bash
cd /opt/ueex-stack && source .env
read -rsp "Пароль admin у Kanboard: " KB_PASS; echo
kb() {  # виклик JSON-RPC API Kanboard через nginx
  curl -ks -u "admin:${KB_PASS}" https://127.0.0.1/jsonrpc.php \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":${2:-{\}}}"; echo; }
```

---

## 01. Розгортання стека

```bash
docker compose ps
curl -sI http://127.0.0.1/ | head -3                    # 301 -> https
curl -kI https://127.0.0.1/ | head -1                   # HTTP/2 302 (редирект на логін Kanboard)
echo | openssl s_client -connect 127.0.0.1:443 2>/dev/null | openssl x509 -noout -subject -issuer -ext subjectAltName
```
Очікувано: усі сервіси `Up (healthy)`; subject = issuer (self-signed), SAN = `SERVER_NAME`.
У браузері `https://<SERVER_NAME>/` — попередження про self-signed сертифікат, далі логін Kanboard.

Kanboard справді працює на PostgreSQL:
```bash
docker compose exec db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c '\dt' | head
```

## 02. Моніторинг і сповіщення

1. Grafana `https://<SERVER_NAME>/grafana/` → **UEEX → «UEEX — огляд стека»**: Kanboard / PostgreSQL = UP.
2. Недоступність **БД**:
   ```bash
   docker compose stop db
   ```
   Через ~1.5 хв: у Telegram **[FIRING] PostgresDown**; на дашборді PostgreSQL = DOWN.
   `ApplicationDown` теж активний у Prometheus, але **не надсилається** (inhibit — першопричина БД).
   ```bash
   docker compose start db
   ```
   Через ~1 хв: **[RESOLVED] PostgresDown**.
3. Недоступність **застосунку**:
   ```bash
   docker compose stop app      # ~1.5 хв -> [FIRING] ApplicationDown
   docker compose start app     # ~1 хв   -> [RESOLVED]
   ```
4. Prometheus → *Alerts* (через SSH-тунель, див. OPERATIONS §6) — правила і їхній стан.
5. Юніт-тести правил: `./scripts/validate.sh` → `SUCCESS`.

## 03. Експлуатація

**Health-check:** колонка STATUS у `docker compose ps` → `(healthy)`. Деталі:
```bash
docker inspect -f '{{json .State.Health}}' $(docker compose ps -q app) | jq '.Status, .Log[-1]'
```

**Автозапуск після перезавантаження:**
```bash
systemctl is-enabled docker ueex-stack.service
reboot
# після перепідключення (1–2 хв):
uptime && docker compose -f /opt/ueex-stack/compose.yaml ps
```
Очікувано: свіжий `uptime`, усі сервіси `Up (healthy)`.

**Ротація логів:**
```bash
cat /etc/docker/daemon.json
docker inspect -f '{{.HostConfig.LogConfig}}' $(docker compose ps -q nginx)   # max-size:10m max-file:5
ls -lh /var/lib/docker/containers/*/*-json.log
journalctl --disk-usage
```

## 04. Резервне копіювання та відновлення

```bash
systemctl list-timers ueex-backup.timer          # розклад: щодня 03:00
kb createProject '{"name":"Backup demo"}'         # -> {"result": <id>}
kb getAllProjects | jq '.result[].name'
./scripts/backup.sh manual                        # ... R2: завантажено ... Готово
ls -lh /var/backups/ueex/
```
Імітуємо втрату даних — видаляємо проєкт (у UI або API):
```bash
kb removeProject '{"project_id": <id>}'
kb getAllProjects | jq '.result[].name'           # "Backup demo" зник
```
Відновлення:
```bash
./scripts/restore.sh latest                       # y
kb getAllProjects | jq '.result[].name'           # "Backup demo" повернувся
```
Те саме з R2 (як на новому хості): `./scripts/restore.sh latest --from-r2`.

## 05. Оновлення та відкат

```bash
grep APP_TAG .env                                 # v1.2.56
kb createTask '{"title":"Created before update","project_id": <id>}'
./scripts/update.sh v1.2.57
```
Очікувано: pull → бекап `..._pre-update` → перестворено лише `app` → `Оновлення успішне: працює kanboard/kanboard:v1.2.57`.
```bash
docker compose ps app                             # image v1.2.57, healthy; db не перезапускався (див. CREATED)
kb getAllTasks '{"project_id": <id>}' | jq '.result[].title'   # задача на місці
kb createTask '{"title":"Created after update","project_id": <id>}'
```
Відкат:
```bash
./scripts/rollback.sh                             # y -> v1.2.56
kb getAllTasks '{"project_id": <id>}' | jq '.result[].title'   # обидві задачі на місці
cat .deploy/history.log
```
Відкат з даними (повернення БД до стану до оновлення — «Created after update» зникне):
```bash
./scripts/update.sh v1.2.57 && ./scripts/rollback.sh --restore-db
```
Автовідкат при невдалому оновленні: `./scripts/update.sh v9.9.9` → падає на `docker pull` без жодних змін.

## 06. Git і документація

- Уся конфігурація — у цьому репозиторії; секрети — лише в `.env` (у `.gitignore`), шаблон — `.env.example`.
- CI (`.github/workflows/validate.yml`): shellcheck, `docker compose config`, `promtool` + юніт-тести алертів.
- Runbook: [docs/RUNBOOK.md](RUNBOOK.md). Перевірено навчанням 2026-11-05: окремий чистий
  VPS піднято строго за інструкцією з відновленням даних з R2 за ~12 хв (журнал — у кінці RUNBOOK).
