param([string]$TvIp = "")
# Operazione: tentativo di connessione ADB. Nessuna modifica al firmware.
$ErrorActionPreference = 'Stop'
$adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
if (-not $adb) {
    $wingetAdb = Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Path
    if ($wingetAdb) { $adb = $wingetAdb }
}
if (-not $adb) { throw "ADB non trovato: apri un nuovo terminale e verifica adb version." }
if (-not $TvIp) { $TvIp = Read-Host 'IP locale della TV' }
$parsed = $null
if (-not ([System.Net.IPAddress]::TryParse($TvIp, [ref]$parsed)) -or $parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw "Inserisci un indirizzo IPv4 valido (senza porta), per esempio 192.168.1.100."
}
$target = "${TvIp}:5555"
Write-Host "Provo $target. Se la TV non abilita ADB sulla rete, il collegamento fallira'." -ForegroundColor Cyan
$result = & $adb connect $target 2>&1
$result | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw "ADB connect non riuscito: controlla le opzioni della TV e la rete." }
$devices = @(& $adb devices)
$found = @($devices | Where-Object { $_ -match ('^' + [regex]::Escape($target) + '\s+device\s*$') })
if ($found.Count -ne 1) {
    $devices | ForEach-Object { Write-Host $_ }
    throw "TV non autorizzata o non connessa. Verifica eventuale richiesta di autorizzazione sulla TV."
}
Write-Host "Connesso e autorizzato: $target" -ForegroundColor Green
