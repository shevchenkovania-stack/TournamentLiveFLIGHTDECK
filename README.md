# TournamentLive — Local Streaming Infrastructure (MVP)

> **Полный справочник платформы** (контракты путей, состояния live↔fallback, конфиги,
> API, интеграция с телефонами, runbook, безопасность) — [`docs/RELAY.md`](docs/RELAY.md).
> Ниже — только быстрый старт.

Принимает RTMP с 1–8 телефонов (зарезервировано 8 татами, по одному на татами), показывает живое видео и
статусы в веб-панели, и держит **непрерывный выход** на площадки: когда телефон
пропадает, выход не рвётся — автоматически включается зацикленная заставка, а при
восстановлении возвращается живое видео.

## Архитектура

```
Телефон (TournamentLive) ──RTMP──▶ rtmp://host:1935/tatami/<a..h>
                                              │
                            MediaMTX (Docker) │ приём + HLS-превью + запись + API
                                              ▼
              supervisor (Docker-контейнер): FFmpeg-фидеры, 1 на татами
                    live если телефон онлайн  /  loop fallback_<x>.mp4 если офлайн
                                              ▼
                          rtmp://host:1935/broadcast/<a..h>   ← это читают площадки и панель
                                              │
                        relayer (Docker) ← outputs/outputs.local.conf
                                              ▼
                 YouTube (RTMP out)     VK (RTMP out)     +   Веб-панель :8000
```

Каждое татами независимо: падение одного не трогает остальные.

## Контейнеры (что поднимает `docker compose up -d`)

| Сервис | Образ | Роль |
|--------|-------|------|
| `mediamtx` | `bluenviron/mediamtx` | приём RTMP, HLS-превью, HTTP API :9997, запись в `data/recordings/` |
| `panel` | `nginx:alpine` | коктпит :8000 + прокси `/v3` → API и `/ctl` → supervisor |
| `supervisor` | `tl-supervisor:local` | фидеры live↔fallback + контрольный сервер `/ctl/*` (кнопки, ключи) |
| `relayer` | `tl-relayer:local` | ретрансляция `broadcast/<x>` → площадки (VK/YouTube) |

## Порты

| Порт | Что |
|------|-----|
| 1935 | RTMP-приём (телефоны пушат сюда) |
| 8888 | HLS-плеер MediaMTX (превью любого пути) |
| 9997 | HTTP API MediaMTX (статусы путей) |
| 8000 | **Веб-коктпит** (панель управления) |

## Запуск / остановка

```powershell
# Всё одной командой:
powershell -ExecutionPolicy Bypass -File scripts/start-all.ps1

# Остановить:
powershell -ExecutionPolicy Bypass -File scripts/stop-all.ps1
```

По-компонентно:

```powershell
docker compose up -d --build                           # MediaMTX + панель + supervisor + relayer
powershell -File scripts/gen-fallback.ps1              # сгенерировать заставки (a..h)
powershell -File scripts/start-test-streams.ps1        # 8 фейковых «телефонов»
powershell -File scripts/stop-test-streams.ps1         # стоп фейковых телефонов
```

> `scripts/supervisor.ps1` — легаси-версия фидеров на хосте (до Docker). **Не запускай её
> вместе с контейнером `supervisor`**: два фидера на один `broadcast/<x>` будут драться.

## Ключи площадок (VK/YouTube) — только из панели

Боевые RTMP-ключи живут в `outputs/outputs.local.conf` (в `.gitignore`, в git не попадает).
Редактируются **из коктпита** — секция «Площадки»: выбрать платформу (VK / YouTube / custom),
вставить `stream_key`, нажать «Сохранить ключи». Панель шлёт `POST /ctl/outputs`,
supervisor переписывает файл атомарно, relayer перечитывает его каждые ~3 с — **без рестарта**,
healthy-ретрансляции не трогаются.

Кнопки на карточке татами:
- **«Завершить»** (`POST /ctl/end/<x>`) — операторская intent: выход `broadcast/<x>` уходит
  в offline, заставка НЕ включается. На площадке VK корректно показывает «трансляция завершена».
- **«Возобновить»** (`POST /ctl/resume/<x>`) — снять intent, вернуть live/fallback-логику.

Контрольный API supervisor-а (через прокси панели на `:8000`):

| Эндпоинт | Что даёт |
|---|---|
| `GET /ctl/state` | intent по каждому татами: `hold` / `ended` |
| `GET /ctl/outputs` | список строк `татами → площадка` + флаг enabled |
| `POST /ctl/outputs` | перезаписать список (атомарно) |
| `POST /ctl/end/<x>` · `/ctl/resume/<x>` | операторский «стоп» / «продолжить» |

## Записи

Каждый вход `tatami/<x>` пишется в `data/recordings/tatami/<x>/` (fmp4, сегменты 60 с,
автоудаление через 24 ч). `broadcast/*` не пишутся (`record: no`) — там заставка, дубли не нужны.

