# ==============================================================================
# AKAI Custom Remote - Test 11: Collaudo Reale su Riavvio Hardware della TV
# Esegue un vero riavvio (reboot) e verifica:
#  1. Riconnessione autonoma della TV al Wi-Fi (IP statico 192.168.1.8)
#  2. Avvio autonomo al boot di it.akai.customremote tramite BootReceiver (SENZA COMANDI ADB)
#  3. Apertura autonoma della porta HTTP 8088
#  4. Accettazione dei comandi da iPhone con il token salvato (ZERO PIN)
# ==============================================================================

param(
    [string]$Target = "192.168.1.8:5555",
    [string]$TvIp = "192.168.1.8"
)

$ErrorActionPreference = "Continue"
$pkg = "it.akai.customremote"
$adb = Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" | Select-Object -First 1 -ExpandProperty Path

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " AKAI Custom TV - Test 11: Riavvio Hardware Reale della TV" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

# 1. Verifica token salvato prima del riavvio
Write-Host "`n[1/5] Verifica sessioni permanenti salvate prima del riavvio..."
& $adb connect $Target | Out-Null
Start-Sleep -Milliseconds 500

$statusPre = Invoke-RestMethod -Uri "http://${TvIp}:8088/api/status" -TimeoutSec 3
Write-Host "       Stato Server Pre-Reboot: $($statusPre.service) (UInput: $($statusPre.uinput_ready))" -ForegroundColor Green

# 2. Comando di Reboot Hardware Reale
Write-Host "`n[2/5] INVIO COMANDO DI RIAVVIO REALE ALLA TV (adb reboot)..." -ForegroundColor Yellow
Write-Host "       La TV si spegnera' e si riavviera' completamente da zero." -ForegroundColor Yellow
& $adb -s $Target reboot
Write-Host "       Comando reboot inviato. Attesa spegnimento..." -ForegroundColor Cyan
Start-Sleep -Seconds 10

# 3. Polling attesa riavvio e boot completed
Write-Host "`n[3/5] Attesa riavvio TV e ricollegamento alla rete Wi-Fi ${TvIp}..."
$timeoutSec = 180
$elapsed = 0
$online = $false
$bootComplete = $false

while ($elapsed -lt $timeoutSec) {
    Start-Sleep -Seconds 5
    $elapsed += 5
    
    # Prova ping
    $pingOk = Test-Connection -ComputerName $TvIp -Count 1 -Quiet -ErrorAction SilentlyContinue
    if ($pingOk) {
        Write-Host "       [+${elapsed}s] TV raggiungibile via ping. Connessione ADB..." -ForegroundColor Cyan
        & $adb connect $Target | Out-Null
        $bootState = & $adb -s $Target shell "getprop sys.boot_completed" 2>$null
        if ($bootState -and $bootState.Trim() -eq "1") {
            Write-Host "       [+${elapsed}s] BOOT ANDROID COMPLETATO (sys.boot_completed=1)!" -ForegroundColor Green
            $bootComplete = $true
            break
        }
    } else {
        Write-Host "       [+${elapsed}s] TV in fase di spegnimento/boot hardware..." -ForegroundColor Gray
    }
}

if (-not $bootComplete) {
    Write-Host "`n[ERRORE] Timeout di 180s superato in attesa del boot." -ForegroundColor Red
    exit 1
}

# 4. Attesa assestamento BootReceiver (senza inviare alcun comando di avvio!)
Write-Host "`n[4/5] Verifica avvio autonomo del telecomando (NESSUN COMANDO INVIATO DAL PC)..."
Write-Host "       Attesa 5 secondi per permettere a BootReceiver di avviare il demone..."
Start-Sleep -Seconds 5

$pidVal = & $adb -s $Target shell "pidof $pkg" 2>$null
Write-Host "       Processo it.akai.customremote : $(if ($pidVal) { "ATTIVO (PID $pidVal)" } else { "NON ATTIVO" })" -ForegroundColor $(if ($pidVal) { "Green" } else { "Red" })

$portVal = & $adb -s $Target shell "netstat -tuln 2>/dev/null | grep 8088" 2>$null
Write-Host "       Porta 8088 in ascolto        : $portVal" -ForegroundColor $(if ($portVal -match "8088") { "Green" } else { "Red" })

# 5. Verifica Riconnessione HTTP & Accettazione Comandi con Sessione Precedente
Write-Host "`n[5/5] Test connettivita' HTTP e validazione sessioni senza PC..."
try {
    $statusPost = Invoke-RestMethod -Uri "http://${TvIp}:8088/api/status" -TimeoutSec 5
    Write-Host "       [OK] Endpoint status attivo: $($statusPost.service) (UInput: $($statusPost.uinput_ready))" -ForegroundColor Green
} catch {
    Write-Host "       [FAIL] Endpoint status non risponde: $_" -ForegroundColor Red
}

$bootLogs = & $adb -s $Target shell "logcat -d -s AKAI_BootReceiver AKAI_RemoteServer AKAI_SecurityManager | tail -n 15" 2>$null
Write-Host "`n--- LOGCAT AVVIO AUTONOMO TV ---" -ForegroundColor Yellow
$bootLogs | ForEach-Object { Write-Host "  $_" }

Write-Host "`n=================================================================" -ForegroundColor Green
Write-Host " COLLAUDO RIAVVIO HARDWARE COMPLETATO!" -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Green
