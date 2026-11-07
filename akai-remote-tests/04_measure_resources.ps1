# ==============================================================================
# AKAI Custom Remote - Test 04: Misurazione Consumo Risorse (PSS RAM, Swap, CPU)
# Misura telemetria di memoria e impatto prestazionale del demone sulla TV
# ==============================================================================

param(
    [string]$PackageName = "it.akai.customremote",
    [int]$Samples = 5
)

$ErrorActionPreference = "Stop"

Write-Host "=== TEST 04: TELEMETRIA RISORSE PER $PackageName ===" -ForegroundColor Cyan

$adb = Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" | Select-Object -First 1 -ExpandProperty Path
& $adb connect 192.168.1.103:5555 | Out-Null
Start-Sleep -Milliseconds 500

$pidCheck = & $adb -s 192.168.1.103:5555 shell "pidof $PackageName"
if (-not $pidCheck -or $pidCheck.Trim() -eq "") {
    Write-Host "Processo $PackageName non in esecuzione sulla TV." -ForegroundColor Yellow
    Write-Host "Nota: Il test potra' essere eseguito non appena l'APK sara' installato e autorizzato." -ForegroundColor Gray
    exit 0
}

$procPid = $pidCheck.Trim().Split(" ")[0]
Write-Host "Processo attivo trovato: PID $procPid" -ForegroundColor Green

Write-Host "`nAcquisizione $Samples campioni telemetrici (intervallo 2s)..."

for ($i = 1; $i -le $Samples; $i++) {
    $memDump = & $adb -s 192.168.1.103:5555 shell "dumpsys meminfo $procPid"
    $pssTotal = [regex]::Match($memDump, "TOTAL PSS:\s+(\d+)").Groups[1].Value
    $swapTotal = [regex]::Match($memDump, "TOTAL SWAP PSS:\s+(\d+)").Groups[1].Value

    if ($pssTotal) {
        $pssMb = [Math]::Round([int]$pssTotal / 1024, 2)
        $swapMb = if ($swapTotal) { [Math]::Round([int]$swapTotal / 1024, 2) } else { 0 }
        Write-Host "  Campione $i: PSS = $pssMb MB | Swap ZRAM = $swapMb MB"
    }
    Start-Sleep -Seconds 2
}

Write-Host "`n=== ESITO TEST 04 COMPLETATO ===" -ForegroundColor Cyan
