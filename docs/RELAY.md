# Ретранслятор TournamentLive — справочник

Серверная платформа ретрансляции: принимает RTMP с телефонов, **непрерывно** держит
выход на площадки и показывает операторскую панель. Живёт **отдельным проектом**
(не внутри Flutter-приложения):

```
c:\WORK\FLUTTER\WORK_PROJECTS\streaming-infra        # ветка main, коммит 530c8ba
```

Документ — справочник по контрактам, состояниям, конфигам и операциям.
Быстрый старт описан в [`../README.md`](../README.md), боевое развёртывание —
в [`../deploy/vps/README.md`](../deploy/vps/README.md). Здесь — почему всё устроено
именно так и что ломается при каждой правке.

---

## 1. Задачи, которые решает платформа

| Задача | Как решается |
|---|---|
| Принять 1–8 независимых стримов | MediaMTX, пути `tatami/a..h` |
| Не порвать выход, когда телефон упал | supervisor меняет FFmpeg-фидер `live` ↔ зацикленная заставка `fallback` |
| Дать одно и то же видео нескольким площадкам | relayer читает `broadcast/<x>` и пушит наружу по списку ключей |
| Оператор видит и управляет | веб-панель (nginx) + MediaMTX API + контрольный API supervisor |

Ключевая идея: **вход и выход разделены**. Площадки и панель никогда не читают
`tatami/*` — только `broadcast/*`. Поэтому обрыв телефона не виден снаружи: выход
продолжает существовать, меняется лишь его источник.

---

## 2. Схема путей — главный контракт

| Путь | Кто пишет | Кто читает | Запись на диск |
|---|---|---|---|
| `tatami/<x>` | телефон (RTMP-публикация) | supervisor (как источник) | **да** — `data/recordings/tatami/<x>/` |
| `broadcast/<x>` | supervisor (live-копия или заставка) | панель, превью, relayer | нет (`record: no`, иначе дубли) |

`<x>` — буква татами, `a..h` (зарезервировано 8, по одному на татами). Один и тот же
набор букв повторяется в шести местах (см. §9, «добавить 9-е татами») — это и есть
единственное, что реально нужно править при росте числа татами.

Оба пути объявлены в `mediamtx/mediamtx.yml` как `source: publisher`, то есть
никто не тянет их по расписанию — их публикуют. Пути, которого нет в списке `paths:`,
публикация не примет (catch-all в текущей конфигурации не используется).

---

## 3. Топология

```
Телефон ──RTMP──▶ rtmp://host:1935/tatami/<a..h>
                          │
              MediaMTX (контейнер mediamtx)   ← приём + HLS-превью + API + запись
                          │  статус путей по HTTP API
              supervisor (контейнер): цикл каждые INTERVAL_SEC
                 tatami/x online  → фидер ffmpeg -i tatami/x -c copy → broadcast/x
                 tatami/x offline → фидер ffmpeg -stream_loop -1 fallback_x.mp4 → broadcast/x
                          │
                          ▼
              rtmp://host:1935/broadcast/<a..h>   ← это читают панель и площадки
                          │
              relayer (контейнер): построчно из outputs/*.conf
                          ▼
              YouTube RTMP out · VK RTMP out · (+ ещё площадок на ту же букву)

              панель (nginx, :8000): index.html + прокси /v3 → API, /hls → плеер, /ctl → supervisor
```

| Контейнер | Образ | Роль |
|---|---|---|
| `mediamtx` | `bluenviron/mediamtx` | RTMP-приём, HLS, HTTP API, запись сегментов |
| `supervisor` | `tl-supervisor:local` (`deploy/vps/supervisor/`) | фидеры live↔fallback + контрольный сервер `/ctl/*` |
| `relayer` | `tl-relayer:local` (`relay/`) | ретрансляция `broadcast/<x>` → площадки |
| `panel` | `nginx:alpine` | кокпит + обратный прокси к API и плееру (один origin — без CORS) |

| Порт | Назначение | Наружу (локально / на VPS) |
|---|---|---|
| 1935 | RTMP-приём с телефонов | да / да (сузить по source IP) |
| 8888 | HLS-плеер MediaMTX (`http://host:8888/broadcast/a`) | да / **нет** (через Caddy) |
| 8889 | WebRTC | объявлен, сервис выключен (`webrtc: no`) |
| 9997 | HTTP API MediaMTX | да / **нет** (через Caddy `/v3`) |
| 8000 | панель (cockpit) | да / только HTTPS 443 за BasicAuth |

WebRTC выключен осознанно: ICE под Docker на Windows нестабилен, превью делают по HLS.

---

## 4. Состояния выхода одного татами

Желание (`want`) считается по входу, текущее (`cur`) — по файлу состояния в контейнере.
Логика целиком в [`../deploy/vps/supervisor/supervisor.sh`](../deploy/vps/supervisor/supervisor.sh).

