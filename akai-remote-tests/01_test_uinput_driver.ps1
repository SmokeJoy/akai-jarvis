# ==============================================================================
# AKAI Custom Remote - Test 01: Verifica Driver Kernel UInput
# Verifica disponibilita' di /dev/uinput e permessi per creazione virtual device
# ==============================================================================

$ErrorActionPreference = "Stop"

Write-Host "=== TEST 01: VERIFICA DRIVER KERNEL UINPUT ===" -ForegroundColor Cyan

$adb = Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" | Select-Object -First 1 -ExpandProperty Path
& $adb connect 192.168.1.103:5555 | Out-Null
Start-Sleep -Milliseconds 500

Write-Host "[1/3] Verifica presenza nodo dispositivo /dev/uinput..."
$uinputStat = & $adb -s 192.168.1.103:5555 shell "ls -la /dev/uinput"
Write-Host "      Risultato: $uinputStat"

if ($uinputStat -match "crw-rw-rw-") {
    Write-Host "      OK: Permessi POSIX 0666 confermati (accesso consentito a tutte le app)." -ForegroundColor Green
} else {
    Write-Host "      ATTENZIONE: Permessi non 0666 ($uinputStat)" -ForegroundColor Yellow
}

Write-Host "`n[2/3] Verifica supporto kernel CONFIG_INPUT_UINPUT..."
$kernelConfig = & $adb -s 192.168.1.103:5555 shell "zcat /proc/config.gz 2>/dev/null | grep -i uinput"
Write-Host "      Config: $kernelConfig"

Write-Host "`n[3/3] Verifica stato SELinux del sistema..."
$selinux = & $adb -s 192.168.1.103:5555 shell "getenforce"
Write-Host "      SELinux: $selinux"

if ($selinux.Trim() -eq "Permissive") {
    Write-Host "      OK: SELinux Permissive: le chiamate ioctl /dev/uinput da app utente non sono bloccate dal MAC policy." -ForegroundColor Green
} else {
    Write-Host "      SELinux Enforcing: verificare avc denial per il dominio untrusted_app." -ForegroundColor Yellow
}

Write-Host "`n=== ESITO TEST 01 COMPLETATO ===" -ForegroundColor Cyan
