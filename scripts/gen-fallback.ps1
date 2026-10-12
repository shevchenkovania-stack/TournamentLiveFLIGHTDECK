# Generates looping fallback MP4s, one per tatami, used when a phone's live stream
# drops WITHOUT a graceful stop (unplanned interruption). This is what the audience
# sees on the platform (VK/YouTube) until the phone reconnects.
#
# Style: a bright, ANIMATED test card (ffmpeg "testsrc2") tinted to a distinct hue
# per tatami, with a big tatami label + a "connection recovering" subtitle so it is
# obviously a technical pause and not a dead stream.
#
# Usage: powershell -ExecutionPolicy Bypass -File gen-fallback.ps1

$defs = @(
    @{ p = 'a'; label = 'TATAMI A'; hue = 0 },
    @{ p = 'b'; label = 'TATAMI B'; hue = 72 },
    @{ p = 'c'; label = 'TATAMI C'; hue = 144 },
    @{ p = 'd'; label = 'TATAMI D'; hue = 216 },
    @{ p = 'e'; label = 'TATAMI E'; hue = 288 },
    @{ p = 'f'; label = 'TATAMI F'; hue = 36 },
    @{ p = 'g'; label = 'TATAMI G'; hue = 108 },
    @{ p = 'h'; label = 'TATAMI H'; hue = 180 }
)

New-Item -ItemType Directory -Force -Path fallback | Out-Null

$font = 'C\:/Windows/Fonts/arial.ttf'
$sub  = 'connection recovering...'

foreach ($d in $defs) {
    $out = "fallback/fallback_$($d.p).mp4"

    # Animated colorful source -> per-tatami hue -> two centered text lines.
    $vf = "testsrc2=size=1280x720:rate=30," +
          "hue=h=$($d.hue)," +
          "drawtext=fontfile='${font}':text='$($d.label)':fontsize=88:fontcolor=white:borderw=4:bordercolor=black@0.7:x=(w-text_w)/2:y=(h/2)-90," +
          "drawtext=fontfile='${font}':text='${sub}':fontsize=40:fontcolor=yellow:borderw=3:bordercolor=black@0.7:x=(w-text_w)/2:y=(h/2)+30"

    ffmpeg -hide_banner -loglevel error -y `
        -f lavfi -i "color=c=black:s=1280x720:r=30" `
        -f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=44100" `
        -f lavfi -i $vf `
        -map 2:v -map 1:a `
        -t 6 `
        -c:v libx264 -pix_fmt yuv420p -profile:v baseline -level 3.1 -g 30 `
        -c:a aac -ar 44100 -b:a 64k -shortest `
        $out
    Write-Host ("generated {0} (exit={1})" -f $out, $LASTEXITCODE)
}

Write-Host ""
Write-Host "Fallback cards regenerated. Files live in ./fallback/ and are mounted read-only"
Write-Host "into the supervisor container (FALLBACK_DIR=/fallback)."
