$token = "c7f7415a26c49e031070159e2ec6a2b76dcaa28345004462596d11630ef466e6"
$headers = @{ "Authorization" = "Bearer $token" }

Write-Host "=== TEST 1: SIMULAZIONE BLOCCO PREVENTIVO (INSUFFICIENT BUDGET) ===" -ForegroundColor Cyan
$body1 = @{
    test_type = "insufficient_budget"
    simulated_remaining = 0.01
    simulated_estimate = 0.02
} | ConvertTo-Json

$res1 = Invoke-RestMethod -Uri "http://192.168.1.8:8088/api/ai/simulate_budget" -Method POST -Headers $headers -ContentType "application/json" -Body $body1
$res1 | ConvertTo-Json -Depth 5

Write-Host "`n=== TEST 2: SIMULAZIONE CONCORRENZA ATOMICA (CONCURRENT RESERVATIONS) ===" -ForegroundColor Cyan
$body2 = @{
    test_type = "concurrent_reservation"
} | ConvertTo-Json

$res2 = Invoke-RestMethod -Uri "http://192.168.1.8:8088/api/ai/simulate_budget" -Method POST -Headers $headers -ContentType "application/json" -Body $body2
$res2 | ConvertTo-Json -Depth 5
