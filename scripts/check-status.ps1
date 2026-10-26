# Temporary test probe: raw JSON of one input + one output path
foreach ($n in 'tatami/1','broadcast/a') {
    Write-Host "--- $n ---"
    try { (Invoke-RestMethod "http://localhost:9997/v3/paths/get/$n") | ConvertTo-Json -Depth 4 -Compress } catch { Write-Host "error: $_" }
}
