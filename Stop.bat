@echo off
setlocal
cd /d "%~dp0"
echo Stopping TournamentLive streaming stack...
docker compose down
pause
