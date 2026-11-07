$url = "https://d.apkpure.net/b/APK/it.rainet.androidtv?version=4.2.11"
$outFile = "scratch\raiplay_4.2.11.apk"

$headers = @{
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
}

try {
    Write-Host "Provo download da APKPure: $url" -ForegroundColor Cyan
    Invoke-WebRequest -Uri $url -OutFile $outFile -Headers $headers -TimeoutSec 30
    $len = (Get-Item $outFile).Length
    Write-Host "Download completato: $len bytes" -ForegroundColor Green
} catch {
    Write-Host "Errore download: $_" -ForegroundColor Red
}
