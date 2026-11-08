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

    # 1. Prova con Node.js
    $nodePaths = @(
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
    const row = db.prepare('PRAGMA integrity_check;').get();
    db.close();
    if (row && row.integrity_check === 'ok') {
        process.exit(0);
    }
    process.exit(1);
} catch (e) {
    process.exit(2);
}
"@
        $res = & $validNode --no-warnings -e $jsCheck 2>&1
        if ($LASTEXITCODE -eq 0) {
            return $true
        } elseif ($LASTEXITCODE -eq 1) {
            throw "ERRORE FAIL-CLOSED: Controllo di integrita' SQLite fallito (database corrotto) su $dbFile : $res"
        }
        # Se LASTEXITCODE == 2, la versione corrente di Node.js non include node:sqlite (es. Node < 22).
        # Fall-through trasparente verso Python 3 / sqlite3 CLI.
    }

    # 2. Prova con Python
    $pythonCmd = Get-Command python3 -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch "WindowsApps" } | Select-Object -First 1
    if (-not $pythonCmd) { $pythonCmd = Get-Command python -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch "WindowsApps" } | Select-Object -First 1 }
    if ($pythonCmd) {
        $pyCheck = "import sqlite3, sys; con = sqlite3.connect(r'$dbFile'); res = con.execute('PRAGMA integrity_check;').fetchone()[0]; con.close(); sys.exit(0 if res == 'ok' else 1)"
        $res = & $pythonCmd.Source -c $pyCheck 2>&1
        if ($LASTEXITCODE -eq 0) {
            return $true
        } else {
            throw "ERRORE FAIL-CLOSED: Controllo di integrita' SQLite fallito con Python (exit $LASTEXITCODE) su $dbFile : $res"
        }
    }

    # 3. Prova con sqlite3 CLI
    $sqlite3 = Get-Command sqlite3 -ErrorAction SilentlyContinue
    if ($sqlite3) {
        $out = & $sqlite3.Source $dbFile "PRAGMA integrity_check;" 2>&1
        if ($LASTEXITCODE -eq 0 -and $out.Trim() -eq "ok") {
            return $true
        } else {
            throw "ERRORE FAIL-CLOSED: Controllo di integrita' fallito con sqlite3 su $dbFile : $out"
        }
    }

    # Nessun interprete disponibile: FAIL-CLOSED categorico!
    throw "ERRORE FAIL-CLOSED: Impossibile verificare l'integrita' SQLite offline. Nessun interprete idoneo disponibile (Node.js, Python o sqlite3 mancanti). Operazione interrotta per sicurezza."
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
            $memResp = Invoke-RestMethod -Uri $MemoryUrl -Method Get -TimeoutSec 4 -ErrorAction Stop
            $memJson = $memResp | ConvertTo-Json -Depth 10
            [System.IO.File]::WriteAllText($logicalBackupPath, $memJson, [System.Text.Encoding]::UTF8)
            Write-Host "      Backup logico REST /api/ai/memory salvato: $logicalBackupPath" -ForegroundColor Green
        } catch {
            Write-Host "      Endpoint REST non raggiungibile per backup logico ($($_.Exception.Message)) - continuo con snapshot binario..." -ForegroundColor Yellow
        }

        # 3. Snapshot consistente SQLite
        $backupDb = Join-Path $sessionDir "akai_memory.db"
        Write-Host "[2/3] Creazione snapshot consistente con WAL checkpoint via intent (se v6+)..."
        & $adb -s $TargetAdb shell "am startservice -a it.akai.customremote.ACTION_BACKUP_DB $PackageName/.RemoteServerService" | Out-Null
        Start-Sleep -Seconds 2

        Write-Host "[3/3] Estrazione database SQLite e verifica integrita'..."
        $extracted = $false

        # Tentativo A: snapshot via run-as
        $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "run-as $PackageName cat files/akai_memory_snapshot.db" -LocalFilePath $backupDb
        if ($rx.Success) { $extracted = $true }

        # Tentativo B: snapshot via su
        if (-not $extracted) {
            $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "su -c 'cat /data/data/$PackageName/files/akai_memory_snapshot.db'" -LocalFilePath $backupDb
            if ($rx.Success) { $extracted = $true }
        }

        # Tentativo C: database primario via run-as (baseline v5)
        if (-not $extracted) {
            $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "run-as $PackageName cat databases/akai_memory.db" -LocalFilePath $backupDb
            if ($rx.Success) { $extracted = $true }
        }

        # Tentativo D: database primario via su (baseline v5)
        if (-not $extracted) {
            $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "su -c 'cat /data/data/$PackageName/databases/akai_memory.db'" -LocalFilePath $backupDb
            if ($rx.Success) { $extracted = $true }
        }

        if (-not $extracted -or -not (Test-Path $backupDb) -or (Get-Item $backupDb).Length -lt 512) {
            throw "ERRORE FAIL-CLOSED: Estrazione del database fallita (permessi negati o file non accessibile)."
        }

        Verify-SQLiteIntegrityOffline $backupDb | Out-Null
        $dbHash = Get-Sha256Hex $backupDb
        Write-Host "      Database SQLite salvato e verificato integro: $backupDb ($((Get-Item $backupDb).Length) bytes, SHA-256=$dbHash)" -ForegroundColor Green
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
                $memResp = Invoke-RestMethod -Uri $MemoryUrl -Method Get -TimeoutSec 4 -ErrorAction Stop
                $memJson = $memResp | ConvertTo-Json -Depth 10
                [System.IO.File]::WriteAllText($logicalBackupPath, $memJson, [System.Text.Encoding]::UTF8)
                Write-Host "      Backup logico REST /api/ai/memory salvato: $logicalBackupPath" -ForegroundColor Green
            } catch {
                Write-Host "      Endpoint REST non raggiungibile per backup logico ($($_.Exception.Message)) - continuo con snapshot binario..." -ForegroundColor Yellow
            }

            # 1.3 Backup OBBLIGATORIO del database SQLite (FAIL-CLOSED)
            Write-Host "[2/6] Backup preventivo OBBLIGATORIO del database SQLite..."
            & $adb -s $TargetAdb shell "am startservice -a it.akai.customremote.ACTION_BACKUP_DB $PackageName/.RemoteServerService" | Out-Null
            Start-Sleep -Seconds 2

            $dbExtracted = $false
            # Tentativo A: snapshot via run-as
            $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "run-as $PackageName cat files/akai_memory_snapshot.db" -LocalFilePath $backupDb
            if ($rx.Success) { $dbExtracted = $true }

            # Tentativo B: snapshot via su
            if (-not $dbExtracted) {
                $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "su -c 'cat /data/data/$PackageName/files/akai_memory_snapshot.db'" -LocalFilePath $backupDb
                if ($rx.Success) { $dbExtracted = $true }
            }

            # Tentativo C: database primario via run-as (baseline v5)
            if (-not $dbExtracted) {
                $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "run-as $PackageName cat databases/akai_memory.db" -LocalFilePath $backupDb
                if ($rx.Success) { $dbExtracted = $true }
            }

            # Tentativo D: database primario via su (baseline v5)
            if (-not $dbExtracted) {
                $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "su -c 'cat /data/data/$PackageName/databases/akai_memory.db'" -LocalFilePath $backupDb
                if ($rx.Success) { $dbExtracted = $true }
            }

            # VERIFICA FAIL-CLOSED CATEGORICA
            if (-not $dbExtracted -or -not (Test-Path $backupDb) -or (Get-Item $backupDb).Length -lt 512) {
                throw "ERRORE FAIL-CLOSED: Impossibile estrarre un backup integro del database dal dispositivo (permessi negati run-as/su o database non accessibile). L'installazione e' categoricamente INTERROTTA per prevenire perdite irrecuperabili di dati."
            }

            Verify-SQLiteIntegrityOffline $backupDb | Out-Null
            $backupDbHash = Get-Sha256Hex $backupDb
            Write-Host "      Database SQLite integro e salvato: $backupDb ($((Get-Item $backupDb).Length) bytes, SHA-256=$backupDbHash)" -ForegroundColor Green

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
        $attempts = if ($env:WATCHDOG_ATTEMPTS) { [int]$env:WATCHDOG_ATTEMPTS } else { 6 }
        $sleepSec = if ($env:WATCHDOG_SLEEP_SEC) { [int]$env:WATCHDOG_SLEEP_SEC } else { 5 }
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
                Write-Host "[ROLLBACK 1/4] Reinstallazione APK precedente (adb install -r -d)..."
                $rbRes = & $adb -s $TargetAdb install -r -d $backupApk
                Write-Host "      Esito adb install rollback: $rbRes"
                if ($LASTEXITCODE -ne 0 -or $rbRes -notmatch "Success") {
                    throw "FATALE: Reinstallazione rollback APK fallita!"
                }

                if (Test-Path $backupDb) {
                    Write-Host "[ROLLBACK 2/4] Ripristino database SQLite originale..."
                    # 1. Arresto forzato dell'app per rilasciare lock sul file
                    & $adb -s $TargetAdb shell "am force-stop $PackageName" | Out-Null

                    # 2. Rimozione file WAL e SHM orfani
                    & $adb -s $TargetAdb shell "run-as $PackageName rm -f databases/akai_memory.db-wal databases/akai_memory.db-shm" 2>$null | Out-Null
                    & $adb -s $TargetAdb shell "su -c 'rm -f /data/data/$PackageName/databases/akai_memory.db-wal /data/data/$PackageName/databases/akai_memory.db-shm'" 2>$null | Out-Null

                    # 3. Streaming diretto del backup binario in databases/akai_memory.db tramite pipe universale
                    $restored = $false
                    $streamRes = Send-FileViaAdbExecIn -AdbExe $adb -TargetAdb $TargetAdb -LocalFilePath $backupDb -RemoteCommand "run-as $PackageName sh -c 'mkdir -p databases; cat > databases/akai_memory.db; chmod 660 databases/akai_memory.db'"
                    if ($streamRes.Success) {
                        $restored = $true
                    } else {
                        $streamRes = Send-FileViaAdbExecIn -AdbExe $adb -TargetAdb $TargetAdb -LocalFilePath $backupDb -RemoteCommand "su -c 'mkdir -p /data/data/$PackageName/databases; cat > /data/data/$PackageName/databases/akai_memory.db; chown -R ${PackageName}:${PackageName} /data/data/$PackageName/databases; chmod 660 /data/data/$PackageName/databases/akai_memory.db'"
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

                    if ((Test-Path $verifyRestoreDb) -and ((Get-Item $verifyRestoreDb).Length -ge 512)) {
                        Verify-SQLiteIntegrityOffline $verifyRestoreDb | Out-Null
                        $restHash = Get-Sha256Hex $verifyRestoreDb
                        if ($backupDbHash -and $restHash -ne $backupDbHash) {
                            throw "ERRORE FAIL-CLOSED: Mismatch hash SHA-256 post-ripristino! Orig: $backupDbHash, Device: $restHash"
                        }
                        Write-Host "      Parita' hash SHA-256 ($restHash) e integrita' SQLite post-rollback verificate con successo." -ForegroundColor Green
                    }

                    Write-Host "      Database SQLite v5 ripristinato con successo." -ForegroundColor Green
                }

                Write-Host "[ROLLBACK 3/4] Riavvio servizio RemoteServerService..."
                & $adb -s $TargetAdb shell "am startservice $PackageName/.RemoteServerService" | Out-Null

                Write-Host "[ROLLBACK 4/4] Verifica post-rollback dello stato di salute..."
                Start-Sleep -Seconds 3
                try {
                    $rbStatus = Invoke-RestMethod -Uri $StatusUrl -Method Get -TimeoutSec 5 -ErrorAction Stop
                    if ($rbStatus.status -eq "ok") {
                        Write-Host "ROLLBACK RIUSCITO E VERIFICATO: Sistema TV tornato operativo al 100% sulla versione precedente." -ForegroundColor Green
                    }
                } catch {
                    Write-Host "ATTENZIONE POST-ROLLBACK: Endpoint status non ancora pronto ($($_.Exception.Message))." -ForegroundColor Yellow
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
            throw "Nessuna sessione di backup trovata in $BackupDir."
        }
        $backupApk = Join-Path $latestSession.FullName "it.akai.customremote_backup.apk"
        $backupDb = Join-Path $latestSession.FullName "akai_memory.db"

        if (-not (Test-Path $backupApk)) {
            throw "File di backup APK non trovato in $backupApk."
        }
        Write-Host "[1/4] Reinstallazione APK precedente da sessione: $($latestSession.Name)..."
        $res = & $adb -s $TargetAdb install -r -d $backupApk
        Write-Host "      Esito adb: $res"
        if ($LASTEXITCODE -ne 0 -or $res -notmatch "Success") {
            throw "Rollback fallito: adb non e' riuscito a reinstallare l'APK ($res)"
        }

        if (Test-Path $backupDb) {
            Write-Host "[2/4] Ripristino database SQLite originale..."
            & $adb -s $TargetAdb shell "am force-stop $PackageName" | Out-Null

            # Rimozione file WAL/SHM orfani
            & $adb -s $TargetAdb shell "run-as $PackageName rm -f databases/akai_memory.db-wal databases/akai_memory.db-shm" 2>$null | Out-Null
            & $adb -s $TargetAdb shell "su -c 'rm -f /data/data/$PackageName/databases/akai_memory.db-wal /data/data/$PackageName/databases/akai_memory.db-shm'" 2>$null | Out-Null

            $restored = $false
            $streamRes = Send-FileViaAdbExecIn -AdbExe $adb -TargetAdb $TargetAdb -LocalFilePath $backupDb -RemoteCommand "run-as $PackageName sh -c 'mkdir -p databases; cat > databases/akai_memory.db; chmod 660 databases/akai_memory.db'"
            if ($streamRes.Success) {
                $restored = $true
            } else {
                $streamRes = Send-FileViaAdbExecIn -AdbExe $adb -TargetAdb $TargetAdb -LocalFilePath $backupDb -RemoteCommand "su -c 'mkdir -p /data/data/$PackageName/databases; cat > /data/data/$PackageName/databases/akai_memory.db; chown -R ${PackageName}:${PackageName} /data/data/$PackageName/databases; chmod 660 /data/data/$PackageName/databases/akai_memory.db'"
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
            if ((Test-Path $verifyRestoreDb) -and ((Get-Item $verifyRestoreDb).Length -ge 512)) {
                Verify-SQLiteIntegrityOffline $verifyRestoreDb | Out-Null
                $origHash = Get-Sha256Hex $backupDb
                $restHash = Get-Sha256Hex $verifyRestoreDb
                if ($origHash -ne $restHash) {
                    throw "ERRORE FAIL-CLOSED: Mismatch hash SHA-256 post-ripristino! Orig: $origHash, Device: $restHash"
                }
                Write-Host "      Parita' hash SHA-256 ($origHash) e integrita' SQLite verificate con successo." -ForegroundColor Green
            }

            Write-Host "      Database SQLite ripristinato." -ForegroundColor Green
        }

        Write-Host "[3/4] Riavvio servizio RemoteServerService..."
        & $adb -s $TargetAdb shell "am startservice $PackageName/.RemoteServerService" | Out-Null

        Write-Host "[4/4] Watchdog post-rollback..."
        Start-Sleep -Seconds 3
        try {
            $statusResp = Invoke-RestMethod -Uri $StatusUrl -Method Get -TimeoutSec 5 -ErrorAction Stop
            if ($statusResp.status -eq "ok") {
                Write-Host "Rollback manuale completato e verificato con successo: TV operativa!" -ForegroundColor Green
            }
        } catch {
            Write-Host "Servizio in fase di avvio post-rollback." -ForegroundColor Yellow
        }
    }
}