| Состояние | Условие | Что на выходе | Логи |
|---|---|---|---|
| `live` | `tatami/x` online | прямая RTMP-копия без перекодирования | `tatami/x : none -> live (feeding broadcast/x, pid=...)` |
| `fallback` | `tatami/x` offline | зацикленная `fallback_x.mp4` | `tatami/x : live -> fallback (...)` |
| `ended` | оператор нажал «Завершить» | фидер убит, `broadcast/x` offline | `tatami/x : operator END -> broadcast/x taken offline (platform ends)` |
| `none` | фидер ещё не стартовал | выход offline | — |

Переходы (цикл раз в `INTERVAL_SEC`, по умолчанию 2 с):

- `tatami/x` пропал → на следующей итерации: `kill` старого фидера, пауза 0.4 с
  (освободить путь), старт фидера заставки. **На выходе — дыра ~1–2 с**, при этом
  публикация `broadcast/x` не рвётся «в ноль»: её закрывает и тут же открывает новый фидер.
- `tatami/x` вернулся → обратно `fallback → live` за те же ~2 с.
- «Завершить» → выход уходит в offline и **не восстанавливается сам**, пока не нажмут
  «Возобновить». Это операторский intent, он перебивает live/fallback-логику.
- Фидер умер сам (ffmpeg вышел) → на следующей итерации `alive` = ложь → рестарт.

Инвариант: **ровно один фидер на букву**. Отсюда запрет на одновременный запуск
`scripts/supervisor.ps1` (легаси-версия на хосте) и контейнера `supervisor` — два
фидера будут драться за один `broadcast/<x>`.

Границы ответственности: решение о переключении принимает **только** supervisor.
MediaMTX — транспорт, relayer — доставка. Никто из них «чинить» вход не пытается.

---

## 5. Конфигурация: что где лежит

| Файл | Что задаёт | После правки |
|---|---|---|
| `docker-compose.yml` | сервисы, env `TATAMIS`, `FALLBACK_DIR`, `INTERVAL_SEC`, `OUTPUTS_PATH`, монты | `docker compose up -d` (env/ports меняются, пересоздание сработает) |
| `mediamtx/mediamtx.yml` | список путей, `record*`, auth, адреса портов | **`--force-recreate mediamtx`** |
| `panel/index.html`, `panel/config.js` | кокпит, `playerOrigin` | **`--force-recreate panel`** |
| `panel/nginx.conf` | прокси `/v3`, `/hls`, `/ctl` | **`--force-recreate panel`** |
| `outputs/outputs.conf` | образец списка площадок (в git) | relayer перечитает сам |
| `outputs/outputs.local.conf` | **боевые ключи** (`.gitignore`) | relayer перечитает за ~3 с, без рестарта |
| `fallback/fallback_a..h.mp4` | заставки по татами | перезапустить фидер буквы (END/RESUME или рестарт контейнера) |
| `relay/relayer.sh`, `deploy/vps/supervisor/*` | логика доставки и фидеров | `docker compose up -d --build relayer supervisor` |

