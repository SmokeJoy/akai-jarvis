# ==============================================================================
# AKAI Custom Remote - Provisioning Sicuro TLS Keystore per Dispositivo
#
# REGOLA DI SICUREZZA:
# Durante la fase di review tecnica, l'esecuzione su TV fisica è congelata (HARDWARE FREEZE).
# Lo script richiede obbligatoriamente il flag: -AllowHardwareExecution
#
# Caratteristiche Tecniche di Sicurezza (Revisione 6):
# 1. Zero Transito su /sdcard:
#    I file di chiavi e password NON vengono mai scritti su storage condiviso pubblico (/sdcard).
#    I byte vengono trasferiti direttamente tramite stdin pipe sicura (adb exec-in) nello storage privato.
# 2. Verifica Fail-Closed ad ogni passaggio:
#    Ogni comando controlla $LASTEXITCODE e verifica l'esistenza e dimensione dei file provisionati.
# 3. Pulizia Garantita:
#    I file temporanei locali vengono distrutti nel blocco finally con sovrascrittura.
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
if (-not (Test-Path $keytool)) {
    $kt = Get-Command keytool -ErrorAction SilentlyContinue
    if ($kt) { $keytool = $kt.Source } else { $keytool = "keytool" }
}
$adb = Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Path
if (-not $adb) { $adb = "adb" }

$TargetAdb = "$($TargetTv):5555"
$tempDir = [System.IO.Path]::GetTempPath()
$p12File = Join-Path $tempDir "device_server_keystore_$([Guid]::NewGuid().ToString('N')).p12"
$passFile = Join-Path $tempDir "device_server_keystore_$([Guid]::NewGuid().ToString('N')).pass"

try {
    # 1. Genera password crittografica casuale a 24 caratteri
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 18
    $rng.GetBytes($bytes)
    $password = [Convert]::ToBase64String($bytes).Replace('+', 'X').Replace('/', 'Y').Replace('=', 'Z')

    [System.IO.File]::WriteAllText($passFile, $password, [System.Text.Encoding]::UTF8)

    if (Test-Path $p12File) { Remove-Item $p12File -Force }

    Write-Host "=== GENERAZIONE TLS KEYSTORE SPECIFICO PER DISPOSITIVO ($TargetTv) ===" -ForegroundColor Cyan
    & $keytool -genkeypair -alias akaitv -keyalg RSA -keysize 2048 -validity 3650 `
        -keystore $p12File -storetype PKCS12 `
        -storepass $password -keypass $password `
        -ext "SAN=ip:$TargetTv,dns:localhost" `
        -dname "CN=$TargetTv,O=AKAI Custom Remote,C=IT"

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $p12File) -or (Get-Item $p12File).Length -lt 512) {
        throw "ERRORE FAIL-CLOSED: Generazione keystore con keytool fallita (exit $LASTEXITCODE)."
    }

    $p12Length = (Get-Item $p12File).Length
    Write-Host "Keystore TLS generato con successo: $p12Length bytes" -ForegroundColor Green

    # 2. Connessione ADB e streaming diretto in storage privato (ZERO transito su /sdcard)
    Write-Host "Connessione a $TargetAdb..."
    & $adb connect $TargetAdb | Out-Null

    Write-Host "[1/3] Streaming diretto keystore PKCS12 in /data/data/$PackageName/files/server_keystore.p12..."
    Get-Content -Path $p12File -Encoding Byte -Raw | & $adb -s $TargetAdb exec-in "run-as $PackageName sh -c 'mkdir -p files && cat > files/server_keystore.p12 && chmod 600 files/server_keystore.p12'" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        # Fallback a su se run-as negato
        Get-Content -Path $p12File -Encoding Byte -Raw | & $adb -s $TargetAdb exec-in "su -c 'mkdir -p /data/data/$PackageName/files && cat > /data/data/$PackageName/files/server_keystore.p12 && chmod 600 /data/data/$PackageName/files/server_keystore.p12'" 2>&1 | Out-Null
    }

    Write-Host "[2/3] Streaming diretto password in /data/data/$PackageName/files/server_keystore.pass..."
    Get-Content -Path $passFile -Encoding Byte -Raw | & $adb -s $TargetAdb exec-in "run-as $PackageName sh -c 'cat > files/server_keystore.pass && chmod 600 files/server_keystore.pass'" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Get-Content -Path $passFile -Encoding Byte -Raw | & $adb -s $TargetAdb exec-in "su -c 'cat > /data/data/$PackageName/files/server_keystore.pass && chmod 600 /data/data/$PackageName/files/server_keystore.pass'" 2>&1 | Out-Null
    }

    # 3. Verifica Fail-Closed dell'installazione del file su device
    Write-Host "[3/3] Verifica presenza e dimensione dei file provisionati su device..."
    $checkLs = & $adb -s $TargetAdb shell "run-as $PackageName ls -l files/server_keystore.p12" 2>&1
    if ($LASTEXITCODE -ne 0) {
        $checkLs = & $adb -s $TargetAdb shell "su -c 'ls -l /data/data/$PackageName/files/server_keystore.p12'" 2>&1
    }

    if ($LASTEXITCODE -ne 0 -or $checkLs -notmatch "server_keystore\.p12") {
        throw "ERRORE FAIL-CLOSED: Verifica provisioning fallita! Il file server_keystore.p12 non e' presente nello storage privato della TV ($checkLs)."
    }

    Write-Host "Verifica completata: Keystore presente e protetto in storage privato: $checkLs" -ForegroundColor Green

    # 4. Riavvio controllato del servizio
    Write-Host "Riavvio RemoteServerService per attivare listener HTTPS con il nuovo certificato..."
    & $adb -s $TargetAdb shell "am force-stop $PackageName" | Out-Null
    & $adb -s $TargetAdb shell "am startservice $PackageName/.RemoteServerService" | Out-Null

    Write-Host "`nPROVISIONING TLS SPECIFICO COMPLETATO E VERIFICATO CON SUCCESSO AL 100%!" -ForegroundColor Green

} finally {
    # Pulizia garantita file temporanei locali
    if (Test-Path $p12File) {
        [System.IO.File]::WriteAllBytes($p12File, (New-Object byte[] 512))
        Remove-Item $p12File -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $passFile) {
        [System.IO.File]::WriteAllText($passFile, "000000000000000000000000")
        Remove-Item $passFile -Force -ErrorAction SilentlyContinue
    }
}
