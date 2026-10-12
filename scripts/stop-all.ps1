# TournamentLive streaming infra — one-command tear-down (local MVP).
# Stops the supervisor, all FFmpeg (test streams + broadcast feeders), and MediaMTX.
#
# Usage:  powershell -ExecutionPolicy Bypass -File scripts/stop-all.ps1

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

Write-Host "== Stopping supervisor ==" -ForegroundColor Cyan
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*supervisor.ps1*' } |
    ForEach-Object { Write-Host "   kill pid $($_.ProcessId)"; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Write-Host "== Stopping all FFmpeg (tests + feeders) ==" -ForegroundColor Cyan
Get-Process ffmpeg -ErrorAction SilentlyContinue | Stop-Process -Force
Write-Host "   ffmpeg stopped"

Write-Host "== Stopping MediaMTX ==" -ForegroundColor Cyan
docker compose down

Write-Host "All stopped." -ForegroundColor Green
