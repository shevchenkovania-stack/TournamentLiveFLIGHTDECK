@echo off
setlocal
cd /d "%~dp0"
echo Starting TournamentLive streaming stack (MediaMTX + panel + supervisor + relay)...
docker compose up -d --build
echo.
echo   Cockpit (panel):   http://localhost:8000
echo   Phone players:     http://localhost:8888/broadcast/a   (b, c, d, e)
echo   Edit platform URLs in:  outputs\outputs.conf   (then: docker compose restart relayer)
echo.
echo To change platform links later, edit outputs\outputs.conf and double-click Restart-Relay.bat
pause
