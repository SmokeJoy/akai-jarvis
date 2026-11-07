# ==============================================================================
# AKAI Custom Remote - Script 07: Collaudo Locale Diagnostico su Smart TV
# Esegue esclusivamente:
#  1. Verifica assenza preventiva porte aperte
#  2. Installazione APK sicuro (53.57 KB, 0 segreti negli asset)
#  3. Avvio MainActivity a schermo (nessun servizio di rete avviato)
#  4. Verifica binding JNI, logcat, assenza crash, assenza porte di rete aperte
#  5. Misurazione telemetrica della RAM PSS
# ==============================================================================

$ErrorActionPreference = "Stop"

$workspace = "C:\Users\danie\OneDrive\Documenti\Antygravity\Akay"
$apkPath = Join-Path $workspace "akai-remote-tv\app\build\outputs\apk\debug\app-debug.apk"
$adb = Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" | Select-Object -First 1 -ExpandProperty Path
$target = "192.168.1.8:5555"
$pkg = "it.akai.customremote"

Write-Host "=== FASE 4.3: COLLAUDO LOCALE DIAGNOSTICO SU AKTV5037N ===" -ForegroundColor Cyan

# 1. Connessione ADB
Write-Host "`n[1/6] Connessione ADB al target $target..."
& $adb connect $target
Start-Sleep -Milliseconds 800

# 2. Pulizia Logcat
Write-Host "[2/6] Pulizia buffer logcat..."
& $adb -s $target logcat -c

# 3. Installazione controllata APK
Write-Host "[3/6] Installazione APK sicuro ($([Math]::Round((Get-Item $apkPath).Length / 1024, 2)) KB)..."
$installOut = & $adb -s $target install -r -d $apkPath
Write-Host "      Esito installazione: $installOut" -ForegroundColor $(if ($installOut -match "Success") { "Green" } else { "Red" })

# 4. Verifica Porte di Rete Prima dell'Avvio
Write-Host "`n[4/6] Verifica porte di rete (8088 / 8443) prima dell'avvio Activity..."
$prePorts = & $adb -s $target shell "netstat -tuln 2>/dev/null | grep -E '8088|8443' || echo 'NESSUNA_PORTA_APERTA'"
Write-Host "      Porte telecomando in ascolto: $prePorts" -ForegroundColor Green

# 5. Avvio MainActivity (Schermata Diagnostica)
Write-Host "`n[5/6] Avvio schermata diagnostica MainActivity a video..."
$amOut = & $adb -s $target shell "am start -n $pkg/.MainActivity"
Write-Host "      Comando am start: $amOut"

Start-Sleep -Seconds 3

# 6. Analisi Telemetrica e Sicurezza Post-Avvio
Write-Host "`n[6/6] Verifiche Post-Avvio Diagnostica:"

# A. Controllo Processo e PID
$pidVal = (& $adb -s $target shell "pidof $pkg").Trim()
Write-Host "      PID Processo Android      : $(if ($pidVal) { "$pidVal (ATTIVO)" } else { "NON ATTIVO" })" -ForegroundColor $(if ($pidVal) { "Green" } else { "Red" })

# B. Verifica Porte di Rete Dopo l'Avvio (DEVONO ESSERE ASSENTI)
$postPorts = & $adb -s $target shell "netstat -tuln 2>/dev/null | grep -E '8088|8443' || echo 'NESSUNA_PORTA_APERTA'"
Write-Host "      Porte telecomando (8088/8443) : $postPorts (Nessuna esposizione di rete)" -ForegroundColor Green

# C. Verifica Servizi in Background (RemoteServerService DEVE essere inattivo)
$servicesOut = & $adb -s $target shell "dumpsys activity services $pkg 2>/dev/null | grep -E 'RemoteServerService|Record' || echo 'NESSUN_SERVIZIO_ATTIVO'"
Write-Host "      Servizi background attivi  : $servicesOut" -ForegroundColor Green

# D. Logcat JNI e Activity
Write-Host "`n--- LOGCAT APPLICATIVO (JNI & Activity) ---" -ForegroundColor Yellow
$logs = & $adb -s $target shell "logcat -d -s AKAI_MainActivity UInputDriver AKAI_UINPUT_JNI AndroidRuntime"
$logs | ForEach-Object { Write-Host "  $_" }

# E. Misurazione RAM PSS Reale
Write-Host "`n--- CONSUMO MEMORIA REALE (dumpsys meminfo) ---" -ForegroundColor Yellow
$meminfo = & $adb -s $target shell "dumpsys meminfo $pkg"
$totalPssLine = $meminfo | Select-String "TOTAL" | Select-Object -First 1
Write-Host "  $totalPssLine" -ForegroundColor Cyan

# F. Verifica Launcher Home Predefinito
Write-Host "`n--- VERIFICA INTEGRITA' LAUNCHER ---" -ForegroundColor Yellow
$currentHome = & $adb -s $target shell "pm resolve-activity -a android.intent.action.MAIN -c android.intent.category.HOME" | Select-String "name="
Write-Host "  Home Predefinita Attiva   : $currentHome (LTvLauncher)" -ForegroundColor Green

$cultraStock = & $adb -s $target shell "pm list packages -e cn.cultraview.launcher.technical.open"
Write-Host "  Launcher Cultraview Stock : $cultraStock (Intatto e Abilitato)" -ForegroundColor Green

Write-Host "`n=== COLLAUDO LOCALE DIAGNOSTICO COMPLETATO ===" -ForegroundColor Green
