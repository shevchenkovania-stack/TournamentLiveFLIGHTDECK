# Launches 8 synthetic RTMP test streams (fake cameras) into MediaMTX tatami/a..h.
# Each stream has a distinct hue + resolution so tatami are visually distinguishable.
# These are placeholders for real phones; remove this once TournamentLive devices push in.
#
# Usage:  powershell -ExecutionPolicy Bypass -File start-test-streams.ps1
# Stop :  powershell -ExecutionPolicy Bypass -File stop-test-streams.ps1

param(
    [string]$ServerHost = "localhost"
)

$defs = @(
    @{ path = 'a'; label = 'TATAMI A'; w = 1280; h = 720; hue = 0 },
    @{ path = 'b'; label = 'TATAMI B'; w = 1280; h = 720; hue = 72 },
    @{ path = 'c'; label = 'TATAMI C'; w = 640;  h = 480; hue = 144 },
    @{ path = 'd'; label = 'TATAMI D'; w = 640;  h = 480; hue = 216 },
    @{ path = 'e'; label = 'TATAMI E'; w = 640;  h = 480; hue = 288 },
    @{ path = 'f'; label = 'TATAMI F'; w = 640;  h = 480; hue = 36 },
    @{ path = 'g'; label = 'TATAMI G'; w = 640;  h = 480; hue = 108 },
    @{ path = 'h'; label = 'TATAMI H'; w = 640;  h = 480; hue = 180 }
)

foreach ($d in $defs) {
    $dst = "rtmp://${ServerHost}:1935/tatami/$($d.path)"
    $vf  = "hue=h=$($d.hue)"

    $ffargs = @(
        "-hide_banner", "-loglevel", "error", "-re",
        "-f", "lavfi", "-i", "testsrc=size=$($d.w)x$($d.h):rate=30",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100",
        "-vf", $vf,
        "-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency",
        "-profile:v", "baseline", "-level", "3.0", "-pix_fmt", "yuv420p", "-g", "30",
        "-c:a", "aac", "-ar", "44100", "-b:a", "64k",
        "-f", "flv", $dst
    )

    Start-Process -FilePath "ffmpeg" -ArgumentList $ffargs -WindowStyle Hidden
    Write-Host "Started -> $dst  ($($d.label), hue=$($d.hue), $($d.w)x$($d.h))"
}

Write-Host ""
Write-Host "All 8 test streams launched. Preview at http://localhost:8888/tatami/<a..h>"
