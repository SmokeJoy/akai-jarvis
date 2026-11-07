# ==============================================================================
# AKAI Custom TV - Script 10: Recupero e Analisi Diagnostica Autonoma
# Recupera i log registrati a bordo della TV senza PC acceso
# ==============================================================================

param(
    [string]$TvIp = "192.168.1.8",
    [int]$RemotePort = 8088
)

$ErrorActionPreference = "Continue"

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host " AKAI Custom TV - Recupero Telemetria Autonoma TV" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan

$workspace = "C:\Users\danie\OneDrive\Documenti\Antygravity\Akay"
$diagDir = Join-Path $workspace "diagnostics"
if (-not (Test-Path $diagDir)) {
    New-Item -ItemType Directory -Path $diagDir -Force | Out-Null
}

$timestampStr = (Get-Date).ToString("yyyyMMdd_HHmmss")
$localFile = Join-Path $diagDir "telemetry_$timestampStr.jsonl"
$latestFile = Join-Path $diagDir "telemetry_latest.jsonl"

$retrieved = $false
$rawContent = ""

# Metodo 1: Recupero wireless tramite API REST locale porta 8088 (anche se ADB e chiuso)
Write-Host "`n[1/3] Tentativo recupero tramite API REST locale..." -ForegroundColor Yellow
try {
    $rawContent = Invoke-RestMethod -Uri "http://$($TvIp):$($RemotePort)/api/diagnostics" -TimeoutSec 5 -ErrorAction Stop
    if ($rawContent -and $rawContent.Length -gt 10) {
        $len = $rawContent.Length
        Write-Host "      Recupero via HTTP completato con successo: $len byte" -ForegroundColor Green
        $retrieved = $true
    }
} catch {
    Write-Host "      API HTTP non raggiungibile. Passo al fallback ADB..." -ForegroundColor DarkYellow
}

# Metodo 2: Fallback via ADB (su 0 cat)
if (-not $retrieved) {
    Write-Host "`n[2/3] Tentativo recupero tramite canale ADB TCP 5555..." -ForegroundColor Yellow
    $adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
    if (-not (Test-Path $adb)) { $adb = "adb" }

    & $adb connect "${TvIp}:5555" | Out-Null
    Start-Sleep -Milliseconds 500
    $rawContent = & $adb -s "${TvIp}:5555" shell "su 0 cat /data/data/it.akai.customremote/files/akai_diagnostics.jsonl"
    if ($rawContent -and $rawContent.Length -gt 10) {
        Write-Host "      Recupero via ADB completato con successo!" -ForegroundColor Green
        $retrieved = $true
    }
}

if (-not $retrieved -or [string]::IsNullOrWhiteSpace($rawContent)) {
    Write-Host "`n[ERRORE] Impossibile recuperare i dati diagnostici dalla TV. Verifica che la TV sia accesa e connessa al Wi-Fi ($TvIp)." -ForegroundColor Red
    exit 1
}

# Salvataggio su file locale
Set-Content -Path $localFile -Value $rawContent -Encoding UTF8
Set-Content -Path $latestFile -Value $rawContent -Encoding UTF8
Write-Host "      Dati archiviati in: $localFile" -ForegroundColor Cyan

# ==============================================================================
# Analisi Statistica e Rilevamento Anomalie
# ==============================================================================
Write-Host "`n[3/3] Elaborazione metrica dei campioni raccolti..." -ForegroundColor Yellow

$lines = $rawContent -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

$samples = @()
$boots = @()
$errors = @()
$events = @()

foreach ($line in $lines) {
    try {
        $obj = $line | ConvertFrom-Json
        switch ($obj.type) {
            "sample" { $samples += $obj }
            "boot"   { $boots += $obj }
            "error"  { $errors += $obj }
            default  { $events += $obj }
        }
    } catch {}
}

Write-Host "========================================================" -ForegroundColor Green
Write-Host " REPORT DIAGNOSTICO AUTONOMO - RISULTATI ANALISI" -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green

Write-Host "Totale Campioni Registrati   : $($samples.Count)"
Write-Host "Eventi di Riavvio Registrati : $($boots.Count)"
Write-Host "Errori Rilevati a Bordo      : $($errors.Count)"

if ($samples.Count -gt 0) {
    $firstSample = $samples[0]
    $lastSample = $samples[$samples.Count - 1]

    $availArr = $samples | ForEach-Object { [int]$_.mem_avail_mb }
    $swapArr  = $samples | ForEach-Object { [int]$_.swap_used_mb }
    $launcherArr = $samples | Where-Object { $_.launcher_pss_mb -gt 0 } | ForEach-Object { [int]$_.launcher_pss_mb }

    $minAvail = ($availArr | Measure-Object -Minimum).Minimum
    $maxAvail = ($availArr | Measure-Object -Maximum).Maximum
    $avgAvail = [math]::Round(($availArr | Measure-Object -Average).Average, 1)

    $minSwap = ($swapArr | Measure-Object -Minimum).Minimum
    $maxSwap = ($swapArr | Measure-Object -Maximum).Maximum
    $avgSwap = [math]::Round(($swapArr | Measure-Object -Average).Average, 1)

    Write-Host "`n--- MEMORIA E RISORSE DI SISTEMA ---" -ForegroundColor Cyan
    Write-Host "Finestra Temporale   : Da $($firstSample.time) a $($lastSample.time)"
    Write-Host "RAM Libera (Media)   : $avgAvail MB (Min: $minAvail MB, Max: $maxAvail MB)"
    Write-Host "Swap ZRAM (Media)    : $avgSwap MB (Min: $minSwap MB, Max: $maxSwap MB)"

    if ($launcherArr.Count -gt 0) {
        $avgLauncher = [math]::Round(($launcherArr | Measure-Object -Average).Average, 1)
        $maxLauncher = ($launcherArr | Measure-Object -Maximum).Maximum
        Write-Host "Launcher PSS (Media) : $avgLauncher MB (Picco Max: $maxLauncher MB)"
    }

    # Verifica Memory Leak o degrado swap
    if ($minAvail -lt 300) {
        Write-Host "ATTENZIONE: Rilevato picco di memoria libera inferiore a 300MB ($minAvail MB)!" -ForegroundColor Red
    } else {
        Write-Host "Stato RAM: OTTIMO (Memoria libera sempre superiore a 300MB)" -ForegroundColor Green
    }

    if ($maxSwap -gt 250) {
        Write-Host "ATTENZIONE: Uso swap ZRAM elevato (> 250MB)!" -ForegroundColor Yellow
    } else {
        Write-Host "Stato Swap ZRAM: STABILE E SOTTO CONTROLLO (Max: $maxSwap MB)" -ForegroundColor Green
    }
}

if ($errors.Count -gt 0) {
    Write-Host "`n--- ERRORI REGISTRATI ($($errors.Count)) ---" -ForegroundColor Red
    foreach ($err in $errors) {
        Write-Host "[$($err.time)] ($($err.source)): $($err.message)" -ForegroundColor Red
    }
} else {
    Write-Host "`nZero errori o anomalie registrati nel periodo!" -ForegroundColor Green
}

Write-Host "`nAnalisi completata con successo." -ForegroundColor Cyan
