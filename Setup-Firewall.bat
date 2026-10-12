@echo off
:: One-time setup: open Windows Firewall so phones on the LAN can push RTMP to this PC.
:: Double-click it once. It will ask for Admin (UAC) by itself.
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrator rights...
  powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
echo Adding firewall rules for TournamentLive (RTMP 1935, HLS/WebRTC 8888, API 9997)...
netsh advfirewall firewall add rule name="TL RTMP 1935" dir=in action=allow protocol=TCP localport=1935
netsh advfirewall firewall add rule name="TL HLS 8888"  dir=in action=allow protocol=TCP localport=8888
netsh advfirewall firewall add rule name="TL API 9997"  dir=in action=allow protocol=TCP localport=9997
echo Done. Phones can now push to rtmp://THIS-PC-IP:1935/tatami/
pause
