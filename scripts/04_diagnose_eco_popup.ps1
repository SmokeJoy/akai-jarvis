param(
    [string]$DeviceId = "192.168.1.103:5555"
)
# scripts/04_diagnose_eco_popup.ps1
# Cattura dati diagnostici in SOLA LETTURA al momento esatto del popup Eco.
# Nessuna modifica al televisore o alle impostazioni.

$ErrorActionPreference = 'Stop'

# Risoluzione percorso ADB
$adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
if (-not $adb) {
    $wingetAdb = Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Path
    if ($wingetAdb) { $adb = $wingetAdb }
}
if (-not $adb) { throw 'ADB non trovato nel sistema.' }

# Verifica / Connessione dispositivo
$lines = @(& $adb devices)
$active = @($lines | ForEach-Object { if ($_ -match '^([^\s]+)\s+device\s*$') { $Matches[1] } })
if ($active -notcontains $DeviceId) {
    Write-Host "Tentativo di connessione verso $DeviceId..." -ForegroundColor Cyan
    & $adb connect $DeviceId | Out-Null
    Start-Sleep -Seconds 1
    $lines = @(& $adb devices)
    $active = @($lines | ForEach-Object { if ($_ -match '^([^\s]+)\s+device\s*$') { $Matches[1] } })
}

if ($active -notcontains $DeviceId) {
    throw "Dispositivo '$DeviceId' non raggiungibile o non autorizzato. Verifica la connessione di rete della TV."
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " AKAI TV - DIAGNOSI POPUP ECO (SOLA LETTURA)" -ForegroundColor Cyan
Write-Host " Dispositivo collegato: $DeviceId" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Quando il popup Eco o il messaggio sul risparmio energetico" -ForegroundColor Yellow
Write-Host "compare sullo schermo della TV, premi INVIO qui sotto." -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Cyan

Read-Host "Premi INVIO appena il popup e' visibile..."

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupDir = Join-Path $PSScriptRoot "..\backups\eco_capture_$stamp"
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

Write-Host "`nCattura diagnostica in corso (finestre, activity, SurfaceFlinger, logcat)..." -ForegroundColor Cyan

# 1. Dumpsys Window
$wfile = Join-Path $backupDir "eco_window.txt"
& $adb -s $DeviceId shell dumpsys window 2>&1 | Out-File $wfile -Encoding UTF8

# 2. Dumpsys Activity
$afile = Join-Path $backupDir "eco_activity.txt"
& $adb -s $DeviceId shell dumpsys activity activities 2>&1 | Out-File $afile -Encoding UTF8

# 3. SurfaceFlinger Layers (rileva overlay hardware e layer OSD grafici del TV)
$sfile = Join-Path $backupDir "eco_surfaceflinger_layers.txt"
& $adb -s $DeviceId shell dumpsys SurfaceFlinger --list 2>&1 | Out-File $sfile -Encoding UTF8

# 4. Logcat recente (ultime 600 righe con timestamp per rilevare broadcast/intent)
$lfile = Join-Path $backupDir "eco_logcat_recent.txt"
& $adb -s $DeviceId shell logcat -d -v time -t 600 2>&1 | Out-File $lfile -Encoding UTF8

# 5. Elaborazione sintetica locale
$focusKeywords = 'mCurrentFocus|mFocusedApp|mFocusedWindow|mTopFocusedDisplay|topResumedActivity|mFocusedActivity'
$focusLines = Get-Content $wfile, $afile | Select-String -Pattern $focusKeywords | ForEach-Object { $_.Line.Trim() }

$logKeywords = 'eco|energy|power|standby|sleep|dialog|toast|retail|timer'
$logLines = Get-Content $lfile | Select-String -Pattern $logKeywords -CaseSensitive:$false | Select-Object -Last 25 | ForEach-Object { $_.Line.Trim() }

$layers = Get-Content $sfile

$summaryFile = Join-Path $backupDir "ECO_DIAGNOSI_SUMMARY.txt"
$summaryText = @"
==========================================================
 AKAI TV - DIAGNOSI POPUP ECO ($stamp)
==========================================================
1. FOCUS E FINESTRA ATTIVA:
$($focusLines -join "`n")

2. LAYER GRAFICI ATTIVI (SurfaceFlinger):
$($layers -join "`n")

3. EVENTI RILEVANTI NEL LOGCAT RECENTE (Filtro 'eco/power/sleep/dialog'):
$($logLines -join "`n")

File completi archiviati in: $backupDir
==========================================================
"@

$summaryText | Out-File $summaryFile -Encoding UTF8
Write-Host "`nDiagnostica completata!" -ForegroundColor Green
Write-Host $summaryText -ForegroundColor White
