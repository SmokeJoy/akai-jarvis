# ==============================================================================
# AKAI Custom TV - Script 11: Unit Test Isolamento Fail-Closed Script 10 (P0)
# Valida che scripts/10_android_tv_emulator_smoke_test.ps1 rifiuti categoricamente:
# 1. Solo TV fisica (192.168.1.8:5555)
# 2. TV fisica + Emulatore contemporanei
# 3. Nessun dispositivo connesso
# 4. Molteplici emulatori contemporanei
# E accetti unicamente 1 singolo emulatore virtuale validato.
# ==============================================================================

$ErrorActionPreference = "Stop"

$workspace = "C:\Users\danie\OneDrive\Documenti\Antygravity\Akay"
$script10 = Join-Path $workspace "scripts\10_android_tv_emulator_smoke_test.ps1"

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " TEST ISOLAMENTO DETERMINISTICO ADB FAIL-CLOSED (P0 SAFETY SUITE)" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

$passed = 0
$total = 5

# SCENARIO 1: Solo TV fisica connessa (192.168.1.8:5555)
$mockTvOnly = @"
List of devices attached
192.168.1.8:5555	device
"@
try {
    & $script10 -MockDeviceListTest -MockDevicesOutput $mockTvOnly
    Write-Host "  [FAIL] Scenario 1: Doveva fallire rilevando TV fisica!" -ForegroundColor Red
} catch {
    if ($_ -match "SICUREZZA P0 VIOLATA") {
        Write-Host "  [PASS] Scenario 1 (Solo TV fisica): Bloccato con successo fail-closed" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "  [FAIL] Scenario 1: Errore imprevisto: $_" -ForegroundColor Red
    }
}

# SCENARIO 2: TV fisica + Emulatore connessi insieme
$mockTvAndEmulator = @"
List of devices attached
emulator-5554	device
192.168.1.8:5555	device
"@
try {
    & $script10 -MockDeviceListTest -MockDevicesOutput $mockTvAndEmulator
    Write-Host "  [FAIL] Scenario 2: Doveva fallire rilevando presenza TV fisica con emulatore!" -ForegroundColor Red
} catch {
    if ($_ -match "SICUREZZA P0 VIOLATA") {
        Write-Host "  [PASS] Scenario 2 (TV + Emulatore): Bloccato con successo fail-closed" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "  [FAIL] Scenario 2: Errore imprevisto: $_" -ForegroundColor Red
    }
}

# SCENARIO 3: Nessun dispositivo connesso
$mockEmpty = @"
List of devices attached

"@
try {
    & $script10 -MockDeviceListTest -MockDevicesOutput $mockEmpty
    Write-Host "  [FAIL] Scenario 3: Doveva fallire per assenza dispositivi!" -ForegroundColor Red
} catch {
    if ($_ -match "SICUREZZA P0 FAIL-CLOSED") {
        Write-Host "  [PASS] Scenario 3 (Nessun device): Bloccato con successo fail-closed" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "  [FAIL] Scenario 3: Errore imprevisto: $_" -ForegroundColor Red
    }
}

# SCENARIO 4: Più emulatori connessi
$mockMultipleEmulators = @"
List of devices attached
emulator-5554	device
emulator-5556	device
"@
try {
    & $script10 -MockDeviceListTest -MockDevicesOutput $mockMultipleEmulators
    Write-Host "  [FAIL] Scenario 4: Doveva fallire per ambiguità emulatori!" -ForegroundColor Red
} catch {
    if ($_ -match "SICUREZZA P0 FAIL-CLOSED") {
        Write-Host "  [PASS] Scenario 4 (Multipli emulatori): Bloccato per ambiguità" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "  [FAIL] Scenario 4: Errore imprevisto: $_" -ForegroundColor Red
    }
}

# SCENARIO 5: Singolo emulatore Android TV valido
$mockValidEmulator = @"
List of devices attached
emulator-5554	device
"@
try {
    $res = & $script10 -MockDeviceListTest -MockDevicesOutput $mockValidEmulator
    if ($res -eq "emulator-5554") {
        Write-Host "  [PASS] Scenario 5 (Singolo emulatore valido): Individuato correttamente '$res'" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "  [FAIL] Scenario 5: Risultato inatteso '$res'" -ForegroundColor Red
    }
} catch {
    Write-Host "  [FAIL] Scenario 5: Fallito inaspettatamente: $_" -ForegroundColor Red
}

Write-Host "`n=================================================================" -ForegroundColor Cyan
Write-Host " RISULTATO SUITE ISOLAMENTO ADB: $passed / $total SUPERATI" -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Cyan

if ($passed -ne $total) {
    exit 1
}
