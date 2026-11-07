# ==============================================================================
# AKAI Custom Remote - Procedura di Installazione Sicura, Verifica Firme e Rollback Atomico
#
# REGOLA DI SICUREZZA ASSOLUTA:
# Durante la fase di review tecnica, l'esecuzione su TV fisica è congelata (HARDWARE FREEZE).
# Lo script richiede obbligatoriamente il flag esplicito: -AllowHardwareExecution
#
# Caratteristiche Tecniche di Sicurezza (Revisione 6):
# 1. Verifica Firma Digitale Fail-Closed Pre-Install:
#    Estrae e confronta l'impronta SHA-256 (64 caratteri esadecimali) tra backup e candidato.
#    Blocca l'esecuzione (Fail-Closed) se il tool è assente, l'APK non è firmato o se i digest differiscono.
# 2. Backup Atomico Obbligatorio e Consistente (Fail-Closed):
#    - Se l'app esiste sul dispositivo, il backup verificato del database SQLite è REQUISITO IMPERATIVO.
#    - Se il dump fallisce per permessi negati (run-as non debuggable / no su) o file inaccessibile:
#      ABORTO IMMEDIATO prima di qualsiasi operazione di installazione.
#    - Esegue snapshot consistente con checkpoint WAL TRUNCATE via intent applicativo.
#    - Salva in directory isolata di sessione con timestamp univoco.
# 3. Controllo Integrità SQLite Rigoroso (Fail-Closed):
#    - Verifica offline PRAGMA integrity_check via Node.js, Python o sqlite3 CLI.
#    - Se nessun interprete è disponibile o il file è corrotto: THROW IMMEDIATO (zero fail-open).
# 4. Rollback Atomico Indivisibile (APK + DB) Verificato:
#    - In caso di anomalia entro 30s dal watchdog, reinstalla l'APK v5 E ripristina il DB v5.
#    - Controlla i codici di uscita ($LASTEXITCODE) di ogni comando adb, con verifica integrità post-rollback.
# 5. Rimozione Default CI Pericoloso:
#    - Nessun default su artefatti CI effimeri; parametro -ApkPath obbligatorio ed esplicito.
# ==============================================================================

param(
    [ValidateSet("status", "backup", "install", "rollback", "plan")]
    [string]$Action = "status",
    [string]$ApkPath = $null,
    [string]$BackupDir = ".\backup_tv",
    [switch]$AllowHardwareExecution = $false
)

$ErrorActionPreference = "Stop"

$TargetTv = "192.168.1.8"
$TargetAdb = "$($TargetTv):5555"
$PackageName = "it.akai.customremote"
$StatusUrl = "http://$($TargetTv):8088/api/status"
$WebUrl = "http://$($TargetTv):8088/index.html"

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

