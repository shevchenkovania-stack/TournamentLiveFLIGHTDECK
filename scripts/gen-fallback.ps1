# Generates looping fallback MP4s (stop-cards), one per tatami — what the audience
# sees on the platform (VK/YouTube) while a phone's stream is down.
#
# Frame 1920x1080, brand background: fallback/banner_background.png
#   (the quiet zone x<1000 / y<820 is reserved for the text — do not put anything there).
#
# Text block (quiet zone): start (20,20), font 50px, line step 60px, color #0064FF
# (RGB 0,100,255, arial). Lines: ID, Port, Ver, Platform, Mode, up to 5 "IP:" lines,
# then the message.
#
# Optional poster (case 2): contain-scaled into the right box x 1000..1900,
# y 100..980 — it never overlaps the text. poster='' (case 1) = background + text only.
#
# $defs holds the per-tatami card values (currently placeholder defaults:
# ID = tatami letter, Port = 1935, Ver = 2.0.4, Mode = "ручной", IP empty).
# Fill in real values before the event.
#
# Usage:  powershell -ExecutionPolicy Bypass -File scripts/gen-fallback.ps1
# Contract: tournament-live docs/15-banner-manager.md, section "Подложка стоп-баннера".

$ErrorActionPreference = 'Stop'

$defs = @(
    @{ p='a'; id='A'; port=1935; ver='2.0.4'; platform='Android'; mode='ручной'; ips=@();  message='Трансляция скоро продолжится'; poster='' },
    @{ p='b'; id='B'; port=1935; ver='2.0.4'; platform='Android'; mode='ручной'; ips=@();  message='Трансляция скоро продолжится'; poster='' },
    @{ p='c'; id='C'; port=1935; ver='2.0.4'; platform='Android'; mode='ручной'; ips=@();  message='Трансляция скоро продолжится'; poster='' },
    @{ p='d'; id='D'; port=1935; ver='2.0.4'; platform='Android'; mode='ручной'; ips=@();  message='Трансляция скоро продолжится'; poster='' },
    @{ p='e'; id='E'; port=1935; ver='2.0.4'; platform='Android'; mode='ручной'; ips=@();  message='Трансляция скоро продолжится'; poster='' },
    @{ p='f'; id='F'; port=1935; ver='2.0.4'; platform='Android'; mode='ручной'; ips=@();  message='Трансляция скоро продолжится'; poster='' },
    @{ p='g'; id='G'; port=1935; ver='2.0.4'; platform='Android'; mode='ручной'; ips=@();  message='Трансляция скоро продолжится'; poster='' },
    @{ p='h'; id='H'; port=1935; ver='2.0.4'; platform='Android'; mode='ручной'; ips=@();  message='Трансляция скоро продолжится'; poster='' }
)

$root = Split-Path -Parent $PSScriptRoot
$bg   = Join-Path $root 'fallback\banner_background.png'
$font = 'C\:/Windows/Fonts/arial.ttf'

if (-not (Test-Path $bg)) { throw "background not found: $bg (copy images/banner_background.png from tournament-live into fallback/)" }

function DText([string]$txt, [int]$line) {
    # One text line at (20, 20+60*line), 50px, #0064FF.
    # A literal colon inside drawtext is written as \:.
    $esc = $txt -replace ':', '\:'
    "drawtext=fontfile='$font':text='$esc':fontsize=50:fontcolor=0x0064FF:x=20:y=$((20 + 60 * $line))"
}

$failed = $false
foreach ($d in $defs) {
    $out = Join-Path $root "fallback\fallback_$($d.p).mp4"

    $lines = @("ID: $($d.id)", "Port: $($d.port)", "Ver: $($d.ver)",
               "Platform: $($d.platform)", "Mode: $($d.mode)")
    foreach ($ip in $d.ips) { $lines += "IP: $ip" }
    $lines += $d.message
    $dt = @()
    for ($i = 0; $i -lt $lines.Count; $i++) { $dt += DText $lines[$i] $i }

    if ([string]::IsNullOrEmpty($d.poster)) {
        # case 1: background + text only
        ffmpeg -hide_banner -loglevel error -y `
            -loop 1 -framerate 30 -i $bg `
            -f lavfi -i 'anullsrc=channel_layout=stereo:sample_rate=44100' `
            -vf ($dt -join ',') `
            -map 0:v -map 1:a `
            -t 6 -r 30 `
            -c:v libx264 -pix_fmt yuv420p -profile:v baseline -level 4.0 -g 30 -crf 18 `
            -c:a aac -ar 44100 -b:a 64k -shortest `
            $out
    } else {
        # case 2: + poster in the right box (x 1000..1900, y 100..980);
        # the text stays in the quiet zone and never touches the poster
        $poster = $d.poster
        if (-not [IO.Path]::IsPathRooted($poster)) { $poster = Join-Path $root $poster }
        $fc = "[1:v]scale=900:880:force_original_aspect_ratio=decrease,format=rgba[p];" +
              "[0:v][p]overlay=x='1000+(900-overlay_w)/2':y='100+(880-overlay_h)/2'[base];" +
              "[base]" + ($dt -join ',') + "[v]"
        ffmpeg -hide_banner -loglevel error -y `
            -loop 1 -framerate 30 -i $bg `
            -i $poster `
            -f lavfi -i 'anullsrc=channel_layout=stereo:sample_rate=44100' `
            -filter_complex $fc `
            -map '[v]' -map 2:a `
            -t 6 -r 30 `
            -c:v libx264 -pix_fmt yuv420p -profile:v baseline -level 4.0 -g 30 -crf 18 `
            -c:a aac -ar 44100 -b:a 64k -shortest `
            $out
    }
    $code = $LASTEXITCODE
    if ($code -eq 0) {
        Write-Host "generated $out"
    } else {
        Write-Host "FAILED $out (ffmpeg exit=$code)"
        $failed = $true
    }
}

if ($failed) { throw 'one or more fallbacks failed' }
Write-Host 'All stop-cards regenerated (1920x1080, 6s loop). To apply on a running stack:'
Write-Host 'restart the letter feeders (panel END/RESUME) or restart the supervisor container.'
