# ==============================================================================
# AKAI Custom TV - Script 11: Unit Test Deterministico Isolamento Fail-Closed ADB (P0)
# Valida che scripts/10_android_tv_emulator_smoke_test.ps1 rifiuti categoricamente:
# 1. Solo TV fisica (192.168.1.8:5555)
# 2. TV fisica + Emulatore contemporanei
# 3. Nessun dispositivo connesso (lista vuota)
# 4. Molteplici emulatori contemporanei (ambiguità)
# 5. Dispositivi USB o seriali estranei non-emulatore
# 6. Emulatore in stato non-device (offline/unauthorized)
# E accetti unicamente 1 singolo emulatore virtuale validato in stato 'device'.
# ==============================================================================

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = $PSScriptRoot }
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$workspace = (Resolve-Path (Join-Path $scriptDir "..")).Path
$script10 = Join-Path $workspace "scripts/10_android_tv_emulator_smoke_test.ps1"

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " TEST ISOLAMENTO DETERMINISTICO ADB FAIL-CLOSED (P0 SAFETY SUITE)" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "Target script sotto test: $script10" -ForegroundColor Gray

$passed = 0
$total = 7

# SCENARIO 1: Solo TV fisica connessa via rete (192.168.1.8:5555)
$mockTvOnly = "List of devices attached`n192.168.1.8:5555`tdevice"
try {
    & $script10 -MockDeviceListTest -MockDevicesOutput $mockTvOnly
    Write-Host "  [FAIL] Scenario 1: Doveva sollevare eccezione di sicurezza per TV fisica!" -ForegroundColor Red
} catch {
    if ($_ -match "SICUREZZA P0 VIOLATA") {
        Write-Host "  [PASS] Scenario 1 (Solo TV fisica): Bloccato fail-closed con eccezione P0 attesa" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "  [FAIL] Scenario 1: Errore imprevisto: $_" -ForegroundColor Red
    }
}

# SCENARIO 2: TV fisica + Emulatore connessi contemporaneamente
$mockTvAndEmulator = "List of devices attached`nemulator-5554`tdevice`n192.168.1.8:5555`tdevice"
try {
    & $script10 -MockDeviceListTest -MockDevicesOutput $mockTvAndEmulator
    Write-Host "  [FAIL] Scenario 2: Doveva fallire rilevando presenza TV fisica in parallelo!" -ForegroundColor Red
} catch {
    if ($_ -match "SICUREZZA P0 VIOLATA") {
        Write-Host "  [PASS] Scenario 2 (TV + Emulatore): Bloccato fail-closed con eccezione P0 attesa" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "  [FAIL] Scenario 2: Errore imprevisto: $_" -ForegroundColor Red
    }
}

# SCENARIO 3: Nessun dispositivo connesso (lista vuota)
$mockEmpty = "List of devices attached`n"
try {
    & $script10 -MockDeviceListTest -MockDevicesOutput $mockEmpty
    Write-Host "  [FAIL] Scenario 3: Doveva fallire per assenza dispositivi!" -ForegroundColor Red
} catch {
    if ($_ -match "SICUREZZA P0 FAIL-CLOSED") {
        Write-Host "  [PASS] Scenario 3 (Nessun device): Bloccato fail-closed con eccezione P0 attesa" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "  [FAIL] Scenario 3: Errore imprevisto: $_" -ForegroundColor Red
    }
}

# SCENARIO 4: Più emulatori connessi contemporaneamente (ambiguità)
$mockMultipleEmulators = "List of devices attached`nemulator-5554`tdevice`nemulator-5556`tdevice"
try {
    & $script10 -MockDeviceListTest -MockDevicesOutput $mockMultipleEmulators
    Write-Host "  [FAIL] Scenario 4: Doveva fallire per ambiguità multipli emulatori!" -ForegroundColor Red
} catch {
    if ($_ -match "SICUREZZA P0 FAIL-CLOSED" -and $_ -match "ambiguit") {
        Write-Host "  [PASS] Scenario 4 (Multipli emulatori): Bloccato per ambiguità target" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "  [FAIL] Scenario 4: Errore imprevisto: $_" -ForegroundColor Red
    }
}

# SCENARIO 5: Singolo emulatore Android TV valido (con tab backtick-t e spazi multipli)
$mockValidEmulator = "List of devices attached`nemulator-5554`tdevice"
try {
    $res = & $script10 -MockDeviceListTest -MockDevicesOutput $mockValidEmulator
    if ($res -eq "emulator-5554") {
        Write-Host "  [PASS] Scenario 5 (Singolo emulatore valido con tab): Individuato correttamente '$res'" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "  [FAIL] Scenario 5: Risultato inatteso '$res'" -ForegroundColor Red
    }
} catch {
    Write-Host "  [FAIL] Scenario 5: Fallito inaspettatamente: $_" -ForegroundColor Red
}

# SCENARIO 6: Dispositivo fisico USB estraneo (es. smartphone o dev-board)
$mockUsbDevice = "List of devices attached`n0123456789ABCDEF`tdevice"
try {
    & $script10 -MockDeviceListTest -MockDevicesOutput $mockUsbDevice
    Write-Host "  [FAIL] Scenario 6: Doveva fallire rilevando dispositivo hardware USB estraneo!" -ForegroundColor Red
} catch {
    if ($_ -match "SICUREZZA P0 VIOLATA") {
        Write-Host "  [PASS] Scenario 6 (Dispositivo USB estraneo): Bloccato con eccezione P0 attesa" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "  [FAIL] Scenario 6: Errore imprevisto: $_" -ForegroundColor Red
    }
}

# SCENARIO 7: Emulatore non pronto (stato offline o unauthorized)
$mockOfflineEmulator = "List of devices attached`nemulator-5554`toffline"
try {
    & $script10 -MockDeviceListTest -MockDevicesOutput $mockOfflineEmulator
    Write-Host "  [FAIL] Scenario 7: Doveva fallire per emulatore non pronto (offline)!" -ForegroundColor Red
} catch {
    if ($_ -match "SICUREZZA P0 FAIL-CLOSED") {
        Write-Host "  [PASS] Scenario 7 (Emulatore offline): Bloccato fail-closed per target non operativo" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "  [FAIL] Scenario 7: Errore imprevisto: $_" -ForegroundColor Red
    }
}

Write-Host "`n=================================================================" -ForegroundColor Cyan
Write-Host " RISULTATO SUITE ISOLAMENTO ADB: $passed / $total SUPERATI" -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Cyan

if ($passed -ne $total) {
    exit 1
}
