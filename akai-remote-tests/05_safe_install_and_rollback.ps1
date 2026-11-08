# ==============================================================================
# AKAI Custom Remote - Procedura di Installazione Sicura, Verifica Firme e Rollback Atomico
#
# REGOLA DI SICUREZZA ASSOLUTA:
# Durante la fase di review tecnica, l'esecuzione su TV fisica è congelata (HARDWARE FREEZE).
# Lo script richiede obbligatoriamente il flag esplicito: -AllowHardwareExecution
#
# Caratteristiche Tecniche di Sicurezza (Revisione 7):
# 1. Riconoscimento Vincoli Architetturali Baseline Legacy (v5):
#    - Non attribuisce all'APK v5 capacità inesistenti (ACTION_BACKUP_DB / ACTION_RESTORE_DB assenti in v5).
#    - Cattura preventivamente backup logico REST /api/ai/memory se il server v5/v6 è online.
#    - Esegue snapshot binario Fail-Closed: se non è possibile estrarre un DB integro via UID o root, ABORTISCE.
# 2. Verifica Firma Digitale Fail-Closed Pre-Install:
#    - Estrae e confronta l'impronta SHA-256 (64 hex) tra backup e candidato con apksigner.
#    - Rifiuta categoricamente artefatti CI di test effimeri non distribuibili.
# 3. Controllo Integrità SQLite Rigoroso (Fail-Closed):
#    - Verifica offline PRAGMA integrity_check via Node.js, Python o sqlite3 CLI.
#    - Se nessun interprete è disponibile o il file è corrotto: THROW IMMEDIATO (zero fail-open).
# 4. Streaming Binario Universale PowerShell 5.1 / Pwsh 7:
#    - Send-FileViaAdbExecIn tramite [System.IO.File]::ReadAllBytes e Process.StandardInput.
#    - Zero dipendenza da Get-Content -Encoding Byte (incompatibile con PowerShell 7).
# 5. Rollback Atomico Indivisibile (APK + DB) con Verifica Hash SHA-256:
#    - In caso di timeout/anomalia watchdog (30s), reinstalla APK precedente e ripristina DB originale.
#    - Pulisce preventivamente file WAL/SHM orfani.
#    - Valida bit-for-bit la parità SHA-256 e l'integrità del DB ripristinato sul device.
# ==============================================================================

param(
    [ValidateSet("status", "backup", "install", "rollback", "plan")]
    [string]$Action = "status",
    [string]$ApkPath = $null,
    [string]$BackupDir = ".\backup_tv",
    [string]$TargetTv = "192.168.1.8",
    [int]$HttpPort = 8088,
    [string]$AuthToken = $null,
    [switch]$AllowHardwareExecution = $false
)

$ErrorActionPreference = "Stop"

$TargetAdb = "$($TargetTv):5555"
$PackageName = "it.akai.customremote"
$StatusUrl = "http://$($TargetTv):$HttpPort/api/status"
$WebUrl = "http://$($TargetTv):$HttpPort/index.html"
$MemoryUrl = "http://$($TargetTv):$HttpPort/api/ai/memory"

# -----------------------------------------------------------------------------
# SAFETY FREEZE GUARD
# -----------------------------------------------------------------------------
if ($Action -in @("install", "rollback", "backup") -and -not $AllowHardwareExecution) {
    Write-Host "================================================================================" -ForegroundColor Red
    Write-Host "BLOCCO DI SICUREZZA ATTIVO (HARDWARE FREEZE):" -ForegroundColor Red
    Write-Host "L'esecuzione su hardware fisico TV e' bloccata fino all'approvazione formale." -ForegroundColor Yellow
    Write-Host "Per visualizzare il piano operativo sicuro usa: -Action plan" -ForegroundColor Cyan
    Write-Host "Per autorizzare l'esecuzione su TV e' richiesto il parametro: -AllowHardwareExecution" -ForegroundColor Yellow
    Write-Host "================================================================================" -ForegroundColor Red
    exit 1
}

# Controllo obbligatorietà ApkPath per install
if ($Action -eq "install") {
    if ([string]::IsNullOrWhiteSpace($ApkPath)) {
        throw "ERRORE FAIL-CLOSED: Il parametro -ApkPath e' obbligatorio per l'azione install. Specificare un APK di release autentico (mai l'artefatto CI non distribuibile)."
    }
    if ($ApkPath -match "app-ci-test-nondistributable\.apk") {
        throw "BLOCCO DI SICUREZZA: L'APK candidato e' un artefatto di test CI ('$ApkPath') firmato con chiave effimera. L'installazione su TV reale e' categoricamente vietata."
    }
}

function Get-AdbExecutable {
    if ($env:ADB_EXECUTABLE -and (Test-Path $env:ADB_EXECUTABLE)) {
        return $env:ADB_EXECUTABLE
    }
    $adb = Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Path
    if (-not $adb -or -not (Test-Path $adb)) {
        $adb = "adb"
    }
    return $adb
}

function Get-ApkSignerJar {
    if ($env:APKSIGNER_JAR -and (Test-Path $env:APKSIGNER_JAR)) {
        return $env:APKSIGNER_JAR
    }
    $sdkDir = "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay\tools\android-sdk"
    $apksignerJar = Join-Path $sdkDir "build-tools\28.0.3\lib\apksigner.jar"
    if (Test-Path $apksignerJar) {
        return $apksignerJar
    }
    if ($env:ANDROID_HOME) {
        $found = Get-ChildItem -Path "$env:ANDROID_HOME/build-tools" -Filter "apksigner.jar" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
        if ($found) { return $found }
    }
    return $apksignerJar
}

function Get-Sha256Hex($filePath) {
    if (-not (Test-Path $filePath)) { return $null }
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($filePath)
    try {
        $hashBytes = $sha256.ComputeHash($stream)
        return [BitConverter]::ToString($hashBytes).Replace('-', '').ToLower()
    } finally {
        $stream.Close()
        $sha256.Dispose()
    }
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
    $proc.WaitForExit(10000)

    return @{
        ExitCode = $proc.ExitCode
        Success = ($proc.ExitCode -eq 0)
        Output = "$stdout $stderr".Trim()
    }
}

