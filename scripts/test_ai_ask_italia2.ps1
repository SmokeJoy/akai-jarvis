$token = "c7f7415a26c49e031070159e2ec6a2b76dcaa28345004462596d11630ef466e6"
$headers = @{ "Authorization" = "Bearer $token" }
$body = @{ query = "Metti Italia 2"; source = "test_script" } | ConvertTo-Json

Write-Host "Inviando richiesta AI: 'Metti Italia 2'..." -ForegroundColor Cyan
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$res = Invoke-RestMethod -Uri "http://192.168.1.8:8088/api/ai/ask" -Method POST -Headers $headers -ContentType "application/json" -Body $body
$sw.Stop()

Write-Host "`n=== RISPOSTA ASSISTENTE AI ===" -ForegroundColor Green
$res | ConvertTo-Json -Depth 5
Write-Host "Tempo chiamata HTTP: $($sw.ElapsedMilliseconds) ms" -ForegroundColor Yellow
