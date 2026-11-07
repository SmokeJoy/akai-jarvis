param (
    [string]$Query = "quali canali preferisco?"
)

$token = "c7f7415a26c49e031070159e2ec6a2b76dcaa28345004462596d11630ef466e6"
$jsonBody = @{
    query = $Query
    speak = $false
    source = "web_remote"
} | ConvertTo-Json -Compress

$tmpFile = [System.IO.Path]::GetTempFileName()
[System.IO.File]::WriteAllText($tmpFile, $jsonBody, [System.Text.Encoding]::UTF8)

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$res = curl.exe -k -s -X POST `
    -H "Authorization: Bearer $token" `
    -H "Content-Type: application/json; charset=utf-8" `
    --data-binary "@$tmpFile" `
    https://192.168.1.8:8443/api/ai/ask
$sw.Stop()

Remove-Item $tmpFile -Force

Write-Host "Query: '$Query'"
Write-Host "Tempo impiegato: $($sw.ElapsedMilliseconds) ms"
Write-Host "Risposta TV:"
Write-Host $res