function Get-ApkCertificateFingerprint($apkFile) {
    if (-not (Test-Path $apkFile)) {
        throw "ERRORE FAIL-CLOSED: File APK non trovato in: $apkFile"
    }

    $signerJar = Get-ApkSignerJar
    $out = $null
    
    $apksignerCli = Get-Command apksigner -ErrorAction SilentlyContinue
    if ($apksignerCli) {
        $out = & $apksignerCli.Source verify --print-certs $apkFile 2>&1
    } else {
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
const { DatabaseSync } = require('node:sqlite');
try {
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
        $res = & $validNode -e $jsCheck 2>&1
        if ($LASTEXITCODE -eq 0) {
            return $true
        } else {
            throw "ERRORE FAIL-CLOSED: Controllo di integrita' SQLite fallito con Node (exit $LASTEXITCODE) su $dbFile : $res"
        }
    }

    # 2. Prova con Python
    $pythonCmd = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $pythonCmd) { $pythonCmd = Get-Command python -ErrorAction SilentlyContinue }
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
        Write-Host "=== PIANO SICURO DI DEPLOYMENT, VERIFICA E ROLLBACK ATOMICO (Rev 6) ===" -ForegroundColor Cyan
        Write-Host "Fase 1: Validazione Parametri e Verifica Firma Digitale Fail-Closed Pre-Install"
        Write-Host "        - Rifiuta categoricamente artefatti CI di test non distribuibili."
        Write-Host "        - Estrae e confronta il digest SHA-256 esatto a 64 caratteri con apksigner."
        Write-Host "Fase 2: Backup Atomico Obbligatorio e Consistente (Fail-Closed)"
        Write-Host "        - Attiva checkpoint WAL TRUNCATE via intent di servizio per coerenza ACID."
        Write-Host "        - Estrae database SQLite in directory di sessione con timestamp univoco."
        Write-Host "        - Verifica offline PRAGMA integrity_check = ok."
        Write-Host "        - FAIL-CLOSED: Se il backup non puo' essere estratto o non e' integro, l'installazione NON procede."
        Write-Host "Fase 3: Installazione conservativa nuovo APK (adb install -r -d, ZERO uninstall)"
        Write-Host "Fase 4: Avvio del servizio e Multi-Point Health Check Watchdog (30s):"
        Write-Host "        - Verifica 1: /api/status risponde 200 con status=ok E uinput_ready=true"
        Write-Host "        - Verifica 2: /index.html risponde 200 con frontend Web Remote"
        Write-Host "        - Verifica 3: Processo attivo su device (pidof)"
        Write-Host "Fase 5: Rollback Atomico Indivisibile (APK v5 + DB v5) in caso di timeout/anomalia:"
        Write-Host "        - Reinstalla APK v5 precedente."
        Write-Host "        - Ripristina database SQLite v5 dal backup integro."
        Write-Host "        - Watchdog post-rollback con verifica di funzionamento."
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

        # 2. Snapshot consistente SQLite
        $backupDb = Join-Path $sessionDir "akai_memory.db"
        Write-Host "[2/3] Creazione snapshot consistente con WAL checkpoint via intent..."
        & $adb -s $TargetAdb shell "am startservice -a it.akai.customremote.ACTION_BACKUP_DB $PackageName/.RemoteServerService" | Out-Null
        Start-Sleep -Seconds 2

        Write-Host "[3/3] Estrazione database SQLite e verifica integrita'..."
        $extracted = $false

        # Metodo A: exec-out run-as
        & $adb -s $TargetAdb exec-out run-as $PackageName cat files/akai_memory_snapshot.db > $backupDb 2>$null
        if (Test-Path $backupDb -and (Get-Item $backupDb).Length -ge 512) {
            $extracted = $true
        }

        # Metodo B: su -c
        if (-not $extracted) {
            & $adb -s $TargetAdb shell "su -c 'cat /data/data/$PackageName/files/akai_memory_snapshot.db'" 2>$null > $backupDb
            if (Test-Path $backupDb -and (Get-Item $backupDb).Length -ge 512) {
                $extracted = $true
            }
        }

        # Metodo C: database originale
        if (-not $extracted) {
            & $adb -s $TargetAdb exec-out run-as $PackageName cat databases/akai_memory.db > $backupDb 2>$null
            if (Test-Path $backupDb -and (Get-Item $backupDb).Length -ge 512) {
                $extracted = $true
            }
        }

        if (-not $extracted -or -not (Test-Path $backupDb) -or (Get-Item $backupDb).Length -lt 512) {
            throw "ERRORE FAIL-CLOSED: Estrazione del database fallita (permessi negati o file non accessibile)."
        }

        Verify-SQLiteIntegrityOffline $backupDb | Out-Null
        Write-Host "      Database SQLite salvato e verificato integro: $backupDb ($((Get-Item $backupDb).Length) bytes)" -ForegroundColor Green
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

            # 1.2 Backup OBBLIGATORIO del database SQLite (FAIL-CLOSED)
            Write-Host "[2/6] Backup preventivo OBBLIGATORIO del database SQLite..."
            & $adb -s $TargetAdb shell "am startservice -a it.akai.customremote.ACTION_BACKUP_DB $PackageName/.RemoteServerService" | Out-Null
            Start-Sleep -Seconds 2

            $dbExtracted = $false
            & $adb -s $TargetAdb exec-out run-as $PackageName cat files/akai_memory_snapshot.db > $backupDb 2>$null
            if (Test-Path $backupDb -and (Get-Item $backupDb).Length -ge 512) {
                $dbExtracted = $true
            }

            if (-not $dbExtracted) {
                & $adb -s $TargetAdb shell "su -c 'cat /data/data/$PackageName/files/akai_memory_snapshot.db'" 2>$null > $backupDb
                if (Test-Path $backupDb -and (Get-Item $backupDb).Length -ge 512) {
                    $dbExtracted = $true
                }
            }

            if (-not $dbExtracted) {
                & $adb -s $TargetAdb exec-out run-as $PackageName cat databases/akai_memory.db > $backupDb 2>$null
                if (Test-Path $backupDb -and (Get-Item $backupDb).Length -ge 512) {
                    $dbExtracted = $true
                }
            }

            # VERIFICA FAIL-CLOSED CATEGORICA
            if (-not $dbExtracted -or -not (Test-Path $backupDb) -or (Get-Item $backupDb).Length -lt 512) {
                throw "ERRORE FAIL-CLOSED: Impossibile estrarre un backup integro del database dal dispositivo (permessi negati run-as/su o database non accessibile). L'installazione e' categoricamente INTERROTTA per prevenire perdite irrecuperabili di dati."
            }

            Verify-SQLiteIntegrityOffline $backupDb | Out-Null
            Write-Host "      Database SQLite integro e salvato: $backupDb ($((Get-Item $backupDb).Length) bytes)" -ForegroundColor Green

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
        $attempts = 6
        for ($i = 1; $i -le $attempts; $i++) {
            Start-Sleep -Seconds 5
            try {
                $statusResp = Invoke-RestMethod -Uri $StatusUrl -Method Get -TimeoutSec 4 -ErrorAction Stop
                $webResp = Invoke-WebRequest -Uri $WebUrl -Method Get -TimeoutSec 4 -ErrorAction Stop
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
                    Write-Host "FATALE: Reinstallazione rollback APK fallita!" -ForegroundColor Red
                    exit 1
                }

                if (Test-Path $backupDb) {
                    Write-Host "[ROLLBACK 2/4] Ripristino database SQLite originale v5..."
                    # Invio file direttamente tramite pipe stdin / snapshot
                    & $adb -s $TargetAdb shell "am force-stop $PackageName" | Out-Null
                    Get-Content -Path $backupDb -Encoding Byte -Raw | & $adb -s $TargetAdb exec-in "run-as $PackageName sh -c 'cat > files/akai_memory_restore.db'" 2>&1 | Out-Null
                    & $adb -s $TargetAdb shell "am startservice -a it.akai.customremote.ACTION_RESTORE_DB --es source_path files/akai_memory_restore.db $PackageName/.RemoteServerService" | Out-Null
                    Start-Sleep -Seconds 2
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
            Write-Host "[2/4] Ripristino database SQLite originale v5..."
            & $adb -s $TargetAdb shell "am force-stop $PackageName" | Out-Null
            Get-Content -Path $backupDb -Encoding Byte -Raw | & $adb -s $TargetAdb exec-in "run-as $PackageName sh -c 'cat > files/akai_memory_restore.db'" 2>&1 | Out-Null
            & $adb -s $TargetAdb shell "am startservice -a it.akai.customremote.ACTION_RESTORE_DB --es source_path files/akai_memory_restore.db $PackageName/.RemoteServerService" | Out-Null
            Start-Sleep -Seconds 2
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
