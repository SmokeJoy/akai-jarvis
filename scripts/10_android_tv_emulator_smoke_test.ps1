# ==============================================================================
# AKAI Custom TV - Script 10: Collaudo Funzionale Sicuro su Emulatore Android TV
# Vincolo P0 di sicurezza: isolamento fail-closed assoluto verso emulator-xxxx
# Zero comandi senza -s <serial>; rifiuto categorico di IP, TV fisiche o ambiguità
# Verifica reale via UIAutomator XML + WindowManager mCurrentFocus dopo ogni step
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

function Get-UiDumpXml($serial) {
    $tmpRemote = "/data/local/tmp/ui_verify.xml"
    $lastErr = ""
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $cmdOut = (& $adb -s $serial shell "rm -f $tmpRemote && uiautomator dump --compressed $tmpRemote 2>&1") -join " "
        $raw = (& $adb -s $serial shell "cat $tmpRemote 2>/dev/null") -join "`n"
        if (-not [string]::IsNullOrWhiteSpace($raw) -and ($raw -match "<hierarchy")) {
            [xml]$xml = $raw
            return $xml
        }
        $lastErr = $cmdOut
        Start-Sleep -Milliseconds (400 + ($attempt * 250))
    }
    throw "UIAutomator dump fallito dopo 5 tentativi su $serial (ultimo output: $lastErr)"
}

function Parse-Bounds($boundsStr) {
    if ($boundsStr -match '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') {
        return @{
            X1 = [int]$Matches[1]
            Y1 = [int]$Matches[2]
            X2 = [int]$Matches[3]
            Y2 = [int]$Matches[4]
        }
    }
    return $null
}

function Get-UiNodeById($xml, [string]$resId) {
    $nodes = $xml.SelectNodes("//node[@resource-id='$resId']")
    if ($nodes.Count -gt 0) { return $nodes[0] }
    return $null
}

function Get-FocusedNode($xml) {
    $nodes = $xml.SelectNodes("//node[@focused='true']")
    if ($nodes.Count -gt 0) { return $nodes[0] }
    return $null
}

