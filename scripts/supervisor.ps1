# TournamentLive stream supervisor (local MVP) - NUMBERED-KEY model.
# For each screen (internal letter a..h = ЭКРАН 1..8) it keeps broadcast/<x> alive:
#   - if key N is publishing live to tatami/<N>  -> feed broadcast/<x> from the live stream
#   - if tatami/<N> is offline                   -> feed broadcast/<x> by looping fallback/<x>.mp4
# Platforms (VK/YouTube) and the dashboard read broadcast/<x>, which stays (near) continuously online,
# so the outbound publication is NOT recreated on input loss (only a sub-second feeder swap).
#
# Idempotent: one feeder process per screen; restarts only when the desired source changes
# or when the current feeder process has exited.
#
# Usage:  powershell -ExecutionPolicy Bypass -File supervisor.ps1

param(
    [string[]]$Tatamis   = @('a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'),
    [int]$IntervalSec    = 2,
    [string]$ServerHost  = 'localhost'
)

$RtmpBase = "rtmp://${ServerHost}:1935"
$ApiBase  = "http://${ServerHost}:9997"
$root     = Get-Location

function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Write-Host $line
    Add-Content -Path (Join-Path $root 'logs/supervisor.log') -Value $line
}

function Start-Feeder($t, $mode) {
    $key = [array]::IndexOf($Tatamis, $t) + 1   # letter a..h -> ingest key 1..8
    $dst = "$RtmpBase/broadcast/$t"
    if ($mode -eq 'live') {
        $ffargs = @('-hide_banner', '-loglevel', 'error',
                    '-i', "$RtmpBase/tatami/$key",
                    '-c', 'copy', '-fflags', '+genpts',
                    '-f', 'flv', $dst)
    }
    else {
        $file = Join-Path $root "fallback/fallback_$t.mp4"
        $ffargs = @('-hide_banner', '-loglevel', 'error',
                    '-re', '-stream_loop', '-1', '-i', $file,
                    '-c', 'copy', '-fflags', '+genpts',
                    '-f', 'flv', $dst)
    }
    $p = Start-Process -FilePath 'ffmpeg' -ArgumentList $ffargs -PassThru -WindowStyle Hidden
    return $p.Id
}

New-Item -ItemType Directory -Force -Path logs | Out-Null

$state = @{}
foreach ($t in $Tatamis) { $state[$t] = @{ mode = $null; pid = $null } }

Log "Supervisor started for screens: $($Tatamis -join ',') (keys 1..$($Tatamis.Count))"

while ($true) {
    # Read all path online flags in one API call
    $online = @{}
    try {
        $list = (Invoke-WebRequest "$ApiBase/v3/paths/list" -UseBasicParsing -TimeoutSec 4).Content | ConvertFrom-Json
        foreach ($it in $list.items) { $online[$it.name] = [bool]$it.online }
    }
    catch {
        Log "API unreachable: $($_.Exception.Message) - assuming all offline"
    }

    foreach ($t in $Tatamis) {
        $key      = [array]::IndexOf($Tatamis, $t) + 1
        $isLive   = [bool]$online["tatami/$key"]
        $desired  = if ($isLive) { 'live' } else { 'fallback' }
        $cur      = $state[$t]
        $alive    = ($cur.pid -and (Get-Process -Id $cur.pid -ErrorAction SilentlyContinue))

        if ((-not $alive) -or ($cur.mode -ne $desired)) {
            if ($alive) { Stop-Process -Id $cur.pid -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Milliseconds 400   # grace to free the broadcast path
            $newPid = Start-Feeder $t $desired
            $reason = if (-not $alive) { 'feeder dead' } else { "mode $($cur.mode)->$desired" }
            Log "key $key -> screen $t : $reason ; feeding broadcast/$t via $desired (pid=$newPid)"
            $cur.mode = $desired
            $cur.pid  = $newPid
        }
    }

    Start-Sleep -Seconds $IntervalSec
}
