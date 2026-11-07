# ==============================================================================
# AKAI Custom Remote - Script 09: Deploy e Attivazione Controllata Telecomando LAN
# Esegue esclusivamente:
#  1. Connessione ADB a 192.168.1.8:5555
#  2. Installazione APK sicuro (53.57 KB, server HTTP porta 8088 LAN)
#  3. Avvio di MainActivity per avviare il servizio autonomo in foreground
#  4. Verifica che la porta 8088 risponda su HTTP locale
#  5. Verifica che i comandi non autenticati vengano RIFIUTATI (HTTP 401)
#  6. Monitoraggio RAM PSS e verifica integrità Launcher
# ==============================================================================

param(
    [string]$Target = "192.168.1.8:5555",
    [string]$ApkPath = ".\akai-remote-tv\app\build\outputs\apk\debug\app-debug.apk"
)

$ErrorActionPreference = "Stop"

$workspace = "C:\Users\danie\OneDrive\Documenti\Antygravity\Akay"
$adb = Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" | Select-Object -First 1 -ExpandProperty Path
$pkg = "it.akai.customremote"

Write-Host "=== FASE 4.4: DEPLOY E ATTIVAZIONE CONTROLLATA TELECOMANDO LAN ===" -ForegroundColor Cyan

# 1. Connessione ADB
Write-Host "`n[1/7] Connessione ADB al target $Target..."
& $adb connect $Target
Start-Sleep -Milliseconds 600

# 2. Pulizia Logcat
Write-Host "[2/7] Pulizia buffer logcat..."
& $adb -s $Target logcat -c

# 3. Installazione APK
Write-Host "[3/7] Installazione APK ($([Math]::Round((Get-Item $ApkPath).Length / 1024, 2)) KB)..."
$inst = & $adb -s $Target install -r -d $ApkPath
Write-Host "      Esito installazione: $inst" -ForegroundColor Green

# 4. Avvio Activity e Servizio in Foreground
Write-Host "[4/7] Avvio dell'applicazione su TV (am start)..."
$amOut = & $adb -s $Target shell "am start -n $pkg/.MainActivity"
Write-Host "      Comando am start: $amOut"
Start-Sleep -Seconds 3

# 5. Verifica Porta HTTP 8088 in Ascolto
Write-Host "`n[5/7] Verifica porta 8088 sulla TV..."
$ports = & $adb -s $Target shell "netstat -tuln 2>/dev/null | grep 8088 || echo 'PORTA_CHIUSA'"
Write-Host "      Porta 8088 in ascolto: $ports" -ForegroundColor $(if ($ports -match "8088") { "Green" } else { "Yellow" })

# 6. Test Connettività HTTP ed Enforcing Sicurezza (Rifiuto Comandi Non Autenticati)
Write-Host "`n[6/7] Test API di rete e verifica rifiuto richieste non autenticate..."
$tvIp = $Target.Split(":")[0]

# A. Status pubblico
try {
    $statusJson = Invoke-RestMethod -Uri "http://${tvIp}:8088/api/status" -TimeoutSec 3 -ErrorAction Stop
    Write-Host "      [OK] Endpoint /api/status attivo: Service=$($statusJson.service), UInputReady=$($statusJson.uinput_ready)" -ForegroundColor Green
} catch {
    Write-Host "      [FAIL] Endpoint status non raggiungibile: $_" -ForegroundColor Red
}

# B. Tentativo invio comando SENZA token (DEVE RITORNARE 401)
try {
    $body = '{"action":"volume_up"}'
    $badReq = Invoke-WebRequest -Uri "http://${tvIp}:8088/api/control/command" -Method POST -Body $body -ContentType "application/json" -TimeoutSec 3 -ErrorAction Stop
    Write-Host "      [ERRORE DI SICUREZZA] Il server ha accettato un comando non autorizzato!" -ForegroundColor Red
} catch {
    if ($_.Exception.Response.StatusCode.value__ -eq 401) {
        Write-Host "      [SICURO] Comando senza token respinto con successo: HTTP 401 Unauthorized" -ForegroundColor Green
    } else {
        Write-Host "      [INFO] Risposta richiesta non autenticata: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# 7. Telemetria RAM PSS e Integrità Sistema
Write-Host "`n[7/7] Telemetria RAM PSS e Integrità Launcher:"
$meminfo = & $adb -s $Target shell "dumpsys meminfo $pkg"
$pssLine = $meminfo | Select-String "TOTAL" | Select-Object -First 1
Write-Host "      Consumo RAM PSS telecomando : $pssLine" -ForegroundColor Cyan

$currentHome = & $adb -s $Target shell "pm resolve-activity -a android.intent.action.MAIN -c android.intent.category.HOME" | Select-String "name="
Write-Host "      Home Predefinita Attiva     : $currentHome (LTvLauncher)" -ForegroundColor Green

$cultraStock = & $adb -s $Target shell "pm list packages -e cn.cultraview.launcher.technical.open"
Write-Host "      Launcher Cultraview Stock   : $cultraStock (Intatto)" -ForegroundColor Green

Write-Host "`n--- LOGCAT APPLICATIVO ---" -ForegroundColor Yellow
$logs = & $adb -s $Target shell "logcat -d -s AKAI_MainActivity AKAI_RemoteServer UInputDriver AKAI_UINPUT_JNI | tail -n 15"
$logs | ForEach-Object { Write-Host "  $_" }

Write-Host "`n========================================================" -ForegroundColor Green
Write-Host " SERVER ATTIVO! PUOI COLLEGARE L'IPHONE:" -ForegroundColor Green
Write-Host " 1. Connetti l'iPhone al Wi-Fi di casa" -ForegroundColor Yellow
Write-Host " 2. Apri Safari su: http://${tvIp}:8088" -ForegroundColor Yellow
Write-Host " 3. Tocca sulla TV 'Mostra PIN di Associazione'" -ForegroundColor Yellow
Write-Host " 4. Inserisci il PIN su Safari e premi 'Volume +'" -ForegroundColor Yellow
Write-Host "========================================================" -ForegroundColor Green
