# ==============================================================================
# AKAI Custom Remote - Provisioning Sicuro TLS Keystore per Dispositivo
#
# REGOLA DI SICUREZZA:
# Durante la fase di review tecnica, l'esecuzione su TV fisica è congelata (HARDWARE FREEZE).
# Lo script richiede obbligatoriamente il flag: -AllowHardwareExecution
# ==============================================================================

param(
    [string]$TargetTv = "192.168.1.8",
    [string]$PackageName = "it.akai.customremote",
    [switch]$AllowHardwareExecution = $false
)

$ErrorActionPreference = "Stop"

if (-not $AllowHardwareExecution) {
    Write-Host "================================================================================" -ForegroundColor Red
    Write-Host "BLOCCO DI SICUREZZA ATTIVO (HARDWARE FREEZE):" -ForegroundColor Red
    Write-Host "L'esecuzione su hardware fisico TV e' bloccata fino all'approvazione formale." -ForegroundColor Yellow
    Write-Host "Per autorizzare l'esecuzione e' richiesto il parametro: -AllowHardwareExecution" -ForegroundColor Yellow
    Write-Host "================================================================================" -ForegroundColor Red
    exit 1
}

$jdkDir = "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay\tools\jdk-17"
$keytool = Join-Path $jdkDir "bin\keytool.exe"
$adb = Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Path
if (-not $adb) { $adb = "adb" }

$TargetAdb = "$($TargetTv):5555"
$tempDir = [System.IO.Path]::GetTempPath()
$p12File = Join-Path $tempDir "device_server_keystore.p12"
$passFile = Join-Path $tempDir "device_server_keystore.pass"

try {
    # 1. Genera password casuale a 24 caratteri
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 18
    $rng.GetBytes($bytes)
    $password = [Convert]::ToBase64String($bytes).Replace('+', 'X').Replace('/', 'Y').Replace('=', 'Z')

    [System.IO.File]::WriteAllText($passFile, $password)

    if (Test-Path $p12File) { Remove-Item $p12File -Force }

    Write-Host "=== GENERAZIONE TLS KEYSTORE SPECIFICO PER DISPOSITIVO ($TargetTv) ===" -ForegroundColor Cyan
    & $keytool -genkeypair -alias akaitv -keyalg RSA -keysize 2048 -validity 3650 `
        -keystore $p12File -storetype PKCS12 `
        -storepass $password -keypass $password `
        -ext "SAN=ip:$TargetTv,dns:localhost" `
        -dname "CN=$TargetTv,O=AKAI Custom Remote,C=IT"

    if (-not (Test-Path $p12File)) {
        throw "Generazione keystore fallita."
    }

    Write-Host "Keystore TLS generato con successo: $p12File" -ForegroundColor Green

    # 2. Deploy sicuro su internal storage privato (/data/data/.../files)
    Write-Host "Provisioning sicuro dei file TLS su TV via ADB..."
    & $adb connect $TargetAdb | Out-Null
    & $adb -s $TargetAdb push $p12File "/sdcard/tmp_keystore.p12" | Out-Null
    & $adb -s $TargetAdb push $passFile "/sdcard/tmp_keystore.pass" | Out-Null

    & $adb -s $TargetAdb shell "run-as $PackageName mkdir -p files" 2>&1 | Out-Null
    & $adb -s $TargetAdb shell "run-as $PackageName cp /sdcard/tmp_keystore.p12 files/server_keystore.p12" 2>&1 | Out-Null
    & $adb -s $TargetAdb shell "run-as $PackageName cp /sdcard/tmp_keystore.pass files/server_keystore.pass" 2>&1 | Out-Null
    & $adb -s $TargetAdb shell "rm -f /sdcard/tmp_keystore.p12 /sdcard/tmp_keystore.pass" 2>&1 | Out-Null

    Write-Host "Riavvio servizio per applicare il nuovo certificato TLS per-dispositivo..."
    & $adb -s $TargetAdb shell "am force-stop $PackageName" | Out-Null
    & $adb -s $TargetAdb shell "am startservice $PackageName/.RemoteServerService" | Out-Null

    Write-Host "PROVISIONING TLS COMPLETATO CON SUCCESSO SUL DISPOSITIVO!" -ForegroundColor Green

} finally {
    if (Test-Path $p12File) { Remove-Item $p12File -Force -ErrorAction SilentlyContinue }
    if (Test-Path $passFile) { Remove-Item $passFile -Force -ErrorAction SilentlyContinue }
}
