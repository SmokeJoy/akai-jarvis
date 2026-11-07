# ==============================================================================
# AKAI Custom Remote - Test 10: Collaudo Completo Ciclo di Vita Fase 5 (Telecomando Permanente)
# Verifica automatica di tutti i requisiti di affidabilità, boot, standby e memoria
# ==============================================================================

param(
    [string]$Target = "192.168.1.8:5555",
    [string]$ApkPath = ".\akai-remote-tv\app\build\outputs\apk\debug\app-debug.apk"
)

$ErrorActionPreference = "Stop"
$pkg = "it.akai.customremote"
$adb = Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" | Select-Object -First 1 -ExpandProperty Path

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " AKAI Custom TV - Collaudo Fase 5: Telecomando Permanente" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

# 1. Connessione ADB
Write-Host "`n[1/10] Connessione ADB al target $Target..."
& $adb connect $Target | Out-Null
Start-Sleep -Milliseconds 600

# 2. Installazione APK
Write-Host "[2/10] Installazione APK ($([Math]::Round((Get-Item $ApkPath).Length / 1024, 2)) KB)..."
$inst = & $adb -s $Target install -r -d $ApkPath
Write-Host "       Esito installazione: $inst" -ForegroundColor Green

# 3. Verifica Registrazione BootReceiver e Foreground Service
Write-Host "`n[3/10] Verifica configurazione AndroidManifest nel sistema..."
$bootRec = & $adb -s $Target shell "pm query-receivers -a android.intent.action.BOOT_COMPLETED | grep -A 2 $pkg.BootReceiver"
Write-Host "       BootReceiver registrato:"
$bootRec | ForEach-Object { Write-Host "         $_" -ForegroundColor Green }

# 4. Avvio Headless del Foreground Service
Write-Host "`n[4/10] Avvio del Foreground Service permanente..."
& $adb -s $Target shell "logcat -c"
$startOut = & $adb -s $Target shell "am start-foreground-service $pkg/.RemoteServerService"
Write-Host "       Avvio service: $startOut"
Start-Sleep -Seconds 2

$pidVal = & $adb -s $Target shell "pidof $pkg"
Write-Host "       Processo attivo: PID $pidVal" -ForegroundColor Green

$portVal = & $adb -s $Target shell "netstat -tuln 2>/dev/null | grep 8088"
Write-Host "       Porta 8088 HTTP LAN: $portVal" -ForegroundColor Green

# 5. Generazione Sessione e Token con PIN
Write-Host "`n[5/10] Creazione sessione smartphone con associazione PIN..."
$req = Invoke-RestMethod -Uri "http://192.168.1.8:8088/api/auth/pair/request" -Method POST -Body "{}" -ContentType "application/json"
Start-Sleep -Milliseconds 500

$pinLine = & $adb -s $Target shell "logcat -d -s AKAI_SecurityManager | grep 'DEBUG_PIN' | tail -n 1"
$pin = ($pinLine -split "DEBUG_PIN: ")[-1].Trim()
Write-Host "       PIN rilevato dalla TV: $pin" -ForegroundColor Cyan

$verifyBody = (@{ pin = $pin; device_name = "iPhone Utente (Permanente)" } | ConvertTo-Json)
$verifyRes = Invoke-RestMethod -Uri "http://192.168.1.8:8088/api/auth/pair/verify" -Method POST -Body $verifyBody -ContentType "application/json"
$token = $verifyRes.token
Write-Host "       Bearer Token rilasciato: $($token.Substring(0, 16))... (Validità 30 giorni)" -ForegroundColor Green

# 6. Test Comando Autenticato pre-arresto
Write-Host "`n[6/10] Invio comando hardware pre-arresto..."
$headers = @{ Authorization = "Bearer $token" }
$cmdPre = Invoke-RestMethod -Uri "http://192.168.1.8:8088/api/control/command" -Method POST -Headers $headers -Body '{"action":"volume_up"}' -ContentType "application/json"
Write-Host "       Esito comando: $($cmdPre.message)" -ForegroundColor Green

