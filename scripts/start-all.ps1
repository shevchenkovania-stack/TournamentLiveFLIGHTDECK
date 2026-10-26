# TournamentLive streaming infra — one-command bring-up (local MVP).
# Starts the Docker stack (MediaMTX + cockpit panel + supervisor + relayer),
# (re)generates fallback clips if missing, then launches 8 test "phones".
#
# Usage:  powershell -ExecutionPolicy Bypass -File scripts/start-all.ps1
#
# NOTE: this uses synthetic FFmpeg test streams as phone placeholders. To use
# real TournamentLive phones instead, do NOT run the test streams (comment the
# start-test-streams line) and point the phones at rtmp://<thisPC-ip>:1935/tatami/ + key N
# (key N = screen number, see the panel card).
#
# NOTE: feeders + restreaming run INSIDE the supervisor/relayer containers.
# scripts/supervisor.ps1 is the legacy host-side fallback — do not run both, two
# supervisors fight for the same broadcast/<x> path.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

Write-Host "== 1/4 Starting Docker stack (MediaMTX + panel + supervisor + relayer) ==" -ForegroundColor Cyan
docker compose up -d --build
Write-Host "   tip: after editing mediamtx.yml or panel/index.html (single-file" -ForegroundColor DarkGray
Write-Host "   bind mounts) use: docker compose up -d --force-recreate mediamtx panel" -ForegroundColor DarkGray

Write-Host "== 2/4 Ensuring fallback clips exist ==" -ForegroundColor Cyan
if (-not (Test-Path "$root/fallback/fallback_a.mp4")) {
    powershell -ExecutionPolicy Bypass -File "$root/scripts/gen-fallback.ps1"
} else {
    Write-Host "   fallback clips already present"
}

Write-Host "== 3/4 Launching 8 test streams (fake phones) ==" -ForegroundColor Cyan
powershell -ExecutionPolicy Bypass -File "$root/scripts/start-test-streams.ps1"

Write-Host "== 4/4 Checking supervisors are alive (containerized) ==" -ForegroundColor Cyan
docker compose ps --format '{{.Name}}  {{.Status}}'
Write-Host "   feeder log:  docker compose logs -f supervisor"
Write-Host "   restream log: docker compose logs -f relayer"

Start-Sleep -Seconds 8
Write-Host "`nDone. Open the cockpit:  http://localhost:8000" -ForegroundColor Green
Write-Host "Per-screen raw player:   http://localhost:8888/broadcast/a .. /h (= ЭКРАН 1..8)" -ForegroundColor Green
