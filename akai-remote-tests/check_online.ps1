$ips = @("192.168.1.3", "192.168.1.5", "192.168.1.8", "192.168.1.9", "192.168.1.10", "192.168.1.103")
foreach ($ip in $ips) {
    $t = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $t.BeginConnect($ip, 5555, $null, $null)
        $wh = $ar.AsyncWaitHandle.WaitOne(800, $false)
        if ($wh -and $t.Connected) {
            Write-Host "PORT 5555 OPEN: $ip" -ForegroundColor Green
            $t.EndConnect($ar)
        } else {
            Write-Host "PORT 5555 CLOSED / UNREACHABLE: $ip" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "ERROR: $ip - $_" -ForegroundColor Red
    } finally {
        $t.Dispose()
    }
}