function Capture-Screen($serial, [string]$outPath) {
    & $adb -s $serial shell "screencap -p /data/local/tmp/screencap.png"
    & $adb -s $serial pull /data/local/tmp/screencap.png "$outPath" | Out-Null
    Assert-Step (Test-Path $outPath) "Screenshot salvato su disco: $(Split-Path -Leaf $outPath)"
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
Write-Host "`n[1/7] Analisi deterministica della lista dispositivi ADB..." -ForegroundColor Yellow
& $adb start-server | Out-Null
Start-Sleep -Seconds 2

$rawDevices = & $adb devices
$retryCount = 0
while ($rawDevices -match "offline" -and $retryCount -lt 6) {
    Start-Sleep -Seconds 1
    $rawDevices = & $adb devices
    $retryCount++
}
Write-Host $rawDevices

$emulator = Get-ValidatedEmulatorSerial $rawDevices
Write-Host "Emulatore autorizzato individuato: $emulator" -ForegroundColor Cyan

# 3. Validazione Fingerprint del Sistema Operativo Virtuale (Strict API 28)
Write-Host "`n[2/7] Validazione impronta hardware del target ($emulator)..." -ForegroundColor Yellow
$sdkVer = (& $adb -s $emulator shell getprop ro.build.version.sdk).Trim()
$release = (& $adb -s $emulator shell getprop ro.build.version.release).Trim()
$model = (& $adb -s $emulator shell getprop ro.product.model).Trim()

Assert-Step ($sdkVer -eq "28") "Target OS API Level rigorosamente Android 9 (API 28, letto: $sdkVer)"
Assert-Step ($model -match "atv|emulator|sdk_google_atv") "Profilo hardware emulatore TV validato (letto: $model)"
Write-Host "Target validato al 100%: $model (Android $release, SDK $sdkVer)" -ForegroundColor Green

# 4. Pulizia vecchi stub e installazione 8 Pacchetti Streaming con Banner/Icone reali
Write-Host "`n[3/7] Installazione suite catalogo 8 app streaming indipendenti su $emulator..." -ForegroundColor Yellow
$legacyPkgCheck = & $adb -s $emulator shell pm list packages test.tv.streaming
if ($legacyPkgCheck -match "test\.tv\.streaming") {
    & $adb -s $emulator uninstall test.tv.streaming | Out-Null
}

$testSuiteDir = Join-Path $toolsDir "test-apps\output"
Assert-Step (Test-Path $testSuiteDir) "Cartella output suite streaming presente"
$apks = Get-ChildItem -Path $testSuiteDir -Filter "*.apk"
Assert-Step ($apks.Count -eq 8) "Trovati esattamente 8 APK indipendenti con banner/icone"
foreach ($testApk in $apks) {
    $installSuiteOut = & $adb -s $emulator install -r $testApk.FullName
    Assert-Step ($installSuiteOut -match "Success") "Installata app streaming di test: $($testApk.Name)"
}

# 5. Installazione pulita AKAI Custom Home v8 + Configurazione Ruolo HOME nell'emulatore
Write-Host "`n[4/7] Installazione sicura e configurazione Default HOME in sandbox emulatore ($emulator)..." -ForegroundColor Yellow
$installAppOut = & $adb -s $emulator install -r $apk
Assert-Step ($installAppOut -match "Success") "AKAI Custom Home v8 installata con successo su $emulator"
& $adb -s $emulator shell pm clear it.akai.customhome | Out-Null

# Configurazione esclusiva sull'emulatore affinche' KEYCODE_HOME risolva su it.akai.customhome
# (In Google ATV9 AVD, com.google.android.tvlauncher ha mPriority=2; va disabilitato solo in sandbox AVD)
& $adb -s $emulator shell cmd package set-home-activity it.akai.customhome/.MainActivity | Out-Null
$resolvedHome = (& $adb -s $emulator shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME) -join "`n"
if (-not ($resolvedHome -match "it\.akai\.customhome/\.MainActivity")) {
    Write-Host "  Google TV Launcher (priority=2) intercetta HOME nell'AVD -> Disabilitazione isolata in sandbox emulatore..." -ForegroundColor Yellow
    & $adb -s $emulator shell pm disable-user --user 0 com.google.android.tvlauncher | Out-Null
    & $adb -s $emulator shell cmd package set-home-activity it.akai.customhome/.MainActivity | Out-Null
    $resolvedHome = (& $adb -s $emulator shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME) -join "`n"
}
Assert-Step ($resolvedHome -match "it\.akai\.customhome/\.MainActivity") "HOME RETURN GATE: Launcher predefinito sull'emulatore risolto a it.akai.customhome/.MainActivity"

# 6. Avvio Launcher e Verifica Visuale Header/Sezioni (Zero Clipping)
Write-Host "`n[5/7] Avvio MainActivity e audit pixel bounds 1920x1080..." -ForegroundColor Yellow
& $adb -s $emulator shell am start -W -n it.akai.customhome/.MainActivity | Out-Null
Start-Sleep -Seconds 2

$windowFocus = (& $adb -s $emulator shell dumpsys window windows | Select-String -Pattern "mCurrentFocus") -join "`n"
Assert-Step ($windowFocus -match "it\.akai\.customhome/(\.|it\.akai\.customhome\.)MainActivity") "MainActivity ha il focus esclusivo in primo piano ($windowFocus)"

$xml1 = Get-UiDumpXml $emulator
$brandVerNode = Get-UiNodeById $xml1 "it.akai.customhome:id/tv_brand_version"
$wifiNode = Get-UiNodeById $xml1 "it.akai.customhome:id/btn_home_wifi"
$clockNode = Get-UiNodeById $xml1 "it.akai.customhome:id/home_clock"
$menuSrcNode = Get-UiNodeById $xml1 "it.akai.customhome:id/btn_src_all"

Assert-Step ($null -ne $brandVerNode -and $brandVerNode.text -eq "CUSTOM HOME v8") "Header brand aggiornato esattamente a 'CUSTOM HOME v8'"
$bBrand = Parse-Bounds $brandVerNode.bounds
$bWifi = Parse-Bounds $wifiNode.bounds
$bClock = Parse-Bounds $clockNode.bounds
$bSrcAll = Parse-Bounds $menuSrcNode.bounds

Assert-Step ($bBrand.X2 -lt $bWifi.X1) "Header separato dal pulsante Wi-Fi ($($bBrand.X2) < $($bWifi.X1))"
Assert-Step ($clockNode.text -match "^\d{2}:\d{2}$") "Orologio digitale HH:mm completo senza troncamento AM/PM (letto: '$($clockNode.text)')"
Assert-Step ($bClock.X2 -le 1900) "Orologio visibile entro il margine 1920px (x2=$($bClock.X2))"
Assert-Step ($bSrcAll.X2 -le 1900) "Quinto ingresso 'Menu Ingressi' visibile senza tagli (x2=$($bSrcAll.X2))"

$rawXml1 = $xml1.OuterXml
Assert-Step (-not ($rawXml1 -match "System Tracing")) "Nessuna app tecnica 'System Tracing' presente nei preferiti/catalogo"
Assert-Step (-not ($rawXml1 -match 'text="AKAI Custom Home"')) "Il launcher non duplica se stesso in Tutte le Applicazioni"

New-Item -ItemType Directory -Force -Path $docsDir | Out-Null
Capture-Screen $emulator "$docsDir\01_home_screen_clean.png"

# 7. Collaudo Sequenza Telecomando D-Pad con Verifica UIAutomator ad Ogni Step
Write-Host "`n[6/7] Sequenza D-Pad e catture verificate da UIAutomator..." -ForegroundColor Yellow

# STEP 2: Navigazione verso Sidebar a sinistra (verifica focus reale su sidebar_nav_home)
& $adb -s $emulator shell input keyevent 21 # DPAD_LEFT -> Sidebar
Start-Sleep -Milliseconds 500
$xml2 = Get-UiDumpXml $emulator
$foc2 = Get-FocusedNode $xml2
Assert-Step ($null -ne $foc2 -and $foc2.'resource-id' -match "sidebar_nav_") "Focus reale acquisito dalla Sidebar (id: $($foc2.'resource-id'))"
Capture-Screen $emulator "$docsDir\02_sidebar_navigation_focus.png"

# STEP 3: Ritorno a griglia e scorrimento orizzontale nella riga Streaming & Cinema
& $adb -s $emulator shell input keyevent 22 # DPAD_RIGHT -> btn_src_dtv
Start-Sleep -Milliseconds 300
& $adb -s $emulator shell input keyevent 20 # DPAD_DOWN -> prima riga streaming (Favorites è ancora nascosta)
Start-Sleep -Milliseconds 400

# Muove a destra 4 volte per scorrere il carosello, poi 1 a sinistra su Netflix per evidenziare focus nitido non a filo bordo
for ($i = 0; $i -lt 4; $i++) {
    & $adb -s $emulator shell input keyevent 22 # DPAD_RIGHT
    Start-Sleep -Milliseconds 320
}
& $adb -s $emulator shell input keyevent 21 # DPAD_LEFT -> focus su Netflix con riga visibilmente scrollata
Start-Sleep -Milliseconds 400
$xml3 = Get-UiDumpXml $emulator
$foc3 = Get-FocusedNode $xml3
$scrollStreamNode = Get-UiNodeById $xml3 "it.akai.customhome:id/scroll_streaming"
Assert-Step ($null -ne $foc3 -and -not [string]::IsNullOrWhiteSpace($foc3.'content-desc') -and $foc3.'content-desc' -ne "Disney+") "Scorrimento orizzontale Streaming confermato (focus su '$($foc3.'content-desc')')"
Capture-Screen $emulator "$docsDir\03_streaming_horizontal_scroll.png"

# STEP 4: Pressione prolungata OK sulla card corrente (Netflix) -> Dialogo dark glass
& $adb -s $emulator shell input keyevent --longpress 23 # DPAD_CENTER LONGPRESS
Start-Sleep -Milliseconds 1200
$xml4 = Get-UiDumpXml $emulator
$rawXml4 = $xml4.OuterXml
$windowFocus4 = (& $adb -s $emulator shell dumpsys window windows | Select-String -Pattern "mCurrentFocus") -join "`n"
Assert-Step ($windowFocus4 -match "it\.akai\.customhome") "App NON avviata durante pressione prolungata (finestra ancora nel launcher)"
Assert-Step (($rawXml4 -match "Aggiungi ai Preferiti") -and ($rawXml4 -match "Informazioni Applicazione")) "Dialogo Dark Glass opzioni aperto realmente sul target '$($foc3.'content-desc')'"
Capture-Screen $emulator "$docsDir\04_app_options_dialog.png"

# STEP 5: Click su "Aggiungi ai Preferiti", verifica chiusura dialogo e popolamento reale di 3 Preferiti!
& $adb -s $emulator shell input keyevent 23 # Click su riga 0 "Aggiungi ai Preferiti" (Netflix)
Start-Sleep -Milliseconds 1000
$xml5a = Get-UiDumpXml $emulator
Assert-Step (-not ($xml5a.OuterXml -match "Informazioni Applicazione")) "Dialogo chiuso con successo dopo 'Aggiungi ai Preferiti'"

# Aggiunge altri 2 preferiti reali tramite UI (Prime Video a destra, Mediaset Infinity a sinistra) per una riga preferiti ricca
& $adb -s $emulator shell input keyevent 22 # DPAD_RIGHT -> Prime Video
Start-Sleep -Milliseconds 350
& $adb -s $emulator shell input keyevent --longpress 23
Start-Sleep -Milliseconds 1100
$xmlTemp1 = Get-UiDumpXml $emulator
if ($xmlTemp1.OuterXml -match "Aggiungi ai Preferiti") {
    & $adb -s $emulator shell input keyevent 23
    Start-Sleep -Milliseconds 900
} else {
    & $adb -s $emulator shell input keyevent 4
    Start-Sleep -Milliseconds 500
}

& $adb -s $emulator shell input keyevent 21 # DPAD_LEFT -> Netflix
Start-Sleep -Milliseconds 250
& $adb -s $emulator shell input keyevent 21 # DPAD_LEFT -> Mediaset Infinity
Start-Sleep -Milliseconds 350
& $adb -s $emulator shell input keyevent --longpress 23
Start-Sleep -Milliseconds 1100
$xmlTemp2 = Get-UiDumpXml $emulator
if ($xmlTemp2.OuterXml -match "Aggiungi ai Preferiti") {
    & $adb -s $emulator shell input keyevent 23
    Start-Sleep -Milliseconds 900
} else {
    & $adb -s $emulator shell input keyevent 4
    Start-Sleep -Milliseconds 500
}

# Sposta il focus nella riga App Preferite appena popolata e verifica tutte e 4 le sezioni visibili!
& $adb -s $emulator shell input keyevent 19 # DPAD_UP -> Entra nella riga App Preferite
Start-Sleep -Milliseconds 450
& $adb -s $emulator shell input keyevent 19 # DPAD_UP -> Top/Inputs per garantire ScrollY=0
Start-Sleep -Milliseconds 350
& $adb -s $emulator shell input keyevent 20 # DPAD_DOWN -> App Preferite con focus reale
Start-Sleep -Milliseconds 500

$xml5 = Get-UiDumpXml $emulator
$favCardNodes = $xml5.SelectNodes("//node[@resource-id='it.akai.customhome:id/scroll_favs']//node[@resource-id='it.akai.customhome:id/card_root']")
Assert-Step ($null -ne $favCardNodes -and $favCardNodes.Count -ge 3) "Riga App Preferite popolata realmente (card visibili: $($favCardNodes.Count))"
$titleInputs = Get-UiNodeById $xml5 "it.akai.customhome:id/tv_title_inputs"
$titleFavs = Get-UiNodeById $xml5 "it.akai.customhome:id/tv_title_favorites"
$titleStreaming = Get-UiNodeById $xml5 "it.akai.customhome:id/tv_title_streaming"
$scrollAllApps = Get-UiNodeById $xml5 "it.akai.customhome:id/scroll_all_apps"
$bAllApps = Parse-Bounds $scrollAllApps.bounds
Assert-Step ($null -ne $titleInputs -and $null -ne $titleFavs -and $null -ne $titleStreaming -and $null -ne $scrollAllApps -and $bAllApps.Y2 -le 1080) "Tutte e 4 le sezioni visibili contemporaneamente in 1080p senza taglio inferiore (bottom=$($bAllApps.Y2))"
Capture-Screen $emulator "$docsDir\05_favorites_row_populated.png"

# STEP 6: Navigazione deterministica verso pulsante "Tema" in Top Bar e apertura dialogo Tema
& $adb -s $emulator shell input keyevent 19 # DPAD_UP -> Ingressi
Start-Sleep -Milliseconds 300
& $adb -s $emulator shell input keyevent 19 # DPAD_UP -> Top Bar (btn_home_wifi)
Start-Sleep -Milliseconds 400

$foundThemeBtn = $false
for ($try = 0; $try -lt 6; $try++) {
    $xmlSeek = Get-UiDumpXml $emulator
    $focSeek = Get-FocusedNode $xmlSeek
    if ($null -ne $focSeek -and $focSeek.'resource-id' -eq "it.akai.customhome:id/btn_home_theme") {
        $foundThemeBtn = $true
        break
    } elseif ($null -ne $focSeek -and $focSeek.'resource-id' -eq "it.akai.customhome:id/btn_home_settings") {
        & $adb -s $emulator shell input keyevent 21 # DPAD_LEFT -> btn_home_theme
    } else {
        & $adb -s $emulator shell input keyevent 22 # DPAD_RIGHT
    }
    Start-Sleep -Milliseconds 350
}
Assert-Step $foundThemeBtn "Focus posizionato con precisione sul pulsante 'Tema' della Top Bar"

& $adb -s $emulator shell input keyevent 23 # DPAD_CENTER -> Apre dialogo Tema
Start-Sleep -Milliseconds 1200
$xml6 = Get-UiDumpXml $emulator
$rawXml6 = $xml6.OuterXml
Assert-Step (($rawXml6 -match "Personalizzazione AKAI Home") -and ($rawXml6 -match "Scegli Sfondo")) "Menu Personalizzazione Tema aperto e verificato visivamente tramite UIAutomator"
Capture-Screen $emulator "$docsDir\06_theme_customization_dialog.png"

# Chiusura dialogo Tema e verifica chiusura reale
& $adb -s $emulator shell input keyevent 4 # BACK
Start-Sleep -Milliseconds 500
$xml6Closed = Get-UiDumpXml $emulator
Assert-Step (-not ($xml6Closed.OuterXml -match "Personalizzazione AKAI Home")) "Dialogo Tema chiuso correttamente con BACK"

# STEP 7: Test reale uscita verso app esterna e ritorno mediante tasto fisico KEYCODE_HOME (3)
Write-Host "`n[7/7] Verifica uscita su app esterna e ritorno reale tramite KEYCODE_HOME (3)..." -ForegroundColor Yellow
& $adb -s $emulator shell am start -W -n test.tv.netflix/.MainActivity | Out-Null
Start-Sleep -Seconds 1.5
$extFocus = (& $adb -s $emulator shell dumpsys window windows | Select-String -Pattern "mCurrentFocus") -join "`n"
Assert-Step ($extFocus -match "test\.tv\.netflix") "Uscita dal launcher verificata: finestra attiva ora su app esterna (test.tv.netflix)"

# Invio autentico KEYCODE_HOME (nessun am start artificiale!)
& $adb -s $emulator shell input keyevent 3
Start-Sleep -Seconds 1.5

$homeReturnFocus = (& $adb -s $emulator shell dumpsys window windows | Select-String -Pattern "mCurrentFocus") -join "`n"
if (-not ($homeReturnFocus -match "it\.akai\.customhome/(\.|it\.akai\.customhome\.)MainActivity")) {
    throw "HOME RETURN: FAIL - Il tasto HOME ha portato a '$homeReturnFocus' invece che a it.akai.customhome/.MainActivity"
}
Assert-Step ($homeReturnFocus -match "it\.akai\.customhome/(\.|it\.akai\.customhome\.)MainActivity") "HOME RETURN: PASS - Tasto fisico HOME (3) ha riportato in primo piano it.akai.customhome"

$xml7 = Get-UiDumpXml $emulator
$foc7 = Get-FocusedNode $xml7
Assert-Step ($null -ne $foc7 -and $foc7.package -eq "it.akai.customhome") "Focus tastiera/D-Pad trattenuto attivamente dentro AKAI Custom Home ($($foc7.'resource-id'))"
Capture-Screen $emulator "$docsDir\07_home_key_focus_retention.png"

Write-Host "`n=================================================================" -ForegroundColor Green
Write-Host " COLLAUDO RUNTIME EMULATORE ANDROID TV: 100% VERIFICATO (UI + HOME)" -ForegroundColor Green
Write-Host " Tutte le 7 evidenze 1080p validate tramite UIAutomator XML" -ForegroundColor Green
Write-Host " ZERO comandi inviati verso la TV fisica" -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Green