function Receive-FileViaAdbExecOut {
    param(
        [string]$AdbExe,
        [string]$TargetAdb,
        [string]$RemoteCommand,
        [string]$LocalFilePath
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $AdbExe
    $psi.Arguments = "-s $TargetAdb exec-out $RemoteCommand"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $parentDir = Split-Path $LocalFilePath -Parent
    if ($parentDir -and -not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Force -Path $parentDir | Out-Null
    }
    $outStream = [System.IO.File]::Create($LocalFilePath)
    try {
        $proc.StandardOutput.BaseStream.CopyTo($outStream)
    } finally {
        $outStream.Close()
    }
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit(10000)

    $success = ($proc.ExitCode -eq 0 -and (Test-Path $LocalFilePath) -and ((Get-Item $LocalFilePath).Length -ge 512))
    if (-not $success -and (Test-Path $LocalFilePath)) {
        Remove-Item $LocalFilePath -Force -ErrorAction SilentlyContinue
    }
    return @{
        ExitCode = $proc.ExitCode
        Success = $success
        Error = $stderr.Trim()
    }
}

function Get-ApplicationProcessState {
    param(
        [string]$AdbExe,
        [string]$TargetAdb,
        [string]$PackageName
    )
    # Esecuzione comando shell con marcatore esplicito: echo PIDOF_CHECK:pids=[$pids]:exit=[$code]
    # In una shell POSIX:
    # - Se il processo e' in esecuzione: pidof esce con 0 e stampa uno o piu' PID
    # - Se il processo NON e' in esecuzione: pidof esce con 1 e non stampa nulla
    # In entrambi i casi leciti, echo ha successo (exit 0) e stampa PIDOF_CHECK:pids=[$pids]:exit=[$code].
    #
    # Se ADB fallisce a monte (trasporto, timeout, demone terminato) o il comando fallisce senza stdout,
    # il probe fallisce categoricamente in FAIL-CLOSED.
    $probeCmd = "pids=`$(pidof $PackageName 2>/dev/null); code=`$?; echo PIDOF_CHECK:pids=[`$pids]:exit=[`$code]"
    $raw = & $AdbExe -s $TargetAdb shell $probeCmd 2>&1
    $adbExit = $LASTEXITCODE

    if ($adbExit -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        throw "ERRORE FAIL-CLOSED: Probe dello stato dei processi per $PackageName fallito su target device (exit: $adbExit, out: '$raw'). Impossibile verificare la quiescenza per errore di trasporto o permessi ADB."
    }

    $rawStr = $raw.ToString().Trim()
    if ($rawStr -match "PIDOF_CHECK:pids=\[([^\]]*)\]:exit=\[(\d+)\]") {
        $foundPids = $Matches[1].Trim()
        $pidofExit = [int]$Matches[2]

        # Classificazione deterministica e rigorosa degli exit code di pidof (Revisione 13)
        if ($pidofExit -eq 0) {
            if ([string]::IsNullOrWhiteSpace($foundPids)) {
                throw "ERRORE FAIL-CLOSED: Risultato incoerente del probe quiescenza per ${PackageName}: pidof ha restituito exit code 0 ma nessun PID e' stato catturato. Operazione bloccata in FAIL-CLOSED."
            }
            return @{
                Success = $true
                Pids = $foundPids
                PidofExit = $pidofExit
                IsRunning = $true
            }
        } elseif ($pidofExit -eq 1) {
            if (-not [string]::IsNullOrWhiteSpace($foundPids)) {
                throw "ERRORE FAIL-CLOSED: Risultato incoerente del probe quiescenza per ${PackageName}: pidof ha restituito exit code 1 ma sono presenti PID ('$foundPids'). Operazione bloccata in FAIL-CLOSED."
            }
            return @{
                Success = $true
                Pids = ""
                PidofExit = $pidofExit
                IsRunning = $false
            }
        } elseif ($pidofExit -eq 127) {
            throw "ERRORE FAIL-CLOSED: Binario o comando 'pidof' assente o non eseguibile su target device (exit: 127). Impossibile verificare lo stato dei processi per ${PackageName}."
        } else {
            throw "ERRORE FAIL-CLOSED: Invocazione pidof fallita con codice anomalo ($pidofExit) per ${PackageName}. Il fallimento del comando di controllo non puo' essere interpretato come assenza di processi."
        }
    } else {
        throw "ERRORE FAIL-CLOSED: Formato output probe quiescenza non valido per ${PackageName}: '$rawStr'. Impossibile confermare la quiescenza in modo deterministico."
    }
}

function Ensure-ApplicationQuiescence {
    param(
        [string]$AdbExe,
        [string]$TargetAdb,
        [string]$PackageName
    )
    Write-Host "      Imposizione e verifica attiva della quiescenza del writer ($PackageName)..." -ForegroundColor Yellow
    $stopRes = & $AdbExe -s $TargetAdb shell "am force-stop $PackageName" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "ERRORE FAIL-CLOSED: Invocazione am force-stop fallita con codice $LASTEXITCODE : $stopRes"
    }

    Start-Sleep -Milliseconds 300
    $state = Get-ApplicationProcessState -AdbExe $AdbExe -TargetAdb $TargetAdb -PackageName $PackageName
    if ($state.IsRunning) {
        $pids = $state.Pids
        Write-Host "      Processo ancora attivo (PID: $pids), tentativo terminazione forzata (kill -9)..." -ForegroundColor Yellow
        & $AdbExe -s $TargetAdb shell "kill -9 $pids 2>/dev/null" | Out-Null
        Start-Sleep -Milliseconds 300
        $stateRetry = Get-ApplicationProcessState -AdbExe $AdbExe -TargetAdb $TargetAdb -PackageName $PackageName
        if ($stateRetry.IsRunning) {
            $pidsRetry = $stateRetry.Pids
            throw "ERRORE FAIL-CLOSED: Impossibile arrestare il processo dell'applicazione ($PackageName, PID residuo: $pidsRetry). Writer non quiescente: estrazione database bloccata categoricamente per prevenire incoerenze o corruzione."
        }
    }
    Write-Host "      Quiescenza applicazione verificata e confermata (zero processi attivi)." -ForegroundColor Green
    return $true
}

function Probe-DeviceFileState {
    param(
        [string]$AdbExe,
        [string]$TargetAdb,
        [string]$PackageName,
        [string]$RelativePath,
        [string]$Channel = "any" # "any", "run-as", "su"
    )
    $probeCmdRunAs = "run-as $PackageName sh -c 'test -f $RelativePath && echo FILE_PROBE_RESULT:EXISTS || echo FILE_PROBE_RESULT:NOT_FOUND'"
    $probeCmdSu = "su -c 'test -f /data/data/$PackageName/$RelativePath && echo FILE_PROBE_RESULT:EXISTS || echo FILE_PROBE_RESULT:NOT_FOUND'"

    $runAsAttempted = $false
    $runAsExit = -1
    $runAsOut = ""
    if ($Channel -eq "any" -or $Channel -eq "run-as") {
        $runAsAttempted = $true
        $outRunAs = & $AdbExe -s $TargetAdb shell $probeCmdRunAs 2>&1
        $runAsExit = $LASTEXITCODE
        $runAsOut = if ($outRunAs) { $outRunAs.ToString().Trim() } else { "" }
        if ($runAsExit -eq 0 -and $runAsOut -match "FILE_PROBE_RESULT:(EXISTS|NOT_FOUND)") {
            return $Matches[1]
        }
    }

    $suAttempted = $false
    $suExit = -1
    $suOut = ""
    if ($Channel -eq "any" -or $Channel -eq "su") {
        $suAttempted = $true
        $outSu = & $AdbExe -s $TargetAdb shell $probeCmdSu 2>&1
        $suExit = $LASTEXITCODE
        $suOut = if ($outSu) { $outSu.ToString().Trim() } else { "" }
        if ($suExit -eq 0 -and $suOut -match "FILE_PROBE_RESULT:(EXISTS|NOT_FOUND)") {
            return $Matches[1]
        }
    }

    throw "ERRORE FAIL-CLOSED: Impossibile determinare lo stato del file ($RelativePath) su storage device. Probe run-as (tentato: $runAsAttempted, exit: $runAsExit, out: '$runAsOut'); Probe su (tentato: $suAttempted, exit: $suExit, out: '$suOut'). Operazione abortita per prevenire stati inconsistenti."
}

function Remove-OrphanedWalAndShmFiles {
    param(
        [string]$AdbExe,
        [string]$TargetAdb,
        [string]$PackageName
    )
    Write-Host "      Rimozione e verifica assenza file WAL/SHM orfani su storage device..." -ForegroundColor Cyan
    & $AdbExe -s $TargetAdb shell "run-as $PackageName rm -f databases/akai_memory.db-wal databases/akai_memory.db-shm" 2>$null | Out-Null
    & $AdbExe -s $TargetAdb shell "su -c 'rm -f /data/data/$PackageName/databases/akai_memory.db-wal /data/data/$PackageName/databases/akai_memory.db-shm'" 2>$null | Out-Null

    # Probing attivo tri-state su entrambi i file: solo NOT_FOUND con exit 0 e marcatore valido e' accettato
    $walState = Probe-DeviceFileState -AdbExe $AdbExe -TargetAdb $TargetAdb -PackageName $PackageName -RelativePath "databases/akai_memory.db-wal" -Channel "any"
    $shmState = Probe-DeviceFileState -AdbExe $AdbExe -TargetAdb $TargetAdb -PackageName $PackageName -RelativePath "databases/akai_memory.db-shm" -Channel "any"

    if ($walState -ne "NOT_FOUND" -or $shmState -ne "NOT_FOUND") {
        throw "ERRORE FAIL-CLOSED: Rimozione file WAL/SHM orfani fallita su device (WAL: $walState, SHM: $shmState). Ripristino abortito categoricamente in FAIL-CLOSED per prevenire corruzione dello schema."
    }
    Write-Host "      Assenza file WAL/SHM orfani confermata con successo (WAL: $walState, SHM: $shmState)." -ForegroundColor Green
    return $true
}

