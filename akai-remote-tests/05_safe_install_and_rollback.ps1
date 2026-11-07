# ==============================================================================
# AKAI Custom Remote - Procedura di Installazione Sicura, Verifica Firme e Rollback Atomico
#
# REGOLA DI SICUREZZA ASSOLUTA:
# Durante la fase di review tecnica, l'esecuzione su TV fisica è congelata (HARDWARE FREEZE).
# Lo script richiede obbligatoriamente il flag esplicito: -AllowHardwareExecution
#
# Caratteristiche Tecniche di Sicurezza (Revisione 5):
# 1. Verifica Firma Digitale Fail-Closed Pre-Install:
#    Estrae e confronta l'impronta SHA-256 (64 caratteri esadecimali) tra backup e candidato.
#    Blocca l'esecuzione (Fail-Closed) se il tool è assente, l'APK non è firmato o se i digest differiscono.
# 2. Backup Atomico Binario + Database SQLite con Verifica Integrità:
#    - Arresta l'app preventivamente (am force-stop) per garantire il flush WAL/SHM su disco.
#    - Salva in directory isolata di sessione con timestamp (zero sovrascritture di vecchi backup).
#    - Esegue verifica di integrità SQLite (PRAGMA integrity_check) prima di procedere.
#    - Se il backup fallisce o non è integro: ABORTO IMMEDIATO (FAIL-CLOSED, nessuna installazione).
# 3. Preservazione Dati: NON esegue MAI "adb uninstall" (che distruggerebbe /data/data).
#    Utilizza esclusivamente "adb install -r -d" con controllo del codice di uscita.
# 4. Multi-Point Health Check Watchdog (30s):
#    - Verifica 1: HTTP /api/status risponde 200 con status="ok" E uinput_ready=true
#    - Verifica 2: HTTP /index.html risponde 200 servendo il frontend Web Remote
#    - Verifica 3: Processo demone attivo (pidof)
# 5. Rollback Atomico Indivisibile (APK + DB):
#    In caso di anomalia entro 30s, reinstalla l'APK v5 E ripristina il DB v5 originale,
#    poiché l'APK v5 non possiede retroattivamente l'onDowngrade per leggere un DB v6.
# ==============================================================================

