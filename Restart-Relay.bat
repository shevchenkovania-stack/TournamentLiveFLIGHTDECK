@echo off
setlocal
cd /d "%~dp0"
echo Restarting relay after editing outputs\outputs.conf ...
docker compose up -d --build relayer
echo Relay reloaded. Live logs:  docker compose logs -f relayer
pause