function Get-ApkCertificateFingerprint($apkFile) {
    if (-not (Test-Path $apkFile)) {
        throw "ERRORE FAIL-CLOSED: File APK non trovato in: $apkFile"
    }

    $out = $null
    if ($env:APKSIGNER_EXECUTABLE -and (Test-Path $env:APKSIGNER_EXECUTABLE)) {
        $out = & $env:APKSIGNER_EXECUTABLE verify --print-certs $apkFile 2>&1
    } else {
        $apksignerCli = Get-Command apksigner -ErrorAction SilentlyContinue
        if ($apksignerCli) {
            $out = & $apksignerCli.Source verify --print-certs $apkFile 2>&1
        } else {
            $signerJar = Get-ApkSignerJar
            if (-not (Test-Path $signerJar)) {
                throw "ERRORE FAIL-CLOSED: Tool apksigner.jar non trovato in: $signerJar"
            }

            $jdkDir = "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay\tools\jdk-17"
            $java = Join-Path $jdkDir "bin\java.exe"
            if (-not (Test-Path $java)) {
                $javaCmd = Get-Command java -ErrorAction SilentlyContinue
                if ($javaCmd) { $java = $javaCmd.Source }
            }
            if (-not (Test-Path $java) -and -not (Get-Command $java -ErrorAction SilentlyContinue)) {
                throw "ERRORE FAIL-CLOSED: Eseguibile java non trovato in: $java"
            }

            $out = & $java -jar $signerJar verify --print-certs $apkFile 2>&1
        }
    }
    if ($LASTEXITCODE -ne 0) {
        throw "ERRORE FAIL-CLOSED: apksigner ha fallito la verifica dell'APK ($apkFile) con codice $LASTEXITCODE : $out"
    }

    $match = $out | Select-String "Signer #1 certificate SHA-256 digest:\s*([a-fA-F0-9]{64})"
    if (-not $match) {
        throw "ERRORE FAIL-CLOSED: Impossibile estrarre un digest SHA-256 valido (64 caratteri esadecimali) da: $apkFile"
    }

    $digest = $match.Matches[0].Groups[1].Value.ToLower().Trim()
    if ($digest.Length -ne 64) {
        throw "ERRORE FAIL-CLOSED: Digest SHA-256 corrotto o incompleto ($digest) per: $apkFile"
    }

    return $digest
}

function Verify-SQLiteIntegrityOffline($dbFile) {
    if (-not (Test-Path $dbFile)) {
        throw "ERRORE FAIL-CLOSED: File database per verifica integrita' non trovato: $dbFile"
    }
    if ((Get-Item $dbFile).Length -lt 512) {
        throw "ERRORE FAIL-CLOSED: File database per verifica integrita' corrotto o inferiore a 512 byte ($((Get-Item $dbFile).Length) byte)"
    }

    $walFile = "$dbFile-wal"
    $shmFile = "$dbFile-shm"
    $verified = $false

    # 1. Prova con Node.js (se non forzato sqlite3 CLI per test)
    if (-not $env:FORCE_SQLITE3_CLI) {
        $nodePaths = @(
            $env:NODE_EXE,
            "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay\tools\nodejs\node.exe",
            (Get-Command node -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
        )
        $validNode = $nodePaths | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

        if ($validNode) {
        $dbEscaped = $dbFile.Replace('\', '/')
        $jsCheck = @"
try {
    const { DatabaseSync } = require('node:sqlite');
    const db = new DatabaseSync('$dbEscaped');

    // 1. Checkpoint categorico TRUNCATE
    let cp = null;
    try {
        cp = db.prepare('PRAGMA wal_checkpoint(TRUNCATE);').get();
    } catch (cpErr) {
        console.error('FAIL_CHECKPOINT_EXCEPTION: ' + cpErr.message);
        process.exit(3);
    }
    if (!cp || cp.busy !== 0) {
        console.error('FAIL_CHECKPOINT_BUSY: busy=' + (cp ? cp.busy : 'unknown'));
        process.exit(3);
    }

    // 2. Controllo di integrita' categorico
    const row = db.prepare('PRAGMA integrity_check;').get();
    db.close();
    if (row && row.integrity_check === 'ok') {
        process.exit(0);
    }
    console.error('FAIL_INTEGRITY: ' + (row ? row.integrity_check : 'null'));
    process.exit(1);
} catch (e) {
    console.error('FAIL_OPEN: ' + e.message);
    process.exit(2);
}
"@
        $res = & $validNode --no-warnings -e $jsCheck 2>&1
        if ($LASTEXITCODE -eq 0) {
            $verified = $true
        } elseif ($LASTEXITCODE -eq 3) {
            throw "ERRORE FAIL-CLOSED: Checkpoint WAL fallito o bloccato (busy>0) su $dbFile : $res"
        } elseif ($LASTEXITCODE -eq 1) {
            throw "ERRORE FAIL-CLOSED: Controllo di integrita' SQLite fallito (database corrotto) su $dbFile : $res"
        }
    }
    }

    # 2. Prova con Python (se non forzato sqlite3 CLI per test)
    if (-not $verified -and -not $env:FORCE_SQLITE3_CLI) {
        $pythonCmd = $null
        if ($env:PYTHON_EXE -and (Test-Path $env:PYTHON_EXE)) {
            $pythonCmd = @{ Source = $env:PYTHON_EXE }
        } else {
            $pythonCmd = Get-Command python3 -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch "WindowsApps" } | Select-Object -First 1
            if (-not $pythonCmd) { $pythonCmd = Get-Command python -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch "WindowsApps" } | Select-Object -First 1 }
        }
        if ($pythonCmd) {
            $pyCheck = "import sqlite3, sys
try:
    con = sqlite3.connect(r'$dbFile')
    cur = con.cursor()
    cur.execute('PRAGMA wal_checkpoint(TRUNCATE);')
    cp = cur.fetchone()
    if not cp or cp[0] != 0:
        b = cp[0] if cp else -1; sys.stderr.write(f'FAIL_CHECKPOINT_BUSY: busy={b}\n')
        sys.exit(3)
    res = cur.execute('PRAGMA integrity_check;').fetchone()[0]
    con.close()
    if res == 'ok':
        sys.exit(0)
    sys.stderr.write(f'FAIL_INTEGRITY: {res}\n')
    sys.exit(1)
except Exception as e:
    sys.stderr.write(f'FAIL_OPEN: {e}\n')
    sys.exit(2)"
            $res = & $pythonCmd.Source -c $pyCheck 2>&1
            if ($LASTEXITCODE -eq 0) {
                $verified = $true
            } elseif ($LASTEXITCODE -eq 3) {
                throw "ERRORE FAIL-CLOSED: Checkpoint WAL fallito o bloccato con Python su $dbFile : $res"
            } elseif ($LASTEXITCODE -eq 1) {
                throw "ERRORE FAIL-CLOSED: Controllo di integrita' SQLite fallito con Python (exit $LASTEXITCODE) su $dbFile : $res"
            }
        }
    }

    # 3. Prova con sqlite3 CLI
    if (-not $verified) {
        $sqlite3 = $null
        if ($env:SQLITE3_EXE -and (Test-Path $env:SQLITE3_EXE)) {
            $sqlite3 = @{ Source = $env:SQLITE3_EXE }
        } else {
            $sqlite3 = Get-Command sqlite3 -ErrorAction SilentlyContinue
        }
        if ($sqlite3) {
            $cpOut = & $sqlite3.Source $dbFile "PRAGMA wal_checkpoint(TRUNCATE);" 2>&1
            if ($LASTEXITCODE -ne 0 -or ($cpOut.ToString().Trim() -notmatch "^0\|")) {
                throw "ERRORE FAIL-CLOSED: Checkpoint WAL fallito o bloccato con sqlite3 su $dbFile : $cpOut"
            }
            $out = & $sqlite3.Source $dbFile "PRAGMA integrity_check;" 2>&1
            if ($LASTEXITCODE -eq 0 -and $out.ToString().Trim() -eq "ok") {
                $verified = $true
            } else {
                throw "ERRORE FAIL-CLOSED: Controllo di integrita' fallito con sqlite3 su $dbFile : $out"
            }
        }
    }

    if (-not $verified) {
        throw "ERRORE FAIL-CLOSED: Impossibile verificare l'integrita' SQLite offline. Nessun interprete idoneo disponibile (Node.js, Python o sqlite3 mancanti). Operazione interrotta per sicurezza."
    }

    # Se presente WAL post-checkpoint con dimensione 0 o residuo, verificare o rimuovere
    if (Test-Path $walFile) {
        if ((Get-Item $walFile).Length -eq 0) {
            Remove-Item $walFile -Force -ErrorAction SilentlyContinue
        } else {
            throw "ERRORE FAIL-CLOSED: Post-checkpoint TRUNCATE il file WAL ($walFile) contiene ancora $((Get-Item $walFile).Length) bytes non consolidati. Impossibile consolidare il database come single-file autonomo."
        }
    }
    if (Test-Path $shmFile) {
        Remove-Item $shmFile -Force -ErrorAction SilentlyContinue
    }

    return $true
}

