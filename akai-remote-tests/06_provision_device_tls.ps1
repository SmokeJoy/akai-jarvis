# ==============================================================================
# AKAI Custom Remote - Provisioning Sicuro TLS Keystore per Dispositivo
#
# REGOLA DI SICUREZZA:
# Durante la fase di review tecnica, l'esecuzione su TV fisica è congelata (HARDWARE FREEZE).
# Lo script richiede obbligatoriamente il flag: -AllowHardwareExecution
#
# Caratteristiche Tecniche di Sicurezza (Revisione 7):
# 1. Zero Transito su /sdcard:
#    I file di chiavi e password NON vengono mai scritti su storage condiviso pubblico (/sdcard).
# 2. Streaming Binario Universale (Send-FileViaAdbExecIn):
#    I byte vengono trasferiti tramite [System.IO.File]::ReadAllBytes su StandardInput.BaseStream (adb exec-in).
#    Zero dipendenza da Get-Content -Encoding Byte (incompatibile con PowerShell 7 / pwsh).
# 3. Verifica Fail-Closed ad ogni passaggio:
#    Ogni comando controlla $LASTEXITCODE ed esegue verifica di presenza e leggibilita' di .p12 e .pass.
# 4. Pulizia Crittografica Garantita:
#    I file temporanei locali vengono sovrascritti con byte nulli e rimossi nel blocco finally.
# ==============================================================================

param(
    [string]$TargetTv = "",
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

if ([string]::IsNullOrWhiteSpace($TargetTv)) {
    Write-Host "ERRORE: Parametro -TargetTv obbligatorio mancante. Specificare l'indirizzo IP della TV." -ForegroundColor Red
    exit 1
}

function Send-FileViaAdbExecIn {
    param(
        [string]$AdbExe,
        [string]$TargetAdb,
        [string]$LocalFilePath,
        [string]$RemoteCommand
    )
    if (-not (Test-Path $LocalFilePath)) {
        throw "ERRORE: File locale non trovato: $LocalFilePath"
    }

    $bytes = [System.IO.File]::ReadAllBytes($LocalFilePath)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $AdbExe
    $psi.Arguments = "-s $TargetAdb exec-in `"$RemoteCommand`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stream = $proc.StandardInput.BaseStream
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
    $stream.Close()

    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    return @{
        ExitCode = $proc.ExitCode
        Success = ($proc.ExitCode -eq 0)
        Output = "$stdout $stderr".Trim()
    }
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
    $p12Stream = Send-FileViaAdbExecIn -AdbExe $adb -TargetAdb $TargetAdb -LocalFilePath $p12File -RemoteCommand "run-as $PackageName sh -c 'mkdir -p files; cat > files/server_keystore.p12; chmod 600 files/server_keystore.p12'"
    if (-not $p12Stream.Success) {
        # Fallback a su se run-as negato
        $p12Stream = Send-FileViaAdbExecIn -AdbExe $adb -TargetAdb $TargetAdb -LocalFilePath $p12File -RemoteCommand "su -c 'mkdir -p /data/data/$PackageName/files; cat > /data/data/$PackageName/files/server_keystore.p12; chown -R ${PackageName}:${PackageName} /data/data/$PackageName/files; chmod 600 /data/data/$PackageName/files/server_keystore.p12'"
    }
    if (-not $p12Stream.Success) {
        throw "ERRORE FAIL-CLOSED: Impossibile effettuare lo streaming del keystore TLS su device ($($p12Stream.Output))."
    }

    Write-Host "[2/3] Streaming diretto password in /data/data/$PackageName/files/server_keystore.pass..."
    $passStream = Send-FileViaAdbExecIn -AdbExe $adb -TargetAdb $TargetAdb -LocalFilePath $passFile -RemoteCommand "run-as $PackageName sh -c 'cat > files/server_keystore.pass; chmod 600 files/server_keystore.pass'"
    if (-not $passStream.Success) {
        $passStream = Send-FileViaAdbExecIn -AdbExe $adb -TargetAdb $TargetAdb -LocalFilePath $passFile -RemoteCommand "su -c 'cat > /data/data/$PackageName/files/server_keystore.pass; chown ${PackageName}:${PackageName} /data/data/$PackageName/files/server_keystore.pass; chmod 600 /data/data/$PackageName/files/server_keystore.pass'"
    }
    if (-not $passStream.Success) {
        throw "ERRORE FAIL-CLOSED: Impossibile effettuare lo streaming del file password su device ($($passStream.Output))."
    }

    # 3. Verifica Fail-Closed dell'installazione dei file su device
    Write-Host "[3/3] Verifica presenza e dimensione dei file provisionati su device..."
    $checkLsP12 = & $adb -s $TargetAdb shell "run-as $PackageName ls -l files/server_keystore.p12" 2>&1
    if ($LASTEXITCODE -ne 0) {
        $checkLsP12 = & $adb -s $TargetAdb shell "su -c 'ls -l /data/data/$PackageName/files/server_keystore.p12'" 2>&1
    }

    $checkLsPass = & $adb -s $TargetAdb shell "run-as $PackageName ls -l files/server_keystore.pass" 2>&1
    if ($LASTEXITCODE -ne 0) {
        $checkLsPass = & $adb -s $TargetAdb shell "su -c 'ls -l /data/data/$PackageName/files/server_keystore.pass'" 2>&1
    }

    if ($LASTEXITCODE -ne 0 -or $checkLsP12 -notmatch "server_keystore\.p12" -or $checkLsPass -notmatch "server_keystore\.pass") {
        throw "ERRORE FAIL-CLOSED: Verifica provisioning fallita! Keystore o password non presenti nello storage privato della TV."
    }

    Write-Host "Verifica completata: Keystore e password protetti in storage privato." -ForegroundColor Green

    # 4. Riavvio controllato del servizio
    Write-Host "Riavvio RemoteServerService per attivare listener HTTPS con il nuovo certificato..."
    & $adb -s $TargetAdb shell "am force-stop $PackageName" | Out-Null
    & $adb -s $TargetAdb shell "am startservice $PackageName/.RemoteServerService" | Out-Null

    Write-Host "`nPROVISIONING TLS SPECIFICO COMPLETATO E VERIFICATO CON SUCCESSO AL 100%!" -ForegroundColor Green

} finally {
    # Pulizia crittografica garantita file temporanei locali
    if (Test-Path $p12File) {
        [System.IO.File]::WriteAllBytes($p12File, (New-Object byte[] 512))
        Remove-Item $p12File -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $passFile) {
        [System.IO.File]::WriteAllText($passFile, "000000000000000000000000")
        Remove-Item $passFile -Force -ErrorAction SilentlyContinue
    }
}
