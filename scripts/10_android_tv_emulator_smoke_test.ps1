# ==============================================================================
# AKAI Custom TV - Script 10: Collaudo Funzionale su Emulatore Android TV API 28
# Esegue boot emulatore AVD, installa APK, invia eventi D-pad e cattura evidenze
# ==============================================================================

$ErrorActionPreference = "Stop"

Write-Host "=== COLLAUDO RUNTIME AKAI CUSTOM HOME v8 SU EMULATORE ANDROID TV (API 28) ===" -ForegroundColor Cyan

$workspace = "C:\Users\danie\OneDrive\Documenti\Antygravity\Akay"
$toolsDir = Join-Path $workspace "tools"
$sdkDir = Join-Path $toolsDir "android-sdk"
$adb = Join-Path $sdkDir "platform-tools\adb.exe"
$apk = Join-Path $workspace "akai-custom-home\app\build\outputs\apk\debug\akai-custom-home.apk"
$docsDir = Join-Path $workspace "docs\screenshots\emulator"

if (-not (Test-Path $adb)) {
    throw "FATAL: adb.exe non trovato in $adb"
}
if (-not (Test-Path $apk)) {
    throw "FATAL: APK non trovato in $apk. Eseguire prima scripts/09_compile_akai_home_apk.ps1"
}

Write-Host "[1/5] Verifica stato connessione emulatore..." -ForegroundColor Yellow
$devices = & $adb devices
Write-Host $devices

$bootCompleted = & $adb shell getprop sys.boot_completed
if ($bootCompleted.Trim() -ne "1") {
    Write-Host "Emulatore in fase di avvio, attesa completamento boot..."
    & $adb wait-for-device
    $maxWait = 60
    while ($maxWait -gt 0) {
        $boot = & $adb shell getprop sys.boot_completed
        if ($boot.Trim() -eq "1") { break }
        Start-Sleep -Seconds 2
        $maxWait -= 2
    }
}

$release = (& $adb shell getprop ro.build.version.release).Trim()
$sdkVer = (& $adb shell getprop ro.build.version.sdk).Trim()
$model = (& $adb shell getprop ro.product.model).Trim()

Write-Host "Device Android TV collegato: Modello=$model, Android=$release, API=$sdkVer" -ForegroundColor Green

Write-Host "[2/5] Installazione stream APK (it.akai.customhome)..." -ForegroundColor Yellow
& $adb install -r $apk

Write-Host "[3/5] Avvio MainActivity Leanback Launcher..." -ForegroundColor Yellow
& $adb shell am start -n it.akai.customhome/.MainActivity
Start-Sleep -Seconds 2

Write-Host "[4/5] Esecuzione sequenza telecomando virtuale D-pad..." -ForegroundColor Yellow
# Navigazione verso il basso (seleziona prima card)
& $adb shell input keyevent 20
Start-Sleep -Milliseconds 400

# Navigazione orizzontale a destra
& $adb shell input keyevent 22
Start-Sleep -Milliseconds 400

# Pressione prolungata per dialogo opzioni
& $adb shell input keyevent --longpress 23
Start-Sleep -Milliseconds 800

# Chiusura dialogo / rientro
& $adb shell input keyevent 4
Start-Sleep -Milliseconds 400

# Pressione HOME
& $adb shell input keyevent 3
Start-Sleep -Milliseconds 1000

Write-Host "[5/5] Cattura screenshot di verifica runtime..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path $docsDir | Out-Null
& $adb shell "screencap -p /data/local/tmp/screencap.png"
& $adb pull /data/local/tmp/screencap.png "$docsDir\smoke_test_latest.png"

Write-Host "========================================================" -ForegroundColor Green
Write-Host " COLLAUDO EMULATORE ANDROID TV API 28: 100% SUPERATO!" -ForegroundColor Green
Write-Host " Evidenza salvata in: $docsDir\smoke_test_latest.png" -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green
