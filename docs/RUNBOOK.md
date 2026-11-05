# RUNBOOK: Сервер впав — як підняти сервіс на новому хості з нуля

> **Мета:** відновити Kanboard з даними з останнього бекапу на новому чистому Debian-хості.
> **Орієнтовний час (RTO):** 20–30 хв (фактично на навчанні 2026-11-05 — ~12 хв, див. журнал внизу). **Можлива втрата даних (RPO):** до 24 год
> (щоденний бекап о 03:00; перед кожним оновленням робиться додатковий).
>
> Усі команди виконуються від `root` на **новому** хості, якщо не сказано інше.
> Кожен крок має блок «Перевірка» — не переходьте далі, поки перевірка не пройшла.

---

## 0. Що потрібно мати перед початком

| Що | Де взяти |
|---|---|
| Доступ до хмарного провайдера (створення VPS) | обліковий запис Vultr |
| Вміст файлу `.env` робочого сервера | менеджер паролів, запис **«UEEX stack .env»** |
| Адреса Git-репозиторію | `https://github.com/Deadflixer/ueex-devops-assignment.git` |
| Доступ до Cloudflare R2 (лише для перевірки/діагностики) | Cloudflare → R2 → бакет з `R2_BUCKET` у `.env` |
| SSH-ключ | ваш локальний ключ, доданий при створенні VPS |

> ⚠️ Без `.env` відновлення неможливе: там паролі БД/Grafana і ключі R2.
> Бекапи лежать у R2 і **не залежать** від мертвого сервера.

## 1. Зафіксувати інцидент і переконатися, що сервер справді втрачено

```bash
# з робочої машини
ping -c3 <OLD_IP>
ssh root@<OLD_IP> 'docker compose -f /opt/ueex-stack/compose.yaml ps'
```

- Якщо SSH працює і проблема лише в стеку — **зупиніться**, вам потрібен не цей runbook,
  а [OPERATIONS.md](OPERATIONS.md) (`docker compose ps`, `logs`, `restore.sh`).
- Якщо хост недоступний / диск втрачено — продовжуйте. Перевірте в панелі провайдера, чи можна
  його просто перезавантажити (Restart) — це швидше, ніж відновлення.

## 2. Створити новий сервер

У панелі Vultr: **Deploy → Cloud Compute (Shared CPU)**

| Параметр | Значення |
|---|---|
| Image | **Debian 13 x64** (або 12) |
| Plan | мінімум **2 vCPU / 2 GB RAM / 50+ GB** |
| SSH Keys | ваш ключ |
| Auto Backups | вимкнено (бекапи робимо самі) |

Запишіть **новий IP** — далі `<NEW_IP>`.

**Перевірка:** `ssh root@<NEW_IP> 'cat /etc/os-release | head -2'` показує Debian.

## 3. Отримати код

```bash
apt-get update && apt-get install -y git
git clone https://github.com/Deadflixer/ueex-devops-assignment.git /opt/ueex-stack
cd /opt/ueex-stack
git log -1 --oneline
```

> Якщо репозиторій приватний: `ssh-keygen -t ed25519 -N "" -f ~/.ssh/github_ueex`, додайте
> `~/.ssh/github_ueex.pub` у GitHub → репозиторій → Settings → Deploy keys (read-only),
> і клонуйте через `GIT_SSH_COMMAND="ssh -i ~/.ssh/github_ueex" git clone git@github.com:Deadflixer/ueex-devops-assignment.git /opt/ueex-stack`.

**Перевірка:** у `/opt/ueex-stack` є `compose.yaml`, `scripts/`, `docs/`.

## 4. Підготувати хост (Docker, ротація логів, swap, firewall)

```bash
cd /opt/ueex-stack
./scripts/bootstrap-host.sh
```

Скрипт ідемпотентний — його можна безпечно запускати повторно.

**Перевірка:**
```bash
docker --version && docker compose version
cat /etc/docker/daemon.json          # max-size 10m, max-file 5
swapon --show                        # swap є (створюється 2G, якщо його не було)
ufw status                           # 22, 80, 443 ALLOW
```

## 5. Відновити `.env`

```bash
cd /opt/ueex-stack
nano .env              # вставити вміст запису «UEEX stack .env» з менеджера паролів
chmod 600 .env
```

**Обовʼязково змініть** `SERVER_NAME` на новий IP (або DNS-імʼя):
```bash
sed -i "s/^SERVER_NAME=.*/SERVER_NAME=<NEW_IP>/" .env
grep -E '^(SERVER_NAME|APP_TAG|R2_BUCKET)=' .env
```

> `APP_TAG` має бути **не старішим** за версію, на якій зроблено бекап (вона є в імені бекапу,
> див. крок 7). Якщо сумніваєтесь — залиште значення з менеджера паролів.

**Перевірка:** `grep -c change-me .env` повертає `0`; `R2_BUCKET` і `R2_*` заповнені.

## 6. Розгорнути стек

```bash
./scripts/install.sh
```

Скрипт: генерує новий self-signed сертифікат під `SERVER_NAME`, конфіг Alertmanager,
встановлює systemd-юніти (автозапуск + таймер бекапу), завантажує образи і чекає, поки всі
сервіси стануть `healthy`. На цьому етапі Kanboard **порожній** (новий інстанс) — це нормально.

**Перевірка:**
```bash
docker compose ps                                  # усі сервіси (healthy)
curl -k -o /dev/null -w '%{http_code}\n' https://127.0.0.1/   # 200 або 302
systemctl is-enabled ueex-stack.service ueex-backup.timer      # enabled enabled
```