## Статус и логи

```powershell
curl.exe -s http://localhost:9997/v3/paths/list        # все пути: online/tracks/bytes
docker compose logs -f mediamtx                        # сервер
Get-Content logs/supervisor.log -Tail 20               # переключения live<->fallback
```

## Как протестировать (коротко)

1. **Подними** `scripts/start-all.ps1`.
2. **Открой панель** http://localhost:8000 — 8 карточек, у каждой два бейджа:
   вход (`tatami/x`) и выход (`broadcast/x`). Нажми «Показать живое видео».
3. **Проверь непрерывность выхода:** «вырви» один телефон —
   ```powershell
   Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" |
     Where-Object { $_.CommandLine -like '*tatami/a*' -and $_.CommandLine -notlike '*broadcast*' } |
     ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
   ```
   В панели татами A: вход станет **OFF**, а выход **останется ONLINE** и
   переключится в **FALLBACK** (заставка). Прочие татами — без изменений.
   В `logs/supervisor.log` появится `mode live->fallback`.
4. **Проверь восстановление:** запусти телефон A обратно
   (`start-test-streams.ps1` или одиночный ffmpeg) — через пару секунд выход
   сам вернётся **FALLBACK → LIVE**.
5. Прямой плеер любого пути: http://localhost:8888/broadcast/a

## Подключение реальных телефонов

Код TournamentLive **менять не нужно**: телефон берёт `stream_url`+`stream_key` из
QR и пушит `stream_url+stream_key`. Сгенерируй QR с:
- `stream_url = rtmp://<IP-этой-машины>:1935/tatami/`
- `stream_key = a`  → итог `rtmp://<IP>:1935/tatami/a`

Чтобы выход уходил на площадки, добавь в `supervisor`/ffmpeg второй выход
`rtmp://.../broadcast/<x>` → RTMP-адрес YouTube/VK (ключи — в секретах, не в git).

## Эксплуатационные грабли (проверено на живом стеке)

- **Правка файла, примонтированного как ОДИНОЧНЫЙ файл, сама по себе не применяется.**
  `docker compose up -d` пересоздаёт контейнер только если изменилось описание сервиса
  (image/env/ports/список volumes), а содержимое `mediamtx/mediamtx.yml` или
  `panel/index.html` в хеш не входит. После такой правки:
  `docker compose up -d --force-recreate mediamtx panel` и проверяй изнутри
  (`Invoke-RestMethod http://localhost:9997/v3/paths/list` — сколько путей реально видно).
- **Не лей тестовые `testsrc`-потоки в боевые трансляции.** Перед стартом фейковых телефонов
  с активными ключами VK временно убери файл: `Move-Item outputs/outputs.local.conf outputs.local.conf.paused`
  (реле перестанет видеть строки за ~3 с, обратно — тем же `Move-Item`).
- **QR/телефон смотрят на LAN-IP машины, а не на localhost.** узнай текущий:
  `(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '192.168.*' }).IPAddress`
  — IP меняется вместе с роутером/сетью (в `tools/qr.html` дефолт прописан, сверяй).
- Ключи в `outputs.local.conf` — это секреты площадки; при попадании в чат/скриншот считать
  скомпрометированными и перевыпускать.

## Известные ограничения MVP

- Переключение live↔fallback — это замена FFmpeg-фидера: **~1–2 секунды** дыра на
  выходе. Для «без единого кадра потери» нужен Liquidsoap (см. план, не в MVP).
- Превью в панели грузится по клику (экономия CPU): `hlsAlwaysRemux` на 16 путях
  уже даёт заметную нагрузку на слабом ПК.
- Авторизация API открыта (`user: any`) — **только для локального теста**. На VPS
  обязательны реальный auth + TLS.
- Ключи площадок подключаются через панель (см. «Ключи площадок») — файл `outputs.local.conf`
  не должен попадать в git; в VPS-бандле тот же механизм и то же исключение в `.gitignore`.
- Резервация = 8 татами (`a..h`). Больше — править список в 6 местах: `mediamtx/mediamtx.yml`,
  `docker-compose.yml` (`TATAMIS`), `deploy/vps/*` (то же), `panel/index.html`,
  `scripts/gen-fallback.ps1`, `scripts/start-test-streams.ps1` + перегенерировать заставки.

## Перенос на VPS (Этап E — дальше)

- Заменить `authInternalUsers` на реальных пользователей с паролями (hash) + `TLS`.
- Закрыть 1935/8888/9997 фаерволом, открыть только нужное; панель — за auth.
- `broadcast/*` → реальные RTMP-адреса площадок; секреты вне образов/git.
- systemd/`restart: unless-stopped`, ротация логов, мониторинг, расчёт трафика.
