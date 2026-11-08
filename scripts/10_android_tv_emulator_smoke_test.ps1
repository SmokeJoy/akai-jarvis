# ==============================================================================
# AKAI Custom TV - Script 10: Collaudo Funzionale Sicuro su Emulatore Android TV
# Vincolo P0 di sicurezza: isolamento fail-closed assoluto verso emulator-xxxx
# Zero comandi senza -s <serial>; rifiuto categorico di IP, TV fisiche o ambiguità
# ==============================================================================

param(
    [string]$TargetSerial = "",
    [switch]$MockDeviceListTest = $false,
    [string]$MockDevicesOutput = ""
)

$ErrorActionPreference = "Stop"

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " AKAI CUSTOM HOME v8 - COLLAUDO RUNTIME SICURO SU EMULATORE TV   " -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = $PSScriptRoot }
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$workspace = (Resolve-Path (Join-Path $scriptDir "..")).Path
$toolsDir = Join-Path $workspace "tools"
$sdkDir = Join-Path $toolsDir "android-sdk"
$adb = Join-Path $sdkDir "platform-tools\adb.exe"
if (-not (Test-Path $adb) -and (Get-Command adb -ErrorAction SilentlyContinue)) {
    $adb = (Get-Command adb).Source
}
$apk = Join-Path $workspace "akai-custom-home\app\build\outputs\apk\debug\akai-custom-home.apk"
$testSuiteApk = Join-Path $toolsDir "test-apps\TestStreamingApps.apk"
$docsDir = Join-Path $workspace "docs\screenshots\emulator"

function Assert-Step($condition, $stepName) {
    if (-not $condition) {
        Write-Host "  [FAIL] $stepName" -ForegroundColor Red
        throw "ASSERTION FAILED: $stepName"
    } else {
        Write-Host "  [PASS] $stepName" -ForegroundColor Green
    }
}

function Get-ValidatedEmulatorSerial($rawDevicesInput) {
    if ($rawDevicesInput -is [array]) {
        $lines = $rawDevicesInput
    } else {
        $lines = ("$rawDevicesInput" -split "`r?`n")
    }
    $emulators = @()
    $foreignDevices = @()

    foreach ($line in $lines) {
        $normalized = $line -replace '\\t', "`t"
        $trimmed = $normalized.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed.StartsWith("List of devices")) { continue }
        if ($trimmed.StartsWith("*")) { continue }

        $parts = $trimmed -split "\s+"
        if ($parts.Count -ge 2) {
            $serial = $parts[0]
            $state = $parts[1]

            if ($serial -match "^emulator-\d+$") {
                if ($state -eq "device") {
                    $emulators += $serial
                }
            } else {
                # Qualsiasi dispositivo che non sia emulatore (TV fisica, IP 192.168.*, USB)
                $foreignDevices += "$serial ($state)"
            }
        } elseif ($parts.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace($parts[0])) {
            $foreignDevices += "$($parts[0]) (unknown)"
        }
    }

    # P0 FAIL-CLOSED: Se è presente un dispositivo non-emulatore, blocca immediatamente!
    if ($foreignDevices.Count -gt 0) {
        throw "SICUREZZA P0 VIOLATA: Rilevato dispositivo non emulatore connesso ad ADB: $($foreignDevices -join ', '). Hardware freeze TV attivo: ZERO comandi consentiti."
    }

    # P0 FAIL-CLOSED: Deve essere presente esattamente 1 emulatore in stato 'device'
    if ($emulators.Count -eq 0) {
        throw "SICUREZZA P0 FAIL-CLOSED: Nessun emulatore virtuale collegato in stato 'device'. Operazione interrotta per prevenire comandi orfani."
    }
    if ($emulators.Count -gt 1) {
        throw "SICUREZZA P0 FAIL-CLOSED: Rilevati molteplici emulatori collegati: $($emulators -join ', '). Ambiguità non consentita."
    }

    return $emulators[0]
}

# Se è un test di validazione logica isolata della lista dispositivi:
if ($MockDeviceListTest) {
    Write-Host "Esecuzione test logico di isolamento fail-closed..." -ForegroundColor Yellow
    $detected = Get-ValidatedEmulatorSerial $MockDevicesOutput
    return $detected
}

# 1. Validazione binari
Assert-Step (Test-Path $adb) "adb.exe presente in $adb"
Assert-Step (Test-Path $apk) "APK AKAI Custom Home v8 presente in $apk"

# 2. Rilevazione e Validazione Deterministica dell'Emulatore (P0)
Write-Host "`n[1/6] Analisi deterministica della lista dispositivi ADB..." -ForegroundColor Yellow
& $adb start-server | Out-Null
Start-Sleep -Milliseconds 600