## 7. Відновити дані з останнього бекапу в R2

```bash
./scripts/restore.sh --list                 # переконатися, що бекапи в R2 видно
./scripts/restore.sh latest --from-r2       # підтвердити: y
```

Скрипт завантажує дамп і архів файлів з R2, звіряє sha256, зупиняє застосунок, перестворює БД,
виконує `pg_restore`, відновлює вкладення, запускає застосунок і виводить кількість
проєктів/задач/користувачів.

Якщо скрипт попередив, що бекап зроблено на іншій версії (`Бекап зроблено на vX, а зараз APP_TAG=vY`)
і застосунок не піднявся:
```bash
sed -i 's/^APP_TAG=.*/APP_TAG=vX/' .env     # vX — з повідомлення
docker compose up -d app
```

**Перевірка:**
- вивід `restore.sh` містить ненульові `projects` / `tasks`;
- `docker compose ps app` → `healthy`.

## 8. Функціональна перевірка

1. Відкрити `https://<NEW_IP>/` (браузер попередить про self-signed сертифікат — це очікувано).
2. Увійти **обліковим записом з робочого сервера** (не admin/admin — користувачі відновились з бекапу).
3. Переконатися, що проєкти й задачі на місці, вкладення відкриваються.
4. Grafana: `https://<NEW_IP>/grafana/` → дашборд **UEEX → «UEEX — огляд стека»**:
   Kanboard/PostgreSQL = **UP**, «Активні алерти» = 0 (через 1–2 хв після старту).
5. Тест алертингу (за бажанням, ~2 хв): `docker compose stop app` → у Telegram приходить
   `ApplicationDown` → `docker compose start app` → приходить `RESOLVED`.

## 9. Відновити регулярні бекапи і зробити контрольний

```bash
systemctl start ueex-backup.service
journalctl -u ueex-backup.service -n 20 --no-pager    # «Готово: kanboard_...», «R2: завантажено»
systemctl list-timers ueex-backup.timer               # наступний запуск о 03:00
```

## 10. Після відновлення

- [ ] Спрямувати користувачів на новий сервер:
      - **сервіс доступний за IP** — повідомити користувачам нову адресу `https://<NEW_IP>/`;
      - **сервіс доступний за доменом** — змінити A-запис домену на `<NEW_IP>`, потім на сервері
        вписати домен у `.env` і перевипустити сертифікат під нього:
        `sed -i 's/^SERVER_NAME=.*/SERVER_NAME=<DOMAIN>/' .env && ./scripts/gen-cert.sh --force && docker compose up -d nginx grafana`
- [ ] Оновити запис «UEEX stack .env» у менеджері паролів: на кроці 5 `SERVER_NAME` змінено лише
      у файлі на сервері, а копія в менеджері паролів досі містить стару адресу.
- [ ] Видалити старий сервер у панелі провайдера (**Destroy**), якщо він не повернеться —
      він продовжує тарифікуватися навіть вимкненим.
- [ ] Записати інцидент: час виявлення, причина, час відновлення, втрачені дані (різниця між
      часом бекапу з імені файлу і часом падіння).

---

## Діагностика типових проблем

| Симптом | Причина / дія |
|---|---|
| `install.sh`: «У .env залишились значення change-me» | Вставлено `.env.example`, а не робочий `.env` — візьміть з менеджера паролів |
| `restore.sh --list` не показує R2 | Перевірте `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET` у `.env`; токен має право **Object Read** на бакет; для EU-бакета потрібен `R2_ENDPOINT` з `.eu.` |
| `Контрольна сума не збігається!` | Файл пошкоджено при завантаженні — повторіть; або візьміть попередній бекап: `./scripts/restore.sh --list` → `./scripts/restore.sh <NAME> --from-r2` |
| `app` не стає healthy після restore | `docker compose logs --tail 100 app`; найчастіше `APP_TAG` старіший за версію бекапу (крок 7) |
| `app` unhealthy, у логах помилки підключення до БД | `docker compose ps db`, `docker compose logs db`; пароль у `.env` має збігатися з тим, з яким створено volume. На новому хості volume новий — збіг гарантовано |
| Браузер: `ERR_CONNECTION_REFUSED` | `ufw status` (80/443), `docker compose ps nginx`, `docker compose logs nginx` |
| Grafana 502 | `docker compose ps grafana`; Grafana стартує приблизно на 30 секунд пізніше за інші сервіси — зачекайте і оновіть сторінку |
| Немає алертів у Telegram | `TELEGRAM_*` у `.env` → `./scripts/render-config.sh && docker compose restart alertmanager`; бот має бути доданий у чат, `chat_id` групи — відʼємне число |
| Мало памʼяті / OOM | `free -h`, `docker stats --no-stream`; переконайтесь, що swap увімкнено (крок 4) |

---

## Журнал перевірок runbook

| Дата | Що перевірено | Результат | Знахідки |
|---|---|---|---|
| 2026-11-05 | Повне відновлення на новому чистому VPS (Vultr, Debian 13, 2 vCPU / 2 GB) строго за цим документом, дані з Cloudflare R2 | ✅ RTO ~12 хв (створення VPS → крок 8). Усі 9 сервісів healthy, проєкти/задачі/користувачі відновлені, вхід наявним обліковим записом, бекап з нового хоста йде в R2 | `render-config.sh` падав: каталог `monitoring/alertmanager/` відсутній у свіжому клоні (Git не зберігає порожні каталоги) — виправлено в `3c20cd8` |

Рекомендована періодичність навчання — раз на квартал і після суттєвих змін стека.