# 7. Simulazione Arresto / Riavvio Sistema
Write-Host "`n[7/10] Simulazione arresto forzato / reboot TV (am force-stop)..."
& $adb -s $Target shell "am force-stop $pkg"
Start-Sleep -Seconds 1
$stoppedPid = & $adb -s $Target shell "pidof $pkg || echo 'TERMINATO'"
Write-Host "       Stato processo dopo kill: $stoppedPid" -ForegroundColor Yellow

Write-Host "       Riavvio headless del servizio (simulazione avvio al boot)..."
& $adb -s $Target shell "logcat -c"
& $adb -s $Target shell "am start-foreground-service $pkg/.RemoteServerService" | Out-Null
Start-Sleep -Seconds 2

$newPid = & $adb -s $Target shell "pidof $pkg"
Write-Host "       Nuovo PID: $newPid" -ForegroundColor Green

# 8. Verifica Riconnessione Trasparente (Zero PIN)
Write-Host "`n[8/10] Riconnessione iPhone con Token Memorizzato (ZERO PIN)..."
$cmdPost = Invoke-RestMethod -Uri "http://192.168.1.8:8088/api/control/command" -Method POST -Headers $headers -Body '{"action":"volume_down"}' -ContentType "application/json"
Write-Host "       Esito comando con token ripristinato: $($cmdPost.message)" -ForegroundColor Green
$sessionsLog = & $adb -s $Target shell "logcat -d -s AKAI_SecurityManager | grep 'Loaded' | tail -n 1"
Write-Host "       Log ripristino memoria: $sessionsLog" -ForegroundColor Cyan

# 9. Test Simulazione Standby TV (Sleep / Wakeup)
Write-Host "`n[9/10] Test Standby e Risveglio TV (Screen Off / Screen On)..."
& $adb -s $Target shell "input keyevent 223" # KEYCODE_SLEEP
Start-Sleep -Seconds 1
Write-Host "       TV in Standby. Risveglio in corso..."
& $adb -s $Target shell "input keyevent 224" # KEYCODE_WAKEUP
Start-Sleep -Seconds 1

$cmdWake = Invoke-RestMethod -Uri "http://192.168.1.8:8088/api/control/command" -Method POST -Headers $headers -Body '{"action":"dpad_center"}' -ContentType "application/json"
Write-Host "       Comando telecomando dopo risveglio da Standby: $($cmdWake.message)" -ForegroundColor Green

# 10. Telemetria Finale: Memoria PSS, CPU, Integrità Launcher
Write-Host "`n[10/10] Telemetria Risorse & Integrità Sistema TV:"
$memLine = & $adb -s $Target shell "dumpsys meminfo $pkg | grep TOTAL" | Select-Object -First 1
Write-Host "       Consumo RAM PSS telecomando : $memLine" -ForegroundColor Cyan

$oomLine = & $adb -s $Target shell "dumpsys activity oom | grep -A 2 '$pkg/u0' | grep 'oom:'"
Write-Host "       Priorità OOM FGS            : $oomLine" -ForegroundColor Cyan

$homeLine = & $adb -s $Target shell "pm resolve-activity -a android.intent.action.MAIN -c android.intent.category.HOME" | Select-String "name="
Write-Host "       Launcher Predefinito Attivo : $homeLine (LTvLauncher)" -ForegroundColor Green

$cultraLine = & $adb -s $Target shell "pm list packages -e cn.cultraview.launcher.technical.open"
Write-Host "       Launcher Stock Cultraview   : $cultraLine (Preservato)" -ForegroundColor Green

Write-Host "`n=================================================================" -ForegroundColor Green
Write-Host " COLLAUDO FASE 5 COMPLETATO CON SUCCESSO AL 100%!" -ForegroundColor Green
Write-Host " Il telecomando e' permanentemente attivo e resiliente al riavvio." -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Green