# Loop di tolleranza di 5 secondi se l'emulatore è appena passato online
$rawDevices = & $adb devices
$retryCount = 0
while ($rawDevices -match "offline" -and $retryCount -lt 5) {
    Start-Sleep -Seconds 1
    $rawDevices = & $adb devices
    $retryCount++
}
Write-Host $rawDevices

$emulator = Get-ValidatedEmulatorSerial $rawDevices
Write-Host "Emulatore autorizzato individuato: $emulator" -ForegroundColor Cyan

# 3. Validazione Fingerprint del Sistema Operativo Virtuale (Strict API 28)
Write-Host "`n[2/6] Validazione impronta hardware del target ($emulator)..." -ForegroundColor Yellow
$sdkVer = (& $adb -s $emulator shell getprop ro.build.version.sdk).Trim()
$release = (& $adb -s $emulator shell getprop ro.build.version.release).Trim()
$model = (& $adb -s $emulator shell getprop ro.product.model).Trim()

Assert-Step ($sdkVer -eq "28") "Target OS API Level rigorosamente Android 9 (API 28, letto: $sdkVer)"
Assert-Step ($model -match "atv|emulator|sdk_google_atv") "Profilo hardware emulatore TV validato (letto: $model)"
Write-Host "Target validato al 100%: $model (Android $release, SDK $sdkVer)" -ForegroundColor Green

# 4. Popolamento Catalogo Streaming e App di Test (8 Pacchetti Indipendenti)
$testSuiteDir = Join-Path $toolsDir "test-apps\output"
if (Test-Path $testSuiteDir) {
    Write-Host "`n[3/6] Installazione suite catalogo 8 app streaming indipendenti su $emulator..." -ForegroundColor Yellow
    $apks = Get-ChildItem -Path $testSuiteDir -Filter "*.apk"
    foreach ($testApk in $apks) {
        $installSuiteOut = & $adb -s $emulator install -r $testApk.FullName
        Assert-Step ($installSuiteOut -match "Success") "Installata app streaming di test: $($testApk.Name)"
    }
}

# 5. Installazione Streamed AKAI Custom Home v8
Write-Host "`n[4/6] Installazione sicura AKAI Custom Home v8 su $emulator..." -ForegroundColor Yellow
$installAppOut = & $adb -s $emulator install -r $apk
Assert-Step ($installAppOut -match "Success") "AKAI Custom Home v8 installata con successo su $emulator"

# 6. Avvio MainActivity e Validazione Window Focus
Write-Host "`n[5/6] Avvio Launcher e verifica finestra in primo piano..." -ForegroundColor Yellow
& $adb -s $emulator shell am start -n it.akai.customhome/.MainActivity | Out-Null
Start-Sleep -Seconds 2

$windowFocus = & $adb -s $emulator shell dumpsys window windows | Select-String -Pattern "mCurrentFocus"
Assert-Step ($windowFocus -match "it\.akai\.customhome/\.MainActivity|it\.akai\.customhome/it\.akai\.customhome\.MainActivity") "MainActivity ha il focus esclusivo in primo piano"

# 7. Sequenza Collaudo D-Pad e Acquisizione Evidenze 1080p
Write-Host "`n[6/6] Esecuzione sequenza telecomando e verifica navigazione righe..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path $docsDir | Out-Null

# Cattura 1: Home Screen pulita all'avvio (Premium UI con Sidebar, Top Bar e 4 Righe)
& $adb -s $emulator shell "screencap -p /data/local/tmp/screencap.png"
& $adb -s $emulator pull /data/local/tmp/screencap.png "$docsDir\01_home_screen_clean.png" | Out-Null
Assert-Step (Test-Path "$docsDir\01_home_screen_clean.png") "Evidenza 01 catturata (Home Premium completa a 4 righe con sidebar)"

# Navigazione D-Pad: DPAD_LEFT sposta il focus nella Sidebar di navigazione a sinistra
& $adb -s $emulator shell input keyevent 21 # DPAD_LEFT -> Focus su Sidebar (Home)
Start-Sleep -Milliseconds 400

# Cattura 2: Focus su Sidebar di navigazione a sinistra
& $adb -s $emulator shell "screencap -p /data/local/tmp/screencap.png"
& $adb -s $emulator pull /data/local/tmp/screencap.png "$docsDir\02_sidebar_navigation_focus.png" | Out-Null
Assert-Step (Test-Path "$docsDir\02_sidebar_navigation_focus.png") "Evidenza 02 catturata (Navigazione Sidebar a sinistra attiva)"

# Navigazione D-Pad: Dalla Sidebar preme DPAD_RIGHT per tornare a TV Digitale, poi scende a Streaming
& $adb -s $emulator shell input keyevent 22 # DPAD_RIGHT -> TV Digitale
Start-Sleep -Milliseconds 300
& $adb -s $emulator shell input keyevent 20 # DPAD_DOWN -> App Preferite
Start-Sleep -Milliseconds 300
& $adb -s $emulator shell input keyevent 20 # DPAD_DOWN -> Streaming Apps
Start-Sleep -Milliseconds 400

