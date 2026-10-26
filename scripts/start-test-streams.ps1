# Launches 8 synthetic RTMP test streams (fake cameras) into MediaMTX tatami/1..8.
# Each stream has a distinct hue + resolution so screens are visually distinguishable.
# These are placeholders for real phones; remove this once TournamentLive devices push in.
#
# Usage:  powershell -ExecutionPolicy Bypass -File start-test-streams.ps1
# Stop :  powershell -ExecutionPolicy Bypass -File stop-test-streams.ps1

param(
    [string]$ServerHost = "localhost"
)

$defs = @(
    @{ path = '1'; label = 'SCREEN 1'; w = 1280; h = 720; hue = 0 },
    @{ path = '2'; label = 'SCREEN 2'; w = 1280; h = 720; hue = 72 },
    @{ path = '3'; label = 'SCREEN 3'; w = 640;  h = 480; hue = 144 },
    @{ path = '4'; label = 'SCREEN 4'; w = 640;  h = 480; hue = 216 },
    @{ path = '5'; label = 'SCREEN 5'; w = 640;  h = 480; hue = 288 },
    @{ path = '6'; label = 'SCREEN 6'; w = 640;  h = 480; hue = 36 },
    @{ path = '7'; label = 'SCREEN 7'; w = 640;  h = 480; hue = 108 },
    @{ path = '8'; label = 'SCREEN 8'; w = 640;  h = 480; hue = 180 }
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
Write-Host "All 8 test streams launched. Preview at http://localhost:8888/tatami/<1..8>"
