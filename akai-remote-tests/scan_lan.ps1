$tasks = @()
$pings = @()
1..254 | ForEach-Object {
    $ip = "192.168.1.$_"
    $p = New-Object System.Net.NetworkInformation.Ping
    $pings += $p
    $tasks += $p.SendPingAsync($ip, 300)
}

[System.Threading.Tasks.Task]::WaitAll($tasks)

Write-Host "Host online:"
for ($i = 0; $i -lt $tasks.Count; $i++) {
    if ($tasks[$i].Result.Status -eq "Success") {
        Write-Host "  $($tasks[$i].Result.Address.ToString())"
    }
}
