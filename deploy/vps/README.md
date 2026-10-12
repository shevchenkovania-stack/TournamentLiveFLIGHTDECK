# TournamentLive — развёртывание на VPS (Этап E)

Готовая к переносу конфигурация медиа-сервера. Отличается от локального MVP тем,
что наружу торчат **только** RTMP-приём (1935) и HTTPS (443); API MediaMTX (9997)
и HLS-плеер (8888) доступны лишь из внутренней docker-сети через Caddy с TLS и
BasicAuth. Супервизор фолбэка работает отдельным контейнером (не зависит от ОС хоста).

```
Телефоны ──RTMP:1935──▶ MediaMTX ──(внутр. сеть)──▶ supervisor ──▶ broadcast/<x>
                          │   ▲                                   ├─▶ YouTube RTMP out
   Оператор ─HTTPS:443─▶ Caddy(BasicAuth+TLS)──┘                 └─▶ VK RTMP out
                          └── panel (cockpit) + /v3 API + preview.<домен>
```

## 0. Пред-требования
- Linux (Ubuntu 22.04+/Debian 12), Docker Engine + Compose v2.
- 2 DNS A-записи на IP сервера: `panel.example.com`, `preview.example.com`
  (Caddy сам получит Let's Encrypt при reachability на 80/443).
- Порты хоста свободны: 1935, 80, 443.

## 1. Файлы
```
deploy/vps/
├── docker-compose.yml     # mediamtx + supervisor + relayer + caddy (linux, bridge)
├── mediamtx.yml           # hardened auth; только publish анонимно на tatami/broadcast
├── Caddyfile              # TLS + BasicAuth panel; preview-сабдомен; /v3 и /ctl прокси
├── .env.example           # PANEL_HASH, MTX_ADMIN_* → скопировать в .env
├── panel/config.js        # playerOrigin = https://preview.<домен>
├── supervisor/            # Dockerfile + supervisor.sh (live↔fallback) + ctl.py (/ctl API)
├── outputs/               # outputs.conf (sample); outputs.local.conf с ключами — в .gitignore
├── systemd/tl-streaming.service
└── fallback/              # положить fallback_a..h.mp4 (см. §4)
```

## 2. Быстрый старт
```bash
git clone <repo> && cd streaming-infra/deploy/vps
# standalone repo (not part of the tournament-live Flutter app); default branch: main

cp .env.example .env
# 1) сгенерировать bcrypt для коктпита:
docker compose run --rm caddy caddy hash-password --plaintext 'ВАШ_ПАРОЛЬ'
#    → вписать результат в .env : PANEL_HASH=...
# 2) MTX_ADMIN_PASSWORD в .env должен СОВПАДАТЬ с admin-паролем в mediamtx.yml.

# Заменить домены (panel.example.com / preview.example.com / email) в Caddyfile и panel/config.js.
# Заменить пути tatami/<x> на реальные НЕУГАДАЕМЫЕ ключи в mediamtx.yml (и в QR-конфиге).

docker compose up -d --build
```

## 3. Firewall (UFW пример)
```bash
ufw allow 1935/tcp            # RTMP ingest (лучше сузить до IP провайдера/телефонов)
ufw allow 80/tcp              # нужен Let's Encrypt, затем редирект на 443
ufw allow 443/tcp             # панель + preview (TLS+auth)
# НЕ открывать 9997/8888 — они не проброшены на хост.
ufw enable
```
Строго: ограничить 1935 по source IP (`ufw allow from <IP_телефонов/вышки> to any port 1935`),
иначе приём защищён только длиной/случайностью stream_key.

## 4. Заставки (fallback)
Каждому татами — свой цикл. Положить `fallback/fallback_a.mp4 … _h.mp4`.
Сгенерировать на сервере (яркая анимированная тест-карточка, свой оттенок на татами —
как в локальном gen-fallback.ps1, но bash). Для bash нужен ffmpeg с `testsrc2` и `drawtext`:
```bash
FONT=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf
declare -A HUE=([a]=0 [b]=72 [c]=144 [d]=216 [e]=288 [f]=36 [g]=108 [h]=180)
for x in a b c d e f g h; do
  VF="testsrc2=size=1280x720:rate=30,hue=h=${HUE[$x]},"\
"drawtext=fontfile=${FONT}:text='TATAMI ${x}':fontsize=88:fontcolor=white:borderw=4:bordercolor=black@0.7:x=(w-text_w)/2:y=(h/2)-90,\
drawtext=fontfile=${FONT}:text='connection recovering...':fontsize=40:fontcolor=yellow:borderw=3:bordercolor=black@0.7:x=(w-text_w)/2:y=(h/2)+30"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 \
    -f lavfi -i "$VF" -map 1:v -map 0:a -t 6 \
    -c:v libx264 -pix_fmt yuv420p -profile:v baseline -level 3.1 -g 30 \
    -c:a aac -ar 44100 -b:a 64k -shortest fallback/fallback_${x}.mp4
done
```
(или просто скопировать уже готовые `../../fallback/*.mp4` с локальной машины).

## 4b. Площадки (VK/YouTube) — ключи через панель
Ключи площадок **не вшиваются в приложение и не в QR** (QR несёт только адрес
нашего сервера). После запуска открой `https://panel.<домен>` (BasicAuth) → блок
«🔌 Площадки»: для каждого татами выбери платформу (VK/YouTube/другая), вставь
stream key, отметь «вкл», «Сохранить». Панель пишет `outputs/outputs.local.conf`
через `/ctl/outputs` (supervisor `ctl.py`), а `relayer` подхватывает изменение за
~3 сек без перезапуска контейнеров. Ручная правка файла так же работает.

## 5. Проверка
```bash
docker compose ps
docker compose logs -f supervisor        # строки live->fallback / fallback->live
curl -fsS http://127.0.0.1:9997/v3/paths/list   # с хоста (внутри сети недоступен снаружи)
```
Открыть https://panel.example.com — логин BasicAuth, 8 карточек со статусами вход/выход.

## 6. Подключение площадок (VK/YouTube)
Выход каждой площадки — ещё один «потребитель» `broadcast/<x>`. Добавь в
`supervisor.sh` второй аргумент ffmpeg, публикующий `broadcast/<x>` на RTMP-URL
площадки, либо отдельным ffmpeg-контейнером на путь `broadcast/<x>`.
```
ffmpeg -i rtmp://mediamtx:1935/broadcast/a -c copy -f flv \
  "rtmp://ingest.live.yandex/vh/<STREAM_KEY>"          # пример; реальные URL/ключи — в секретах
```
**Ключи площадок не коммитить** — только в `.env`/docker secrets.

## 7. Подключение реальных телефонов
Код TournamentLive не меняется. В QR-конфиге:
- `stream_url = rtmp://<IP_VPS>:1935/tatami/`
- `stream_key = <неугадаемый ключ татами>` → push на `.../tatami/<ключ>`.
Совпадение пути в mediamtx.yml и ключа обязательно (иначе publish отклонится).

## 8. Ресурсы и трафик
На ингест нет перекодирования (`-c copy`) → CPU лёгкий; нагрузка — HLS-ремукс на
просмотр и число зрителей. Ориентир на 8 татами:
- CPU: 2 ядра (headroom на remux/несколько выходов); RAM: 2–4 ГБ.
- Исходящий трафик без перекодирования ≈ сумма битрейтов выходов. При ~4 Мбит/с ×8 =
  32 Мбит/с постоянно ≈ **~346 ГБ/сутки** на 8 прямых выходах на 1 площадку. Удвоение
  числа площадок = удвоение исходящего трафика. Планируй безлимит/пакет accordingly.
- Диск записи: fmp4 сегментами; `recordDeleteAfter` сокращает хранение. 8×4 Мбит/с ≈
  ~14.4 ГБ/час суммарно (при записи только входов).

## 9. Автозапуск / логи / бэкап
- Автозапуск: `systemd/tl-streaming.service` (см. комментарии в файле).
- Логи идут в stdout контейнеров; ограничь размер демоном Docker (`--log-opt max-size`)
  или включи logrotate на `/var/lib/docker/containers/*/*-json.log`.
- Бэкап: `.env` (в защищённом месте вне git), `mediamtx.yml`, `Caddyfile`,
  `fallback/`, `data/recordings` по политике. Перед рестартом — `tar` конфигов.

## 10. Известные ограничения / риск
- Переключение live↔fallback = замена feeder-процесса: **~0.5–2 с** дыра на выходе.
  Для «ни одного потерянного кадра» нужен Liquidsoap (`fallback`-источник внутри
  одного выхода). Это следующий шаг, не включён в MVP.
- Непрерывность выхода проверена локально (см. чек-лист ниже) на фейковых потоках;
  на реальных VK/YouTube требует тестов с живыми ключами (не выполнено без ключей).
- Превью `preview.<домен>` оставлено без auth (только просмотр, без контроля). При
  необходимости — включить BasicAuth, но учти: браузер может не показать промпт внутри
  iframe (тогда — токенизированный путь).

## 11. Чек-лист отказоустойчивости (Этап D)
Выполняй и фиксируй «ожидаемое/фактическое». Сценарии 1–5 проверяемы без площадок.
| # | Действие | Ожидаемый результат |
|---|----------|---------------------|
| 1 | Телефон стримит, открыть панель | tatami=ONLINE, broadcast=ONLINE/LIVE |
| 2 | Закрыть приложение телефона | tatami→OFF за ~5s, broadcast остаётся ONLINE→FALLBACK |
| 3 | Отключить сеть телефона | то же, другие татами не затронуты |
| 4 | Вернуть связь через несколько сек | broadcast сам возвращается FALLBACK→LIVE |
| 5 | Длительный перерыв (минуты) | заставка крутится, выход не рвётся, возврат автоматом |
| 6 | `docker compose restart supervisor` (1 компонент) | все broadcast восстановлены < ~3s |
| 7 | Выход площадки недоступен | публикация на площадку ретраится; сам broadcast/другые не падают |
| 8 | 8 входов + несколько выходов под нагрузкой | без каскадных сбоев; CPU/трафик в норме |
> Логи `supervisor` — источник правды о переключениях; сверяй таймстампы с панелью.