**Почему `--force-recreate` обязателен для файлов:** `docker compose up -d` решает,
пересоздавать ли контейнер, по хешу **описания сервиса** (image, env, ports, список
volume'ов). Содержимое файла, примонтированного как одиночный файл
(`./mediamtx/mediamtx.yml:/mediamtx.yml:ro`), в хеш не входит — контейнер останется
«Running» со старыми путями в памяти, и новые пути не появятся. Проверять результат
надо со стороны работающего сервиса, а не с диска: `/v3/paths/list` и посчитать объекты
(для 8 татами — 16 путей).

Формат `outputs/*.conf` (одна площадка на строку):

```
<буква> <полный RTMP-адрес площадки вместе с ключом>
#<буква> <адрес>            # строка с # в начале = запись выключена
```

Пустой файл = ретрансляции нет (безопасно). Несколько строк с одной буквой =
один и тот же `broadcast/<x>` льётся на несколько площадок.

---

## 6. API

### MediaMTX (порт 9997, из панели — как `/v3`)

```powershell
curl.exe -s http://localhost:9997/v3/paths/list                 # все пути: online / tracks / bytes
Invoke-RestMethod http://localhost:8000/v3/paths/get/tatami/a   # один путь (через прокси панели)
```

Поле `online` — единственный признак, по которому supervisor выбирает режим
(`grep '"online":true'`). Именно поэтому «вырвать телефон» видно в панели как
OFF на входе при ONLINE на выходе.

### Контрольный API supervisor (из панели — как `/ctl`, внутри сети — `supervisor:8090`)

| Эндпоинт | Действие |
|---|---|
| `GET /ctl/state` | intent по буквам: `hold` / `ended` |
| `GET /ctl/outputs` | список `татами → площадка` + флаг `enabled` |
| `POST /ctl/outputs` | перезаписать список телом `{"items":[...]}` (атомарно, через tmp + replace) |
| `POST /ctl/end/<x>` | «Завершить»: выход в offline, заставка **не** включается |
| `POST /ctl/resume/<x>` | снять intent, вернуть live/fallback-логику |

Реализация — [`../deploy/vps/supervisor/ctl.py`](../deploy/vps/supervisor/ctl.py)
(только stdlib, без авторизации: наружу он не торчит, доступен лишь через origin панели,
который на VPS за Caddy TLS + BasicAuth). Intent'ы хранятся файлами `/control/<буква>`.

---

## 7. Как подключается телефон (интеграция с приложением)

Код приложения менять **не нужно**. Телефон берёт из QR два поля и публикует их склейку
(`StreamConfig.getFullStreamUrl()` = `streamUrl + streamKey`):

```
stream_url = rtmp://<IP-сервера>:1935/tatami/
stream_key = a
итог       = rtmp://<IP-сервера>:1935/tatami/a
```

Правила:

- **QR несёт только адрес нашего сервера.** Ключи VK/YouTube в QR не попадают никогда —
  они живут в `outputs/outputs.local.conf` и правятся из панели. Поэтому смена ключа
  площадки не требует пересканирования ни одним телефоном.
- Буква в `stream_key` = номер татами; та же буква должна быть в списке площадок.
- Телефон смотрит на **LAN-IP машины, а не на localhost**:

  ```powershell
  (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '192.168.*' }).IPAddress
  ```

  IP меняется вместе с роутером/сетью — после смены сети нужно перевыпустить QR
  (генератор — `tools/qr.html`).
- Телефон и сервер — в одной Wi-Fi сети; на хосте нужно входящее правило фаервола на 1935
  (`Setup-Firewall.bat`).
- Каждый вход пишется на диск автоматически: `data/recordings/tatami/<x>/` (fmp4,
  сегменты 60 с, автоудаление через 24 ч) — то есть запись турнира есть даже если
  площадка отвалилась.

---

## 8. Диагностика

```powershell
docker compose ps --format "{{.Name}}  {{.Status}}"   # что живо
docker compose logs -f mediamtx                       # приём / публикации / запись
docker compose logs -f supervisor                     # переключения live<->fallback, intent
docker compose logs -f relayer                        # подключения к площадкам
Get-Content logs/supervisor.log -Tail 20              # если использовался легаси-хост-режим
```

Что искать в логах:

| Строка | Значение |
|---|---|
| `supervisor up: tatamis=[a b ...] api=... interval=2s` | supervisor жив, список букв и API верны |
| `tatami/a : none -> live` | фидер live стартовал |
| `tatami/a : live -> fallback` | телефон пропал, включилась заставка |
| `operator END -> broadcast/a taken offline` | сработала кнопка «Завершить» |
| `relay a -> rtmp://push.vk.com/...` | ретрансляция буквы A на площадку запущена |
| `relay a (re)connecting` / `dest changed` | фидер площадки упал и восстановился / сменили ключ |
| `skipping malformed line` | ошибка формата в `outputs/*.conf` (нужно `<буква> <url>`) |

Матрица «симптом → куда смотреть»:

| Симптом | Причина и проверка |
|---|---|
| Телефон не доходит, приложение показывает ошибку соединения | не тот IP в QR (не LAN-IP), другая Wi-Fi сеть, фаервол на 1935, путь `tatami/x` не объявлен в `mediamtx.yml` |
| Вход ONLINE, выхода нет | supervisor мёртв или конфликтует с `scripts/supervisor.ps1` — оставить что-то одно |
| Правка `mediamtx.yml` «не применилась» | не было `--force-recreate`; считать пути по API |
| Заставка не показывается | нет `fallback_<x>.mp4` для этой буквы (перегенерить `scripts/gen-fallback.ps1`) |
| Площадка ничего не видит | пуст или выключен `outputs.local.conf`, буква не совпала, ключ просрочен — смотреть логи relayer |
| Площадка показывает «трансляция завершена» | стоит intent `ended` — «Возобновить» |
| Тестовые `testsrc` ушли в эфир | ключи не были приостановлены перед `start-test-streams.ps1` (см. §9) |

---

## 9. Runbook: типовые операции

**Поднять всё (локально):**

```powershell
cd C:\WORK\FLUTTER\WORK_PROJECTS\streaming-infra
docker compose up -d --build
Invoke-RestMethod http://localhost:9997/v3/paths/list | Measure-Object   # ожидаем 16 путей
```

**Поднять с фейковыми телефонами** (проверка непрерывности без реальных устройств):

```powershell
powershell -ExecutionPolicy Bypass -File scripts/start-all.ps1   # стек + заставки + 8 тест-стримов
```

⚠️ Перед этим **обязательно** приостановить боевые ключи, иначе тестовая картинка пойдёт
в реальные трансляции:

```powershell
Move-Item outputs/outputs.local.conf outputs/outputs.local.conf.paused
# вернуть тем же Move-Item в обратную сторону
```

**Остановить:** `powershell -ExecutionPolicy Bypass -File scripts/stop-all.ps1`
(или `docker compose down`).

**Проверить непрерывность на живом стеке:** открыть <http://localhost:8000>, «Показать
живое видео», убить фидер-источник одного татами:

```powershell
Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" |
  Where-Object { $_.CommandLine -like '*tatami/a*' -and $_.CommandLine -notlike '*broadcast*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

Ожидаем: вход A → OFF, выход A остаётся ONLINE и становится FALLBACK, остальные без изменений.

**Сменить или добавить ключ площадки:** панель → секция «Площадки» → платформа,
`stream_key`, «Сохранить ключи». Рестарта контейнеров нет: `ctl.py` переписывает файл
атомарно, relayer видит изменение за ~3 с. Тот же результат даёт ручная правка файла.

**Перегенерировать заставки:** `powershell -File scripts/gen-fallback.ps1` (свой оттенок и
буква на татами, 1280x720, цикл 6 с).

**Добавить 9-е татами (буква `i`)** — править шесть мест, иначе конфигурации разъедутся:

1. `mediamtx/mediamtx.yml` → `tatami/i` и `broadcast/i` (и `--force-recreate mediamtx`);
2. `docker-compose.yml` → env `TATAMIS` в сервисе supervisor;
3. `deploy/vps/mediamtx.yml` и `deploy/vps/docker-compose.yml` — то же для VPS;
4. `panel/index.html` — карточка;
5. `scripts/gen-fallback.ps1` и `scripts/start-test-streams.ps1` — списки букв;
6. создать `fallback/fallback_i.mp4`.

**Перевыпустить ключ площадки** = просто вставить новый из панели. Ключ, засвеченный в
логах, чате или скриншоте, считается скомпрометированным и перевыпускается на площадке.

---

## 10. Безопасность

- Локальный MVP намеренно открыт: `authMethod: internal` + `user: any` с правами
  `read/publish/playback/api`. Это **только** для теста в LAN: любой в сети может
  опубликовать свой поток на `tatami/*` и читать API.
- На VPS (Этап E): реальные пользователи с hash-паролями, TLS через Caddy, BasicAuth на
  панель, анонимно разрешена только публикация на `tatami/*`/`broadcast/*` с
  **неугадаемыми** stream_key; 9997 и 8888 на хост не пробрасываются; 1935 сужается до
  source IP (`ufw allow from <IP> to any port 1935`).
- Секреты: `outputs/outputs.local.conf` в `.gitignore`, в git не попадает; в контейнер
  примонтирован как `:ro` у relayer и `:rw` у supervisor (панели нужно перезаписывать).
  `.env` (пароль MediaMTX, hash панели) тоже вне git — существует только `.env.example`.
- Правила разделения проектов: серверная платформа не коммитится в ветки Flutter-приложения
  (в `tournament-live` папка `streaming-infra/` исключена через `.git/info/exclude`).

---

## 11. Ограничения MVP (что не гарантируется)

- **~1–2 секунды дыры** при переключении live↔fallback — это замена FFmpeg-фидера, а не
  бесшовный switch. Для «без единого потерянного кадра» нужен Liquidsoap (осознанно вне MVP).
- `hlsAlwaysRemux: yes` на 16 путях даёт заметную нагрузку на слабый ПК; превью в панели
  грузится по клику именно поэтому.
- Резервация — ровно 8 татами; больше — шесть мест из §9.
- `scripts/supervisor.ps1` — легаси на хосте, с контейнером несовместим.
- Записи хранятся 24 ч (`recordDeleteAfter`) — долговременный архив делать отдельно.
- Шаг relayer'а — 3 с: новый ключ площадки вступает в силу в течение ~3 с, а не мгновенно.

---

## 12. Перенос на VPS

Полная инструкция — [`../deploy/vps/README.md`](../deploy/vps/README.md): пред-требования,
две DNS A-записи, генерация bcrypt для кокпита, `Caddyfile`, UFW, генерация заставок bash,
`systemd/tl-streaming.service`. Держать в голове: `deploy/vps/*` — **зеркало** локальных
настроек (список татами, `TATAMIS`); правя одно без другого, получаем расхождение локального
теста и боевого сервера.

---

*Сверено с файлами репозитория `streaming-infra` (коммит `530c8ba`) 13.10.2026.
Стек на момент написания не запущен (Docker Desktop остановлен), поэтому команды
подтверждены по конфигурации, а не живым прогоном.*
