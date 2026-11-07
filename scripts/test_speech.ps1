$token = "c7f7415a26c49e031070159e2ec6a2b76dcaa28345004462596d11630ef466e6"
$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type" = "application/json"
}

$body = @{
    text = "Ciao, sono Jarvis per AKAI TV. Il motore vocale locale è attivo e funzionante."
    interrupt = $true
} | ConvertTo-Json

try {
    $res = Invoke-RestMethod -Uri "http://192.168.1.8:8088/api/ai/speak" -Method Post -Headers $headers -Body $body -TimeoutSec 5
    Write-Host "Risposta Speech API:"
    $res | ConvertTo-Json
} catch {
    Write-Host "Errore chiamata Speak API: $_"
}
