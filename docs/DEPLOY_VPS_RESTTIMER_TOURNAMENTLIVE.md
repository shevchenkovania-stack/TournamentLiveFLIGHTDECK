# Деплой рестримера на сервер — Restrimer_TournamentLive (22.10.2026)

Рабочий статус переноса ретранслятора с локальной машины на сервер. Читай это,
если нужно продолжить завтра / после перезагрузки / сменить ключи.

---

## 0. Итог одним абзацем
Стек (`mediamtx + supervisor + relayer + caddy`) развёрнут и **проверен живым прогодом**
в директории `/root/Restrimer_TournamentLive` на сервере `172.22.22.17` (Debian 12).
Выходы `broadcast/a..h` непрерывны (замена live↔заставка без ухода в ноль), панель
доступна по `http://172.22.22.17:8070`, автозапуск systemd включён. Локально ничего держать
не нужно.

---

## 1. Сервер и доступ
- Хост: `CT101`, **Debian 12 (bookworm)**, ядро Proxmox (`-pve`) — это VM/LXC.
- IP: `172.22.22.17` — **приватный (LAN)**. Docker + Compose v2 уже были.
- Вход по **SSH-ключу** (пароль не используется). Приватная часть лежит на рабочей
  машине в `.deploy-keys/tl_vps_deploy` (в `.gitignore`, в git НЕ попадает).
  Публичный ключ добавлен в `~/.ssh/authorized_keys` сервера.
- Подключиться:
  ```powershell
  ssh -i .deploy-keys\tl_vps_deploy root@172.22.22.17
  ```

⚠️ Смена пароля root-сервера: старый был показан в чате — считается скомпрометированным.

---

## 2. Что где лежит на сервере
```
/root/Restrimer_TournamentLive/
├── relay/                 # relayer.sh + Dockerfile (билд tl-relayer:loca
├── panel/index.html       # кокпит (монтируется в caddy как /srv/panel)
└── deploy/vps/
    ├── docker-compose.yml # IP/LAN-режим: опубликованы 1935, 8888, 8070->80, 443
    │                      # (хостовый :80 занят другой службой → панель на :8070)
    ├── mediamtx.yml       # 16 путей; record: no; auth только 'any' (см. §4)
    ├── Caddyfile          # HTTP на IP, BasicAuth, /v3 через handle (см. §4)
    ├── panel/config.js    # playerOrigin = http://172.22.22.17:8888
    ├── fallback/*.mp4     # 8 стоп-карт
    ├── outputs/           # outputs.conf (sample) + outputs.local.conf (ключи)
    ├── supervisor/        # Dockerfile + supervisor.sh + ctl.py
    ├── .env               # MTX_ADMIN_USER (anonymous-API, пароля нет)
    ├── .env.panel         # PANEL_HASH (bcrypt) — НЕ коммитить, на сервере
    └── systemd/           # (копия; юнит поставлен в /etc/systemd/system)
```
Структура `relay/` + `panel/` на два уровня выше `deploy/vps` обязательна — на них
ссылается compose (`build: ../../relay`, монтирование `../../panel/index.html`).

⚠️ **Не переносить поверх серверного `docker-compose.yml` версию из репозитория** —
в репо доменный шаблон (80->80, без 8888), на сервере LAN-режим (8070->80, 8888
опубликован). При правке compose в репо — переносить только содержательные строки
(env/volumes), порты сервера оставлять как есть. (26.10 случайно перезаписал — откатано
обратно через `sed` + `up -d`, бэкап `docker-compose.yml.bak.*` на сервере.)

---

## 3. Управление (команды на сервере)

**Экраны и ключи (с 26.10.2026, нумерованная модель):** карточки панели — **ЭКРАН 1..8**
(выходы `broadcast/a..h` = те же экраны внутри). Входы переименованы в `tatami/1..8`:
ключ N попадает ровно на экран N — маршрутизации/`auto`/pin больше нет (supervisor
следит за `tatami/<N>` и кормит `broadcast/<letter>`). Имя «татами/турнир» — свободный
текст на карточке, хранится в `outputs/labels.json` (API `GET/POST /ctl/labels`).
**Количество экранов динамическое (с 26.10.2026):** панель показывает только экраны `1..N`
(`outputs/screens.conf`, по умолчанию 2; кнопки «➕/−» -> API `GET/POST /ctl/screens`),
supervisor кормит только активные, остальных тихо гасит; площадочные настройки убранного
экрана сохраняются в `outputs.local.conf` и возвращаются при добавлении обратно.
⚙️ На сервере правка выполнена точечно: `sed` по путям `mediamtx.yml` (сохранён серверный
`record: no`), бэкапы `mediamtx.yml.bak.keys`, `docker-compose.yml.bak.keys`.
⚠️ Файлы репозитория `mediamtx*.yml` имеют `record: yes` — при новом боевом деплое это
различие надо учитывать (на сервере запись выключена из-за диска).
```bash
cd /root/Restrimer_TournamentLive/deploy/vps
docker compose up -d --build           # поднять/обновить всё
docker compose ps                       # статус
docker compose logs -f supervisor       # live<->fallback переключения
docker compose restart mediamtx supervisor caddy
# После правки mediamtx.yml / Caddyfile / config.js / index.html — ОБЯЗАТЕЛЬНО:
docker compose up -d --force-recreate mediamtx caddy   # одиночные ro-монты не пересобираются сами
```
Проверка путей (ожидаем 16):
```bash
docker exec tl-supervisor curl -s http://mediamtx:9997/v3/paths/list | grep -o '"name"' | wc -l
```