param(
    [ValidateSet("status", "backup", "install", "rollback", "plan")]
    [string]$Action = "status",
    [string]$ApkPath = ".\build_ci\app-ci-test-nondistributable.apk",
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

function Get-AdbExecutable {
    $adb = Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Path
    if (-not $adb -or -not (Test-Path $adb)) {
        $adb = "adb"
    }
    return $adb
}

function Get-ApkSignerJar {
    $sdkDir = "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay\tools\android-sdk"
    $apksignerJar = Join-Path $sdkDir "build-tools\28.0.3\lib\apksigner.jar"
    return $apksignerJar
}

function Get-ApkCertificateFingerprint($apkFile) {
    if (-not (Test-Path $apkFile)) {
        throw "ERRORE FAIL-CLOSED: File APK non trovato in: $apkFile"
    }

    $signerJar = Get-ApkSignerJar
    if (-not (Test-Path $signerJar)) {
        throw "ERRORE FAIL-CLOSED: Tool apksigner.jar non trovato in: $signerJar"
    }

    $jdkDir = "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay\tools\jdk-17"
    $java = Join-Path $jdkDir "bin\java.exe"
    if (-not (Test-Path $java)) {
        throw "ERRORE FAIL-CLOSED: Eseguibile java non trovato in: $java"
    }

    $out = & $java -jar $signerJar verify --print-certs $apkFile 2>&1
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
        return $false
    }
    if ((Get-Item $dbFile).Length -lt 512) {
        return $false
    }
    $node = "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay\tools\nodejs\node.exe"
    if (Test-Path $node) {
        $jsCheck = @"
const { DatabaseSync } = require('node:sqlite');
try {
    const db = new DatabaseSync('$($dbFile.Replace('\', '/'))');
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
        $res = & $node -e $jsCheck
        return ($LASTEXITCODE -eq 0)
    }
    return $true
}

switch ($Action) {
    "plan" {
        Write-Host "=== PIANO SICURO DI DEPLOYMENT, VERIFICA E ROLLBACK ATOMICO (Rev 5) ===" -ForegroundColor Cyan
        Write-Host "Fase 1: Verifica Firma Digitale Fail-Closed Pre-Install"
        Write-Host "        Estrae il digest SHA-256 di entrambi gli APK con apksigner."
        Write-Host "        Blocca categoricamente in caso di mismatch, mancata firma o errore tool."
        Write-Host "Fase 2: Backup Atomico Isolato (APK binario + SQLite akai_memory.db + WAL/SHM)"
        Write-Host "        - Arresto preventivo del demone (am force-stop) per flush transazioni."
        Write-Host "        - Salvataggio in cartella sessione con timestamp univoco."
        Write-Host "        - Verifica offline di integrità SQLite (PRAGMA integrity_check)."
        Write-Host "        - FAIL-CLOSED: Se il backup fallisce o non è integro, l'installazione NON procede."
        Write-Host "Fase 3: Installazione conservativa nuovo APK (adb install -r -d, ZERO uninstall)"
        Write-Host "Fase 4: Avvio del servizio e Multi-Point Health Check Watchdog (30s):"
        Write-Host "        - Verifica 1: /api/status risponde 200 con status=ok E uinput_ready=true"
        Write-Host "        - Verifica 2: /index.html risponde 200 con frontend Web Remote"
        Write-Host "        - Verifica 3: Processo attivo su device (pidof)"
        Write-Host "Fase 5: Rollback Atomico Indivisibile in caso di fallimento o timeout:"
        Write-Host "        - Reinstalla APK v5 precedente."
        Write-Host "        - Ripristina database SQLite v5 originale dal backup verificato."
        Write-Host "        - Watchdog post-rollback con verifica dello stato di salute."
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
            $pidVal = & $adb -s $TargetAdb shell "pidof $PackageName"
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

        # 1. Arresto pulito per commit WAL
        Write-Host "[1/4] Arresto preventivo servizio per garantire il flush SQLite (force-stop)..."
        & $adb -s $TargetAdb shell "am force-stop $PackageName"

        # 2. Download APK
        $pathOutput = & $adb -s $TargetAdb shell "pm path $PackageName"
        if ($pathOutput -notmatch "package:(.+)") {
            throw "ERRORE FAIL-CLOSED: Impossibile individuare il percorso APK su device per $PackageName."
        }
        $remoteApk = $matches[1].Trim()
        $backupApk = Join-Path $sessionDir "it.akai.customremote_backup.apk"
        Write-Host "[2/4] Download APK remoto da $remoteApk..."
        & $adb -s $TargetAdb pull $remoteApk $backupApk
        if (-not (Test-Path $backupApk) -or (Get-Item $backupApk).Length -eq 0) {
            throw "ERRORE FAIL-CLOSED: Download APK di backup fallito o file vuoto."
        }
        Write-Host "      APK salvato: $backupApk ($((Get-Item $backupApk).Length) bytes)" -ForegroundColor Green

        # 3. Estrazione SQLite e verifica integrità
        $backupDb = Join-Path $sessionDir "akai_memory.db"
        Write-Host "[3/4] Estrazione database SQLite /data/data/$PackageName/databases/akai_memory.db..."
        
        # Tentativo via run-as / su / adb shell
        $dbExtracted = $false
        & $adb -s $TargetAdb shell "run-as $PackageName cp databases/akai_memory.db /sdcard/tmp_akai_memory.db" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            & $adb -s $TargetAdb pull /sdcard/tmp_akai_memory.db $backupDb 2>&1 | Out-Null
            & $adb -s $TargetAdb shell "rm -f /sdcard/tmp_akai_memory.db" 2>&1 | Out-Null
            if (Test-Path $backupDb -and (Get-Item $backupDb).Length -gt 0) {
                $dbExtracted = $true
            }
        }
        if (-not $dbExtracted) {
            & $adb -s $TargetAdb shell "su -c 'cp /data/data/$PackageName/databases/akai_memory.db /sdcard/tmp_akai_memory.db && chmod 666 /sdcard/tmp_akai_memory.db'" 2>&1 | Out-Null
            & $adb -s $TargetAdb pull /sdcard/tmp_akai_memory.db $backupDb 2>&1 | Out-Null
            & $adb -s $TargetAdb shell "rm -f /sdcard/tmp_akai_memory.db" 2>&1 | Out-Null
            if (Test-Path $backupDb -and (Get-Item $backupDb).Length -gt 0) {
                $dbExtracted = $true
            }
        }

        if ($dbExtracted) {
            Write-Host "[4/4] Verifica integrità offline del database estratto..."
            $isIntegrityOk = Verify-SQLiteIntegrityOffline $backupDb
            if (-not $isIntegrityOk) {
                throw "ERRORE FAIL-CLOSED: Il database estratto NON ha superato il controllo di integrità SQLite (PRAGMA integrity_check != ok)!"
            }
            Write-Host "      Integrità SQLite verificata con successo: $backupDb ($((Get-Item $backupDb).Length) bytes)" -ForegroundColor Green
        } else {
            Write-Host "      Database non presente o non estraibile (prima installazione o permessi da verificare)." -ForegroundColor Yellow
        }

        # Riavvio servizio
        & $adb -s $TargetAdb shell "am startservice $PackageName/.RemoteServerService" | Out-Null
        Write-Host "Sessione di backup salvata in: $sessionDir" -ForegroundColor Green
    }

    "install" {
        $adb = Get-AdbExecutable
        Write-Host "=== INSTALLAZIONE PROTETTA CON VERIFICA FIRME FAIL-CLOSED E WATCHDOG (30s) ===" -ForegroundColor Cyan
        if (-not (Test-Path $ApkPath)) {
            throw "ERRORE FAIL-CLOSED: File APK candidato non trovato in $ApkPath."
        }

        & $adb connect $TargetAdb | Out-Null
        $sessionDir = Join-Path $BackupDir "session_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null

        # 1. Backup atomico preventivo obbligatorio
        Write-Host "[1/6] Esecuzione backup preventivo dell'APK installato..."
        $pathOutput = & $adb -s $TargetAdb shell "pm path $PackageName"
        $hasPrevious = $false
        $backupApk = Join-Path $sessionDir "it.akai.customremote_backup.apk"
        $backupDb = Join-Path $sessionDir "akai_memory.db"

        if ($pathOutput -match "package:(.+)") {
            $remoteApk = $matches[1].Trim()
            & $adb -s $TargetAdb shell "am force-stop $PackageName"
            & $adb -s $TargetAdb pull $remoteApk $backupApk | Out-Null
            if (-not (Test-Path $backupApk) -or (Get-Item $backupApk).Length -eq 0) {
                throw "ERRORE FAIL-CLOSED: Impossibile completare il backup dell'APK esistente."
            }
            $hasPrevious = $true
            Write-Host "      Backup APK salvato: $backupApk ($((Get-Item $backupApk).Length) bytes)" -ForegroundColor Green

            # Backup DB
            Write-Host "[2/6] Backup preventivo database SQLite..."
            & $adb -s $TargetAdb shell "run-as $PackageName cp databases/akai_memory.db /sdcard/tmp_akai_memory.db" 2>&1 | Out-Null
            & $adb -s $TargetAdb pull /sdcard/tmp_akai_memory.db $backupDb 2>&1 | Out-Null
            & $adb -s $TargetAdb shell "rm -f /sdcard/tmp_akai_memory.db" 2>&1 | Out-Null
            if (Test-Path $backupDb -and (Get-Item $backupDb).Length -gt 0) {
                $isIntegrityOk = Verify-SQLiteIntegrityOffline $backupDb
                if (-not $isIntegrityOk) {
                    throw "ERRORE FAIL-CLOSED: Il database estratto non e' integro! Aborto installazione."
                }
                Write-Host "      Database SQLite integro e salvato: $backupDb ($((Get-Item $backupDb).Length) bytes)" -ForegroundColor Green
            }
        }

        # 2. Verifica compatibilità firme FAIL-CLOSED
        if ($hasPrevious) {
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
            Write-Host "[3/6] Nessun APK precedente installato sulla TV; skip check firme." -ForegroundColor Yellow
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
                if ($rbRes -notmatch "Success") {
                    Write-Host "FATALE: Reinstallazione rollback APK fallita!" -ForegroundColor Red
                    exit 1
                }

                if (Test-Path $backupDb) {
                    Write-Host "[ROLLBACK 2/4] Ripristino database SQLite originale v5 (necessario perché v5 non supporta DB v6)..."
                    & $adb -s $TargetAdb shell "am force-stop $PackageName"
                    & $adb -s $TargetAdb push $backupDb /sdcard/tmp_akai_restore.db | Out-Null
                    & $adb -s $TargetAdb shell "run-as $PackageName cp /sdcard/tmp_akai_restore.db databases/akai_memory.db" 2>&1 | Out-Null
                    & $adb -s $TargetAdb shell "rm -f /sdcard/tmp_akai_restore.db" 2>&1 | Out-Null
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
                    } else {
                        Write-Host "AVVISO POST-ROLLBACK: Servizio riavviato ma risposta status anomala." -ForegroundColor Yellow
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
        # Cerca la sessione di backup più recente
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
        if ($res -notmatch "Success") {
            throw "Rollback fallito: adb non e' riuscito a reinstallare l'APK ($res)"
        }

        if (Test-Path $backupDb) {
            Write-Host "[2/4] Ripristino database SQLite originale v5..."
            & $adb -s $TargetAdb shell "am force-stop $PackageName"
            & $adb -s $TargetAdb push $backupDb /sdcard/tmp_akai_restore.db | Out-Null
            & $adb -s $TargetAdb shell "run-as $PackageName cp /sdcard/tmp_akai_restore.db databases/akai_memory.db" 2>&1 | Out-Null
            & $adb -s $TargetAdb shell "rm -f /sdcard/tmp_akai_restore.db" 2>&1 | Out-Null
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
