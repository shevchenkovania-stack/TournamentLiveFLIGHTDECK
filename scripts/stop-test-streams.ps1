# Stops all local FFmpeg test streams started by start-test-streams.ps1
Get-Process ffmpeg -ErrorAction SilentlyContinue | Stop-Process -Force
Write-Host "Stopped all FFmpeg test streams."
