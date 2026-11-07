[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try {
    $url = 'https://s2salvadorigroup.it/ftp/?dir=.%2FAKAI%2FAGGIORNAMENTI+TV+AKAI'
    $res = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15
    Write-Output "Status: $($res.StatusCode)"
    $matches = [regex]::Matches($res.Content, 'href="([^"]*AKTV5037N[^"]*)"')
    foreach ($m in $matches) {
        Write-Output "Found: $($m.Groups[1].Value)"
    }
    if ($matches.Count -eq 0) {
        $lines = $res.Content -split "`n" | Where-Object { $_ -match '5037' }
        Write-Output "Lines containing 5037:"
        $lines | ForEach-Object { Write-Output $_.Trim() }
    }
} catch {
    Write-Output "Exception: $_"
}