---

## 4. Что пришлось починить (это баги боевой конфигурации, а не случайность)
1. **MediaMTX v1.21.2 не принимает поле `password`** в `authInternalUsers[].password`
   → mediamtx падал по кругу (`json: unknown field`). Убран именованный пользователь
   `admin`; в LAN-режиме (API/RTMP наружу не публикуются, их-frontирует Caddy)
   достаточно `any` с read/publish/playback/api. Supervisor переведён на **anonymous-API**
   (`MTX_ADMIN_PASSWORD` не задан → supervisor.sh берёт ветку без авторизации).
2. **Caddy `/v3`**: было `handle_path /v3/*` (срезает префикс) → панель получала пустой
   список путей. Исправлено на `handle /v3/*` (сохраняет путь, MediaMTX отдаёт API под `/v3`).
   `/ctl` остаётся `handle_path` (ctl.py слушает `/state`,`/outputs`,`/end`,`/resume` без префикса).
3. **bcrypt-хеш панели**: Docker Compose интерполирует `$` даже внутри `env_file`, портя
   `PANEL_HASH=$2a$14$...`. Решение — хеш **запечён литерально в Caddyfile** (Caddy читает
   файл как есть; compose содержимое примонтированных файлов не трогает). В `.env` теперь
   только `$`-свободные переменные.

Эти 3 правки пока применены **только на сервере**. В файлы репозитория `deploy/vps/*`
(домашний доменный шаблон) они НЕ переносились — перенести, если делаешь новый деплой
или перевод доменного шаблона на v1.21.2.

---

## 5. Панель и доступы
- URL: `http://172.22.22.17:8070` (HTTP, LAN; TLS не ставили — домена нет, самоб-signed не нужен).
  ⚠️ Не `:80` — порт 80 на сервере занят, в compose маппинг `8070->80` (проверено 26.10.2026).
- BasicAuth: пользователь `operator`, пароль сгенерирован и выдан в чате 22.10.2026
  (в git не попадает). Как узнать/сбросить пароль панели:
  ```bash
  # сгенерировать новый hash и вписать в Caddyfile строку basic_auth (user=operator):
  docker run --rm caddy:2-alpine caddy hash-password --plaintext 'НОВЫЙ_ПАРОЛЬ'
  # затем: cd /root/Restrimer_TournamentLive/deploy/vps && docker compose up -d --force-recreate caddy
  ```
- Превью HLS отдаётся напрямую с `:8888` (cockpit подставляет `host:8888` сам).

---

## 6. Осталось сделать (следующие шаги)
1. **Телефоны снаружи сети.** `172.22.22.17` приватный → извне не достать. Нужен публичный
   IP сервера или порт-форвардинг роутера на `1935`. Тогда для QR (генератор `tools/qr.html`):
   `stream_url = rtmp://<публичный_IP>:1935/tatami/`, `stream_key = <номер экрана 1..8>`.
   Если турнир в той же LAN — ничего менять, оставляем `172.22.22.17`.
2. **Ключи площадок VK/YouTube.** Открыть панель → карточка экрана → блок «Куда транслируем» →
   выбрать платформу, вставить stream key, «вкл», «Сохранить». Релайер подхватит за ~3 с, рестарт не нужен.
   (Файл: `deploy/vps/outputs/outputs.local.conf`.)
3. **Запись.** Сейчас **выключена** (мало места: ~13 ГБ свободно, диск 78%). Если нужен
   архив турнира — включить `record: yes` и обязательно задать `recordDeleteAfter`
   (например `6h`/`12h`) + следить за диском, либо писать на отдельный том.
4. **Git.** У локального репозитория `streaming-infra` **нет remote** → push невозможен,
   пока не задан URL GitHub. После настройки: `git remote add origin <url> && git push -u origin main`.

---

## 7. Как проверялось (22.10.2026)
- `/v3/paths/list` через Caddy (BasicAuth) → **16** путей; `broadcast/a` → `online:true`,
  треки H264 1920x1080 + MPEG-4 Audio (кормится заставкой).
- Непрерывность: фейковый RTMP-вход в `tatami/a` → `fallback -> live`; убит →
  `live -> fallback`; на всех этапах `broadcast/a` оставался `online:true`.
- BasicAuth: верный пароль → 200, неверный → 401. `/ctl/state` → 200. Превью `:8888` отвечает.