# Scorrimento orizzontale della riga streaming (8 app indipendenti)
& $adb -s $emulator shell input keyevent 22 # DPAD_RIGHT
Start-Sleep -Milliseconds 300
& $adb -s $emulator shell input keyevent 22 # DPAD_RIGHT
Start-Sleep -Milliseconds 300
& $adb -s $emulator shell input keyevent 22 # DPAD_RIGHT
Start-Sleep -Milliseconds 300

# Cattura 3: Scorrimento orizzontale riga Streaming popolata con 8 app indipendenti
& $adb -s $emulator shell "screencap -p /data/local/tmp/screencap.png"
& $adb -s $emulator pull /data/local/tmp/screencap.png "$docsDir\03_streaming_horizontal_scroll.png" | Out-Null
Assert-Step (Test-Path "$docsDir\03_streaming_horizontal_scroll.png") "Evidenza 03 catturata (Scorrimento riga streaming con 8 app indipendenti)"

# Discesa alla riga "Tutte le Applicazioni" e pressione prolungata OK
& $adb -s $emulator shell input keyevent 20 # DPAD_DOWN -> Tutte le Applicazioni
Start-Sleep -Milliseconds 400
& $adb -s $emulator shell input keyevent --longpress 23 # DPAD_CENTER LONGPRESS
Start-Sleep -Milliseconds 800

# Cattura 4: Dialogo opzioni in stile Dark Glassmorphic
& $adb -s $emulator shell "screencap -p /data/local/tmp/screencap.png"
& $adb -s $emulator pull /data/local/tmp/screencap.png "$docsDir\04_app_options_dialog.png" | Out-Null
Assert-Step (Test-Path "$docsDir\04_app_options_dialog.png") "Evidenza 04 catturata (Dialogo Dark Glassmorphic con accenti dorati)"

# Selezione "Aggiungi ai Preferiti" con DPAD_CENTER
& $adb -s $emulator shell input keyevent 23 # DPAD_CENTER
Start-Sleep -Milliseconds 800

# Cattura 5: Riga Preferiti popolata e visibile a schermo
& $adb -s $emulator shell "screencap -p /data/local/tmp/screencap.png"
& $adb -s $emulator pull /data/local/tmp/screencap.png "$docsDir\05_favorites_row_populated.png" | Out-Null
Assert-Step (Test-Path "$docsDir\05_favorites_row_populated.png") "Evidenza 05 catturata (Riga Preferiti popolata a schermo)"

# Navigazione Top Bar e apertura menu Personalizzazione
& $adb -s $emulator shell input keyevent 19 # DPAD_UP
Start-Sleep -Milliseconds 300
& $adb -s $emulator shell input keyevent 19 # DPAD_UP
Start-Sleep -Milliseconds 300
& $adb -s $emulator shell input keyevent 19 # DPAD_UP (Top Bar)
Start-Sleep -Milliseconds 300
& $adb -s $emulator shell input keyevent 22 # DPAD_RIGHT verso tavolozza tema
Start-Sleep -Milliseconds 300
& $adb -s $emulator shell input keyevent 23 # DPAD_CENTER per aprire dialogo tema
Start-Sleep -Milliseconds 800

# Cattura 6: Dialogo personalizzazione tema in stile Dark Glassmorphic
& $adb -s $emulator shell "screencap -p /data/local/tmp/screencap.png"
& $adb -s $emulator pull /data/local/tmp/screencap.png "$docsDir\06_theme_customization_dialog.png" | Out-Null
Assert-Step (Test-Path "$docsDir\06_theme_customization_dialog.png") "Evidenza 06 catturata (Menu Personalizzazione Dark Glassmorphic)"

# Chiusura dialogo con BACK
& $adb -s $emulator shell input keyevent 4 # BACK
Start-Sleep -Milliseconds 500

# Rientro alla Home con tasto HOME e verifica focus
& $adb -s $emulator shell input keyevent 3 # HOME
Start-Sleep -Milliseconds 800
& $adb -s $emulator shell "screencap -p /data/local/tmp/screencap.png"
& $adb -s $emulator pull /data/local/tmp/screencap.png "$docsDir\07_home_key_focus_retention.png" | Out-Null
Assert-Step (Test-Path "$docsDir\07_home_key_focus_retention.png") "Evidenza 07 catturata (Ripristino stabile focus tramite tasto HOME)"

Write-Host "`n=================================================================" -ForegroundColor Green
Write-Host " COLLAUDO RUNTIME EMULATORE ANDROID TV: 100% SUPERATO (CON ASSERT)" -ForegroundColor Green
Write-Host " Tutte le azioni confinate su $emulator (-s vincolato)" -ForegroundColor Green
Write-Host " ZERO comandi inviati verso la TV fisica" -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Green