switch ($Action) {
    "plan" {
        Write-Host "=== PIANO SICURO DI DEPLOYMENT, VERIFICA E ROLLBACK ATOMICO (Rev 7) ===" -ForegroundColor Cyan
        Write-Host "Fase 1: Validazione Parametri e Verifica Firma Digitale Fail-Closed Pre-Install"
        Write-Host "        - Rifiuta categoricamente artefatti CI di test non distribuibili."
        Write-Host "        - Estrae e confronta il digest SHA-256 esatto a 64 caratteri con apksigner."
        Write-Host "Fase 2: Backup Atomico Obbligatorio e Consistente (Fail-Closed)"
        Write-Host "        - Backup logico preventivo REST /api/ai/memory se server e' attivo."
        Write-Host "        - Invio ACTION_BACKUP_DB (supportato da v6+, innocuo su v5)."
        Write-Host "        - Estrazione database SQLite da snapshot o databases/akai_memory.db."
        Write-Host "        - Verifica offline PRAGMA integrity_check = ok e calcolo impronta SHA-256."
        Write-Host "        - FAIL-CLOSED: Se il backup non puo' essere estratto o non e' integro, l'installazione NON procede."
        Write-Host "Fase 3: Installazione conservativa nuovo APK (adb install -r -d, ZERO uninstall)"
        Write-Host "Fase 4: Avvio del servizio e Multi-Point Health Check Watchdog (30s):"
        Write-Host "        - Verifica 1: /api/status risponde 200 con status=ok E uinput_ready=true"
        Write-Host "        - Verifica 2: /index.html risponde 200 con frontend Web Remote"
        Write-Host "        - Verifica 3: Processo attivo su device (pidof)"
        Write-Host "Fase 5: Rollback Atomico Indivisibile (APK + DB) in caso di timeout/anomalia:"
        Write-Host "        - Reinstalla APK precedente."
        Write-Host "        - Ripristina database SQLite via streaming binario diretto in databases/."
        Write-Host "        - Pulisce preventivamente file WAL/SHM orfani."
        Write-Host "        - Verifica bit-for-bit parità hash SHA-256 e integrita' SQLite post-rollback."
        Write-Host "        - Watchdog post-rollback con verifica di ripristino."
        Write-Host "========================================================================" -ForegroundColor Cyan
    }

    "status" {
        $adb = Get-AdbExecutable
        Write-Host "=== STATO ATTUALE TELECOMANDO SU AKAI AKTV5037N ===" -ForegroundColor Cyan
        & $adb connect $TargetAdb | Out-Null
        $installed = & $adb -s $TargetAdb shell "pm list packages $PackageName"
        if ($installed -match $PackageName) {
            Write-Host "Pacchetto $PackageName : INSTALLATO" -ForegroundColor Green
            $pathLine = & $adb -s $TargetAdb shell "pm path $PackageName"
            Write-Host "Percorso APK su device  : $pathLine"
            $pidVal = (& $adb -s $TargetAdb shell "pidof $PackageName").Trim()
            Write-Host "Processo in esecuzione   : $(if ($pidVal) { "ATTIVO (PID $pidVal)" } else { "NON ATTIVO" })"
        } else {
            Write-Host "Pacchetto $PackageName : NON INSTALLATO" -ForegroundColor Yellow
        }
    }

    "backup" {
        $adb = Get-AdbExecutable
        Write-Host "=== BACKUP PREVENTIVO ATOMICO E VERIFICA INTEGRITÀ ===" -ForegroundColor Cyan
        & $adb connect $TargetAdb | Out-Null

        $sessionDir = Join-Path $BackupDir "backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null

        # 1. Download APK
        $pathOutput = & $adb -s $TargetAdb shell "pm path $PackageName"
        if ($pathOutput -notmatch "package:(.+)") {
            throw "ERRORE FAIL-CLOSED: Impossibile individuare il percorso APK su device per $PackageName."
        }
        $remoteApk = $matches[1].Trim()
        $backupApk = Join-Path $sessionDir "it.akai.customremote_backup.apk"
        Write-Host "[1/3] Download APK remoto da $remoteApk..."
        & $adb -s $TargetAdb pull $remoteApk $backupApk
        if (-not (Test-Path $backupApk) -or (Get-Item $backupApk).Length -eq 0) {
            throw "ERRORE FAIL-CLOSED: Download APK di backup fallito o file vuoto."
        }
        Write-Host "      APK salvato: $backupApk ($((Get-Item $backupApk).Length) bytes)" -ForegroundColor Green

        # 2. Snapshot logico preventivo REST (se server HTTP e' online)
        $logicalBackupPath = Join-Path $sessionDir "akai_memory_logical_backup.json"
        try {
            $headers = @{}
            if ($AuthToken) { $headers["Authorization"] = "Bearer $AuthToken" }
            $memResp = Invoke-RestMethod -Uri $MemoryUrl -Method Get -Headers $headers -TimeoutSec 4 -ErrorAction Stop
            $memJson = $memResp | ConvertTo-Json -Depth 10
            [System.IO.File]::WriteAllText($logicalBackupPath, $memJson, [System.Text.Encoding]::UTF8)
            Write-Host "      Snapshot logico parziale REST salvato: $logicalBackupPath (cronologia/preferenze)" -ForegroundColor Green
        } catch {
            Write-Host "      Endpoint REST non raggiungibile o autenticazione 401 richiesta ($($_.Exception.Message)) - continuo con snapshot binario..." -ForegroundColor Yellow
        }

        # 3. Snapshot consistente SQLite
        $backupDb = Join-Path $sessionDir "akai_memory.db"
        $backupDbWal = Join-Path $sessionDir "akai_memory.db-wal"
        Write-Host "[2/3] Arresto writer app e tentativo snapshot consistente (se v6+)..."
        & $adb -s $TargetAdb shell "am force-stop $PackageName" 2>$null | Out-Null
        & $adb -s $TargetAdb shell "am startservice -a it.akai.customremote.ACTION_BACKUP_DB $PackageName/.RemoteServerService" 2>$null | Out-Null
        Start-Sleep -Seconds 1

        Write-Host "[3/3] Estrazione database SQLite e gestione file WAL..."
        $extracted = $false

        # Tentativo A: snapshot via run-as
        $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "run-as $PackageName cat files/akai_memory_snapshot.db" -LocalFilePath $backupDb
        if ($rx.Success) { $extracted = $true }

        # Tentativo B: snapshot via su
        if (-not $extracted) {
            $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "su -c 'cat /data/data/$PackageName/files/akai_memory_snapshot.db'" -LocalFilePath $backupDb
            if ($rx.Success) { $extracted = $true }
        }

        # Se snapshot v6 non presente, applica quiescenza verificata per estrazione baseline v5
        if (-not $extracted) {
            Ensure-ApplicationQuiescence -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName
        }

        # Tentativo C: database primario + WAL via run-as (baseline v5 con probing attivo WAL)
        if (-not $extracted) {
            $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "run-as $PackageName cat databases/akai_memory.db" -LocalFilePath $backupDb
            if ($rx.Success) {
                $walProbe = Probe-DeviceFileState -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName -RelativePath "databases/akai_memory.db-wal" -Channel "run-as"
                if ($walProbe -eq "EXISTS") {
                    Write-Host "      File WAL presente su device (run-as): estrazione obbligatoria (fail-closed)..." -ForegroundColor Cyan
                    $rxWal = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "run-as $PackageName cat databases/akai_memory.db-wal" -LocalFilePath $backupDbWal
                    if (-not $rxWal.Success -or -not (Test-Path $backupDbWal) -or (Get-Item $backupDbWal).Length -lt 32) {
                        throw "ERRORE FAIL-CLOSED: File WAL (akai_memory.db-wal) presente su storage device ma estrazione fallita o non leggibile via run-as."
                    }
                    Write-Host "      File WAL estratto con successo: $backupDbWal ($((Get-Item $backupDbWal).Length) bytes)" -ForegroundColor Green
                } elseif ($walProbe -eq "NOT_FOUND") {
                    Write-Host "      Verifica presenza WAL su storage device: ASSENTE (stato consistente single-file)." -ForegroundColor Green
                    if (Test-Path $backupDbWal) { Remove-Item $backupDbWal -Force -ErrorAction SilentlyContinue }
                }
                $extracted = $true
            }
        }

        # Tentativo D: database primario + WAL via su (baseline v5 con probing attivo WAL)
        if (-not $extracted) {
            $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "su -c 'cat /data/data/$PackageName/databases/akai_memory.db'" -LocalFilePath $backupDb
            if ($rx.Success) {
                $walProbe = Probe-DeviceFileState -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName -RelativePath "databases/akai_memory.db-wal" -Channel "su"
                if ($walProbe -eq "EXISTS") {
                    Write-Host "      File WAL presente su device (su): estrazione obbligatoria (fail-closed)..." -ForegroundColor Cyan
                    $rxWal = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "su -c 'cat /data/data/$PackageName/databases/akai_memory.db-wal'" -LocalFilePath $backupDbWal
                    if (-not $rxWal.Success -or -not (Test-Path $backupDbWal) -or (Get-Item $backupDbWal).Length -lt 32) {
                        throw "ERRORE FAIL-CLOSED: File WAL (akai_memory.db-wal) presente su storage device ma estrazione fallita o non leggibile via su."
                    }
                    Write-Host "      File WAL estratto con successo: $backupDbWal ($((Get-Item $backupDbWal).Length) bytes)" -ForegroundColor Green
                } elseif ($walProbe -eq "NOT_FOUND") {
                    Write-Host "      Verifica presenza WAL su storage device: ASSENTE (stato consistente single-file)." -ForegroundColor Green
                    if (Test-Path $backupDbWal) { Remove-Item $backupDbWal -Force -ErrorAction SilentlyContinue }
                }
                $extracted = $true
            }
        }

        if (-not $extracted -or -not (Test-Path $backupDb) -or (Get-Item $backupDb).Length -lt 512) {
            throw "ERRORE FAIL-CLOSED: Estrazione del database fallita (permessi negati o file non accessibile)."
        }

        # Pulizia WAL vuoto
        if (Test-Path $backupDbWal) {
            if ((Get-Item $backupDbWal).Length -lt 32) {
                Remove-Item $backupDbWal -Force -ErrorAction SilentlyContinue
            } else {
                Write-Host "      File WAL rilevato ($((Get-Item $backupDbWal).Length) bytes) - applicazione checkpoint offline..." -ForegroundColor Cyan
            }
        }

        Verify-SQLiteIntegrityOffline $backupDb | Out-Null
        $dbHash = Get-Sha256Hex $backupDb
        Write-Host "      Database SQLite consolidato e verificato integro: $backupDb ($((Get-Item $backupDb).Length) bytes, SHA-256=$dbHash)" -ForegroundColor Green
        Write-Host "Sessione di backup completata in: $sessionDir" -ForegroundColor Green
    }

    "install" {
        $adb = Get-AdbExecutable
        Write-Host "=== INSTALLAZIONE PROTETTA CON VERIFICA FIRME FAIL-CLOSED E WATCHDOG (30s) ===" -ForegroundColor Cyan

        & $adb connect $TargetAdb | Out-Null
        $sessionDir = Join-Path $BackupDir "backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null

        # 1. Verifica se l'app è già installata
        $pathOutput = & $adb -s $TargetAdb shell "pm path $PackageName"
        $hasPrevious = $false
        $backupApk = Join-Path $sessionDir "it.akai.customremote_backup.apk"
        $backupDb = Join-Path $sessionDir "akai_memory.db"
        $backupDbHash = $null

        if ($pathOutput -match "package:(.+)") {
            $hasPrevious = $true
            $remoteApk = $matches[1].Trim()

            # 1.1 Backup obbligatorio APK
            Write-Host "[1/6] Esecuzione backup preventivo dell'APK installato..."
            & $adb -s $TargetAdb pull $remoteApk $backupApk | Out-Null
            if (-not (Test-Path $backupApk) -or (Get-Item $backupApk).Length -eq 0) {
                throw "ERRORE FAIL-CLOSED: Impossibile completare il backup dell'APK esistente."
            }
            Write-Host "      Backup APK salvato: $backupApk ($((Get-Item $backupApk).Length) bytes)" -ForegroundColor Green

            # 1.2 Backup logico preventivo REST (se server e' attivo)
            $logicalBackupPath = Join-Path $sessionDir "akai_memory_logical_backup.json"
            try {
                $headers = @{}
            if ($AuthToken) { $headers["Authorization"] = "Bearer $AuthToken" }
            $memResp = Invoke-RestMethod -Uri $MemoryUrl -Method Get -Headers $headers -TimeoutSec 4 -ErrorAction Stop
                $memJson = $memResp | ConvertTo-Json -Depth 10
                [System.IO.File]::WriteAllText($logicalBackupPath, $memJson, [System.Text.Encoding]::UTF8)
                Write-Host "      Snapshot logico parziale REST salvato: $logicalBackupPath (cronologia/preferenze)" -ForegroundColor Green
            } catch {
                Write-Host "      Endpoint REST non raggiungibile o autenticazione 401 richiesta ($($_.Exception.Message)) - continuo con snapshot binario..." -ForegroundColor Yellow
            }

            # 1.3 Backup OBBLIGATORIO del database SQLite (FAIL-CLOSED) con WAL
            Write-Host "[2/6] Backup preventivo OBBLIGATORIO del database SQLite e gestione WAL..."
            $backupDbWal = Join-Path $sessionDir "akai_memory.db-wal"
            & $adb -s $TargetAdb shell "am force-stop $PackageName" 2>$null | Out-Null
            & $adb -s $TargetAdb shell "am startservice -a it.akai.customremote.ACTION_BACKUP_DB $PackageName/.RemoteServerService" 2>$null | Out-Null
            Start-Sleep -Seconds 1

            $dbExtracted = $false
            # Tentativo A: snapshot via run-as
            $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "run-as $PackageName cat files/akai_memory_snapshot.db" -LocalFilePath $backupDb
            if ($rx.Success) { $dbExtracted = $true }

            # Tentativo B: snapshot via su
            if (-not $dbExtracted) {
                $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "su -c 'cat /data/data/$PackageName/files/akai_memory_snapshot.db'" -LocalFilePath $backupDb
                if ($rx.Success) { $dbExtracted = $true }
            }

            # Se snapshot v6 non presente, applica quiescenza verificata per estrazione baseline v5
            if (-not $dbExtracted) {
                Ensure-ApplicationQuiescence -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName
            }

            # Tentativo C: database primario + WAL via run-as (baseline v5 con probing attivo WAL)
            if (-not $dbExtracted) {
                $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "run-as $PackageName cat databases/akai_memory.db" -LocalFilePath $backupDb
                if ($rx.Success) {
                    $walProbe = Probe-DeviceFileState -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName -RelativePath "databases/akai_memory.db-wal" -Channel "run-as"
                    if ($walProbe -eq "EXISTS") {
                        Write-Host "      File WAL presente su device (run-as): estrazione obbligatoria (fail-closed)..." -ForegroundColor Cyan
                        $rxWal = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "run-as $PackageName cat databases/akai_memory.db-wal" -LocalFilePath $backupDbWal
                        if (-not $rxWal.Success -or -not (Test-Path $backupDbWal) -or (Get-Item $backupDbWal).Length -lt 32) {
                            throw "ERRORE FAIL-CLOSED: File WAL (akai_memory.db-wal) presente su storage device ma estrazione fallita o non leggibile via run-as."
                        }
                        Write-Host "      File WAL estratto con successo: $backupDbWal ($((Get-Item $backupDbWal).Length) bytes)" -ForegroundColor Green
                    } elseif ($walProbe -eq "NOT_FOUND") {
                        Write-Host "      Verifica presenza WAL su storage device: ASSENTE (stato consistente single-file)." -ForegroundColor Green
                        if (Test-Path $backupDbWal) { Remove-Item $backupDbWal -Force -ErrorAction SilentlyContinue }
                    }
                    $dbExtracted = $true
                }
            }

            # Tentativo D: database primario + WAL via su (baseline v5 con probing attivo WAL)
            if (-not $dbExtracted) {
                $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "su -c 'cat /data/data/$PackageName/databases/akai_memory.db'" -LocalFilePath $backupDb
                if ($rx.Success) {
                    $walProbe = Probe-DeviceFileState -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName -RelativePath "databases/akai_memory.db-wal" -Channel "su"
                    if ($walProbe -eq "EXISTS") {
                        Write-Host "      File WAL presente su device (su): estrazione obbligatoria (fail-closed)..." -ForegroundColor Cyan
                        $rxWal = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "su -c 'cat /data/data/$PackageName/databases/akai_memory.db-wal'" -LocalFilePath $backupDbWal
                        if (-not $rxWal.Success -or -not (Test-Path $backupDbWal) -or (Get-Item $backupDbWal).Length -lt 32) {
                            throw "ERRORE FAIL-CLOSED: File WAL (akai_memory.db-wal) presente su storage device ma estrazione fallita o non leggibile via su."
                        }
                        Write-Host "      File WAL estratto con successo: $backupDbWal ($((Get-Item $backupDbWal).Length) bytes)" -ForegroundColor Green
                    } elseif ($walProbe -eq "NOT_FOUND") {
                        Write-Host "      Verifica presenza WAL su storage device: ASSENTE (stato consistente single-file)." -ForegroundColor Green
                        if (Test-Path $backupDbWal) { Remove-Item $backupDbWal -Force -ErrorAction SilentlyContinue }
                    }
                    $dbExtracted = $true
                }
            }

            # VERIFICA FAIL-CLOSED CATEGORICA
            if (-not $dbExtracted -or -not (Test-Path $backupDb) -or (Get-Item $backupDb).Length -lt 512) {
                throw "ERRORE FAIL-CLOSED: Impossibile estrarre un backup integro del database dal dispositivo (permessi negati run-as/su o database non accessibile). L'installazione e' categoricamente INTERROTTA per prevenire perdite irrecuperabili di dati."
            }

            # Pulizia WAL vuoto se presente
            if (Test-Path $backupDbWal) {
                if ((Get-Item $backupDbWal).Length -lt 32) {
                    Remove-Item $backupDbWal -Force -ErrorAction SilentlyContinue
                } else {
                    Write-Host "      File WAL rilevato ($((Get-Item $backupDbWal).Length) bytes) - applicazione checkpoint offline..." -ForegroundColor Cyan
                }
            }

            Verify-SQLiteIntegrityOffline $backupDb | Out-Null
            $backupDbHash = Get-Sha256Hex $backupDb
            Write-Host "      Database SQLite consolidato e integro: $backupDb ($((Get-Item $backupDb).Length) bytes, SHA-256=$backupDbHash)" -ForegroundColor Green

            # 2. Verifica compatibilità firme FAIL-CLOSED
            Write-Host "[3/6] Verifica compatibilità certificato firma (FAIL-CLOSED)..."
            $backupFp = Get-ApkCertificateFingerprint $backupApk
            $candidateFp = Get-ApkCertificateFingerprint $ApkPath
            Write-Host "      Certificato installato : $backupFp"
            Write-Host "      Certificato candidato   : $candidateFp"

            if ([string]::IsNullOrWhiteSpace($backupFp) -or [string]::IsNullOrWhiteSpace($candidateFp)) {
                throw "BLOCCO FAIL-CLOSED: Impronta SHA-256 non estraibile."
            }
            if ($backupFp.Length -ne 64 -or $candidateFp.Length -ne 64) {
                throw "BLOCCO FAIL-CLOSED: Impronta digest non conforme a SHA-256 (64 hex)."
            }
            if ($backupFp -ne $candidateFp) {
                throw "BLOCCO FAIL-CLOSED: FIRMA INCOMPATIBILE! Il certificato dell'APK candidato non corrisponde alla TV. L'installazione comporterebbe INSTALL_FAILED_UPDATE_INCOMPATIBLE."
            }
            Write-Host "      Compatibilità firma SHA-256 verificata con successo al 100%." -ForegroundColor Green
        } else {
            Write-Host "[1/6] Nessun APK precedente installato sulla TV; skip backup e check firme." -ForegroundColor Yellow
        }

        # 3. Installazione conservativa (mai uninstall, preserva /data/data)
        Write-Host "[4/6] Installazione nuovo APK (adb install -r -d)..."
        $installRes = & $adb -s $TargetAdb install -r -d $ApkPath
        Write-Host "      Esito adb: $installRes"
        if ($LASTEXITCODE -ne 0 -or $installRes -notmatch "Success") {
            throw "ERRORE FAIL-CLOSED: Installazione fallita da adb (exit=$LASTEXITCODE): $installRes"
        }

        # 4. Avvio servizio
        Write-Host "[5/6] Avvio servizio RemoteServerService..."
        & $adb -s $TargetAdb shell "am startservice $PackageName/.RemoteServerService" | Out-Null

        # 5. Multi-Point Health Check Watchdog (30s)
        Write-Host "[6/6] Multi-Point Health Check Watchdog attivo (timeout 30s)..."
        $healthy = $false
        $attempts = $(if ($env:WATCHDOG_ATTEMPTS) { [int]$env:WATCHDOG_ATTEMPTS } else { 6 })
        $sleepSec = $(if ($env:WATCHDOG_SLEEP_SEC) { [int]$env:WATCHDOG_SLEEP_SEC } else { 5 })
        for ($i = 1; $i -le $attempts; $i++) {
            Start-Sleep -Seconds $sleepSec
            try {
                $statusResp = Invoke-RestMethod -Uri $StatusUrl -Method Get -TimeoutSec 4 -ErrorAction Stop
                $webResp = Invoke-WebRequest -Uri $WebUrl -Method Get -TimeoutSec 4 -UseBasicParsing -ErrorAction Stop
                $pidVal = (& $adb -s $TargetAdb shell "pidof $PackageName").Trim()

                if ($statusResp.status -eq "ok" -and $statusResp.uinput_ready -eq $true -and $webResp.StatusCode -eq 200 -and $pidVal) {
                    $healthy = $true
                    Write-Host "      Tentativo $i/$($attempts) SUPERATO:" -ForegroundColor Green
                    Write-Host "      - API Status    : OK (uinput_ready=true, active_sessions=$($statusResp.active_sessions))" -ForegroundColor Green
                    Write-Host "      - Web Remote UI : OK (HTTP 200, $($webResp.RawContentLength) bytes)" -ForegroundColor Green
                    Write-Host "      - Processo TV   : ATTIVO (PID $pidVal)" -ForegroundColor Green
                    break
                }
            } catch {
                Write-Host "      Tentativo $i/$($attempts) - Inizializzazione in corso ($($_.Exception.Message))..." -ForegroundColor Yellow
            }
        }

        if ($healthy) {
            Write-Host "`nDEPLOYMENT VERIFICATO CON SUCCESSO AL 100%! Tutti i componenti operativi." -ForegroundColor Green
        } else {
            Write-Host "`nALLARME: Health check fallito entro 30s! Avvio ROLLBACK ATOMICO INDIVISIBILE (APK + DB)..." -ForegroundColor Red
            if ($hasPrevious) {
                # VALIDAZIONE PREREQUISITI RIGOROSA PRE-ROLLBACK (P0-2 FAIL-CLOSED)
                if (-not (Test-Path $backupApk) -or (Get-Item $backupApk).Length -eq 0) {
                    throw "ERRORE FAIL-CLOSED FATALE: Impossibile eseguire il rollback. File APK precedente mancante ($backupApk)."
                }
                if (-not (Test-Path $backupDb) -or (Get-Item $backupDb).Length -lt 512) {
                    throw "ERRORE FAIL-CLOSED FATALE: Impossibile procedere al rollback automatico dell'APK senza backup del database SQLite v5 ($backupDb). La baseline v5 non supporta lo schema v6; reinstallare l'APK senza DB causerebbe crash irreversibile dell'app. Rollback interrotto in FAIL-CLOSED."
                }
                if (-not $backupDbHash) {
                    throw "ERRORE FAIL-CLOSED FATALE: Hash SHA-256 del backup SQLite v5 assente. Impossibile garantire integrita' bit-for-bit del ripristino."
                }

                Write-Host "[ROLLBACK 1/4] Reinstallazione APK precedente (adb install -r -d)..."
                $rbRes = & $adb -s $TargetAdb install -r -d $backupApk
                Write-Host "      Esito adb install rollback: $rbRes"
                if ($LASTEXITCODE -ne 0 -or $rbRes -notmatch "Success") {
                    throw "FATALE: Reinstallazione rollback APK fallita!"
                }

                Write-Host "[ROLLBACK 2/4] Ripristino database SQLite originale..."
                # 1. Arresto forzato dell'app per rilasciare lock sul file
                & $adb -s $TargetAdb shell "am force-stop $PackageName" | Out-Null

                # 2. Rimozione e verifica assenza file WAL e SHM orfani
                Remove-OrphanedWalAndShmFiles -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName

                # Risoluzione UID numerico Android per chown
                $appUid = $null
                $uidRaw = & $adb -s $TargetAdb shell "dumpsys package $PackageName | grep -E 'userId=|appId='" 2>$null
                $uidOut = if ($uidRaw) { $uidRaw.ToString().Trim() } else { "" }
                if ($uidOut -match "userId=(\d+)") { $appUid = $matches[1] }
                elseif ($uidOut -match "appId=(\d+)") { $appUid = $matches[1] }
                else {
                    $statRaw = & $adb -s $TargetAdb shell "stat -c '%u' /data/data/$PackageName" 2>$null
                    $statOut = if ($statRaw) { $statRaw.ToString().Trim() } else { "" }
                    if ($statOut -match "^\d+$") { $appUid = $statOut }
                }
                if ([string]::IsNullOrWhiteSpace($appUid) -or ($appUid -notmatch "^\d+$")) {
    throw "ERRORE FAIL-CLOSED: Impossibile risolvere con certezza l'identita' numerica UID Linux dell'applicazione ($PackageName) via dumpsys o stat. Applicazione permessi con UID arbitrario (es. 10000) categoricamente VIETATA per sicurezza."
}
$chownTarget = "${appUid}:${appUid}"

                # 3. Streaming diretto del backup binario in databases/akai_memory.db tramite pipe universale
                $restored = $false
                $streamRes = Send-FileViaAdbExecIn -AdbExe $adb -TargetAdb $TargetAdb -LocalFilePath $backupDb -RemoteCommand "run-as $PackageName sh -c 'mkdir -p databases; cat > databases/akai_memory.db; chmod 660 databases/akai_memory.db'"
                if ($streamRes.Success) {
                    $restored = $true
                } else {
                    $streamRes = Send-FileViaAdbExecIn -AdbExe $adb -TargetAdb $TargetAdb -LocalFilePath $backupDb -RemoteCommand "su -c 'mkdir -p /data/data/$PackageName/databases; cat > /data/data/$PackageName/databases/akai_memory.db; chown -R $chownTarget /data/data/$PackageName/databases; chmod 660 /data/data/$PackageName/databases/akai_memory.db'"
                    if ($streamRes.Success) { $restored = $true }
                }

                if (-not $restored) {
                    throw "ERRORE FAIL-CLOSED: Impossibile effettuare lo streaming del database ripristinato sul dispositivo (exit=$($streamRes.ExitCode), out=$($streamRes.Output))."
                }

                # 4. Verifica parità hash SHA-256 e integrità SQLite post-ripristino
                $verifyRestoreDb = Join-Path $sessionDir "verify_restore.db"
                $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "run-as $PackageName cat databases/akai_memory.db" -LocalFilePath $verifyRestoreDb
                if (-not $rx.Success) {
                    $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "su -c 'cat /data/data/$PackageName/databases/akai_memory.db'" -LocalFilePath $verifyRestoreDb
                }

                if (-not (Test-Path $verifyRestoreDb) -or (Get-Item $verifyRestoreDb).Length -lt 512) {
                    throw "ERRORE FAIL-CLOSED: Verifica post-rollback fallita: impossibile rileggere il database ripristinato dal dispositivo per validarne l'integrita'."
                }
                Verify-SQLiteIntegrityOffline $verifyRestoreDb | Out-Null
                $restHash = Get-Sha256Hex $verifyRestoreDb
                if ($restHash -ne $backupDbHash) {
                    throw "ERRORE FAIL-CLOSED: Mismatch hash SHA-256 post-ripristino! Orig: $backupDbHash, Device: $restHash"
                }
                Write-Host "      Parita' hash SHA-256 ($restHash) e integrita' SQLite post-rollback verificate con successo." -ForegroundColor Green

                Write-Host "      Database SQLite v5 ripristinato con successo." -ForegroundColor Green

                Write-Host "[ROLLBACK 3/4] Riavvio servizio RemoteServerService..."
                & $adb -s $TargetAdb shell "am startservice $PackageName/.RemoteServerService" | Out-Null

                Write-Host "[ROLLBACK 4/4] Verifica post-rollback dello stato di salute..."
                $rbHealthy = $false
                for ($r = 1; $r -le 3; $r++) {
                    Start-Sleep -Seconds 2
                    try {
                        $rbStatus = Invoke-RestMethod -Uri $StatusUrl -Method Get -TimeoutSec 4 -ErrorAction Stop
                        if ($rbStatus.status -eq "ok") {
                            $rbHealthy = $true
                            break
                        }
                    } catch {
                        Write-Host "      Controllo post-rollback $r/3: in avvio ($($_.Exception.Message))..." -ForegroundColor Yellow
                    }
                }

                if ($rbHealthy) {
                    Write-Host "ROLLBACK RIUSCITO E VERIFICATO: Sistema TV tornato operativo al 100% sulla versione precedente." -ForegroundColor Green
                } else {
                    Write-Host "ALLARME POST-ROLLBACK: Health check post-rollback fallito - STATO CRITICO FAIL/UNKNOWN." -ForegroundColor Red
                    throw "ERRORE FAIL-CLOSED: Watchdog post-rollback non superato. Il servizio non risponde con status=ok."
                }
            } else {
                Write-Host "Nessun APK precedente disponibile per il ripristino." -ForegroundColor Red
            }
            exit 1
        }
    }

    "rollback" {
        $adb = Get-AdbExecutable
        Write-Host "=== ROLLBACK MANUALE ALLA VERSIONE PRECEDENTE CON VERIFICA ===" -ForegroundColor Yellow
        $latestSession = Get-ChildItem -Path $BackupDir -Directory | Sort-Object CreationTime -Descending | Select-Object -First 1
        if (-not $latestSession) {
            throw "ERRORE FAIL-CLOSED: Nessuna sessione di backup trovata in $BackupDir."
        }
        $backupApk = Join-Path $latestSession.FullName "it.akai.customremote_backup.apk"
        $backupDb = Join-Path $latestSession.FullName "akai_memory.db"

        # VALIDAZIONE PREREQUISITI RIGOROSA PRE-ROLLBACK (P0-2 FAIL-CLOSED)
        if (-not (Test-Path $backupApk) -or (Get-Item $backupApk).Length -eq 0) {
            throw "ERRORE FAIL-CLOSED: File di backup APK non trovato in $backupApk."
        }
        if (-not (Test-Path $backupDb) -or (Get-Item $backupDb).Length -lt 512) {
            throw "ERRORE FAIL-CLOSED: Prerequisito critico mancante per il rollback manuale. File database di backup mancante o non integro in $backupDb. Impossibile procedere al downgrade dell'APK senza ripristino DB (rischio crash per schema v6 non supportato da v5)."
        }

        Verify-SQLiteIntegrityOffline $backupDb | Out-Null
        $backupDbHash = Get-Sha256Hex $backupDb

        Write-Host "[1/4] Reinstallazione APK precedente da sessione: $($latestSession.Name)..."
        $res = & $adb -s $TargetAdb install -r -d $backupApk
        Write-Host "      Esito adb: $res"
        if ($LASTEXITCODE -ne 0 -or $res -notmatch "Success") {
            throw "ERRORE FAIL-CLOSED: Rollback fallito: adb non e' riuscito a reinstallare l'APK ($res)"
        }

        Write-Host "[2/4] Ripristino database SQLite originale..."
        & $adb -s $TargetAdb shell "am force-stop $PackageName" | Out-Null

        # Rimozione e verifica assenza file WAL/SHM orfani
        Remove-OrphanedWalAndShmFiles -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName

        # Risoluzione UID numerico Android per chown
        $appUid = $null
        $uidRaw = & $adb -s $TargetAdb shell "dumpsys package $PackageName | grep -E 'userId=|appId='" 2>$null
        $uidOut = if ($uidRaw) { $uidRaw.ToString().Trim() } else { "" }
        if ($uidOut -match "userId=(\d+)") { $appUid = $matches[1] }
        elseif ($uidOut -match "appId=(\d+)") { $appUid = $matches[1] }
        else {
            $statRaw = & $adb -s $TargetAdb shell "stat -c '%u' /data/data/$PackageName" 2>$null
            $statOut = if ($statRaw) { $statRaw.ToString().Trim() } else { "" }
            if ($statOut -match "^\d+$") { $appUid = $statOut }
        }
        if ([string]::IsNullOrWhiteSpace($appUid) -or ($appUid -notmatch "^\d+$")) {
    throw "ERRORE FAIL-CLOSED: Impossibile risolvere con certezza l'identita' numerica UID Linux dell'applicazione ($PackageName) via dumpsys o stat. Applicazione permessi con UID arbitrario (es. 10000) categoricamente VIETATA per sicurezza."
}
$chownTarget = "${appUid}:${appUid}"

        $restored = $false
        $streamRes = Send-FileViaAdbExecIn -AdbExe $adb -TargetAdb $TargetAdb -LocalFilePath $backupDb -RemoteCommand "run-as $PackageName sh -c 'mkdir -p databases; cat > databases/akai_memory.db; chmod 660 databases/akai_memory.db'"
        if ($streamRes.Success) {
            $restored = $true
        } else {
            $streamRes = Send-FileViaAdbExecIn -AdbExe $adb -TargetAdb $TargetAdb -LocalFilePath $backupDb -RemoteCommand "su -c 'mkdir -p /data/data/$PackageName/databases; cat > /data/data/$PackageName/databases/akai_memory.db; chown -R $chownTarget /data/data/$PackageName/databases; chmod 660 /data/data/$PackageName/databases/akai_memory.db'"
            if ($streamRes.Success) { $restored = $true }
        }

        if (-not $restored) {
            throw "ERRORE FAIL-CLOSED: Impossibile effettuare lo streaming del database ripristinato sul dispositivo."
        }

        # Verifica integrità post-ripristino
        $verifyRestoreDb = Join-Path $latestSession.FullName "verify_manual_restore.db"
        $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "run-as $PackageName cat databases/akai_memory.db" -LocalFilePath $verifyRestoreDb
        if (-not $rx.Success) {
            $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "su -c 'cat /data/data/$PackageName/databases/akai_memory.db'" -LocalFilePath $verifyRestoreDb
        }
        if (-not (Test-Path $verifyRestoreDb) -or (Get-Item $verifyRestoreDb).Length -lt 512) {
            throw "ERRORE FAIL-CLOSED: Verifica post-rollback fallita: impossibile rileggere il database ripristinato dal dispositivo ($($rx.Output))."
        }
        Verify-SQLiteIntegrityOffline $verifyRestoreDb | Out-Null
        $restHash = Get-Sha256Hex $verifyRestoreDb
        if ($backupDbHash -ne $restHash) {
            throw "ERRORE FAIL-CLOSED: Mismatch hash SHA-256 post-ripristino! Orig: $backupDbHash, Device: $restHash"
        }
        Write-Host "      Parita' hash SHA-256 ($backupDbHash) e integrita' SQLite verificate con successo." -ForegroundColor Green

        Write-Host "      Database SQLite ripristinato." -ForegroundColor Green

        Write-Host "[3/4] Riavvio servizio RemoteServerService..."
        & $adb -s $TargetAdb shell "am startservice $PackageName/.RemoteServerService" | Out-Null

        Write-Host "[4/4] Watchdog post-rollback..."
        $rbHealthy = $false
        for ($r = 1; $r -le 3; $r++) {
            Start-Sleep -Seconds 2
            try {
                $statusResp = Invoke-RestMethod -Uri $StatusUrl -Method Get -TimeoutSec 4 -ErrorAction Stop
                if ($statusResp.status -eq "ok") {
                    $rbHealthy = $true
                    break
                }
            } catch {
                Write-Host "      Controllo post-rollback $r/3: in avvio ($($_.Exception.Message))..." -ForegroundColor Yellow
            }
        }
        if ($rbHealthy) {
            Write-Host "Rollback manuale completato e verificato con successo: TV operativa!" -ForegroundColor Green
        } else {
            Write-Host "ALLARME POST-ROLLBACK: Endpoint status non raggiungibile o non operativo - STATO CRITICO FAIL/UNKNOWN." -ForegroundColor Red
            throw "ERRORE FAIL-CLOSED: Watchdog post-rollback non superato. Il servizio non risponde con status=ok."
        }
    }
}
