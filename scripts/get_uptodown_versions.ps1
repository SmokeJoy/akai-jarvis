$url = "https://raiplay-android-tv.it.uptodown.com/android/versions"
$headers = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" }
try {
    $res = Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing
    $matches = [regex]::Matches($res.Content, 'data-url="([^"]+)"[^>]*>[\s\r\n]*<span class="version">([^<]+)</span>')
    foreach ($m in $matches) {
        Write-Output "$($m.Groups[2].Value) -> $($m.Groups[1].Value)"
    }
} catch {
    Write-Output "Errore: $_"
}
