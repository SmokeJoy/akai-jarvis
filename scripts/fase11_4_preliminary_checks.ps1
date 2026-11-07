$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
$aapt = "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay\tools\android-sdk\build-tools\28.0.3\aapt.exe"
$jdk = "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay\tools\jdk-17\bin\keytool.exe"

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " FASE 11.4: VERIFICHE PRELIMINARI COMPLETE" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# 1. Verifiche 4.2.11 Target Splits
Write-Host "`n[1/4] Verifiche 4.2.11 Target Splits (scratch\v4_androidtv_target_splits)..." -ForegroundColor Yellow
$v4Files = @("base.apk", "split_config.armeabi_v7a.apk", "split_config.xhdpi.apk", "split_config.it.apk")
foreach ($f in $v4Files) {
    $p = "scratch\v4_androidtv_target_splits\$f"
    if (Test-Path $p) {
        $len = (Get-Item $p).Length
        $hash = (Get-FileHash $p -Algorithm SHA256).Hash
        $cert = & $jdk -printcert -jarfile $p
        $sha256Cert = ($cert | Select-String "SHA256:").Line.Trim()
        $badging = & $aapt dump badging $p
        $pkgLine = ($badging | Select-String "package:").Line
        Write-Host "  -> $f ($len byte)" -ForegroundColor Green
        Write-Host "     SHA-256 File: $hash"
        Write-Host "     $pkgLine"
        Write-Host "     $sha256Cert"
    } else {
        Write-Host "  -> ERRORE: $f mancante!" -ForegroundColor Red
    }
}

# 2. Verifiche 5.0.1 Backup Splits
Write-Host "`n[2/4] Verifiche 5.0.1 Backup Splits (scratch\backup_v5_splits)..." -ForegroundColor Yellow
$v5Files = @("base.apk", "split_config.armeabi_v7a.apk", "split_config.hdpi.apk", "split_config.it.apk")
foreach ($f in $v5Files) {
    $p = "scratch\backup_v5_splits\$f"
    if (Test-Path $p) {
        $len = (Get-Item $p).Length
        $hash = (Get-FileHash $p -Algorithm SHA256).Hash
        $cert = & $jdk -printcert -jarfile $p
        $sha256Cert = ($cert | Select-String "SHA256:").Line.Trim()
        Write-Host "  -> $f ($len byte)" -ForegroundColor Green
        Write-Host "     SHA-256 File: $hash"
        Write-Host "     $sha256Cert"
    } else {
        Write-Host "  -> ERRORE: $f mancante!" -ForegroundColor Red
    }
}

# 3. Verifica Flag Debuggable
Write-Host "`n[3/4] Controllo Flag 'debuggable' su 5.0.1 e 4.2.11..." -ForegroundColor Yellow
$debug5 = & $aapt dump xmltree scratch\backup_v5_splits\base.apk AndroidManifest.xml | Select-String -Pattern "android:debuggable"
Write-Host "  -> Debuggable v5.0.1: $(if ($debug5) { $debug5.Line.Trim() } else { 'NON PRESENTE (debuggable=false / produzione)' })" -ForegroundColor $(if ($debug5) { "Magenta" } else { "DarkYellow" })

$debug4 = & $aapt dump xmltree scratch\v4_androidtv_target_splits\base.apk AndroidManifest.xml | Select-String -Pattern "android:debuggable"
Write-Host "  -> Debuggable v4.2.11: $(if ($debug4) { $debug4.Line.Trim() } else { 'NON PRESENTE (debuggable=false / produzione)' })" -ForegroundColor $(if ($debug4) { "Magenta" } else { "DarkYellow" })

# 4. Verifica Connettività TV e Stato Attuale RaiPlay
Write-Host "`n[4/4] Verifica Connettività ADB e Stato TV..." -ForegroundColor Yellow
& $adb connect 192.168.1.8:5555 | Out-Null
$state = & $adb -s 192.168.1.8:5555 get-state
Write-Host "  -> ADB Device State: $state" -ForegroundColor Green
$installedVer = & $adb -s 192.168.1.8:5555 shell "dumpsys package it.rainet.androidtv | grep -E 'versionCode|versionName'"
Write-Host "  -> Versione attualmente installata su TV:" -ForegroundColor Cyan
Write-Host "     $($installedVer -join ' | ')" -ForegroundColor White
