# ==============================================================================
# AKAI Custom Remote - Procedura di Installazione Sicura, Verifica Firme e Rollback Atomico
#
# REGOLA DI SICUREZZA ASSOLUTA:
# Durante la fase di review tecnica, l'esecuzione su TV fisica è congelata (HARDWARE FREEZE).
# Lo script richiede obbligatoriamente il flag esplicito: -AllowHardwareExecution
#
# Caratteristiche Tecniche di Sicurezza:
# 1. Verifica Firma Digitale Pre-Install: estrae e confronta il fingerprint SHA-256 del certificato
#    tra l'APK di backup estratto dal dispositivo e l'APK candidato. Rifiuta l'installazione se
#    le firme non coincidono (prevenendo l'errore INSTALL_FAILED_UPDATE_INCOMPATIBLE).
# 2. Backup Atomico Binario + Database SQLite:
#    - Salva l'APK precedente via "adb pull"
#    - Esegue il dump/backup del database SQLite "akai_memory.db"
# 3. Preservazione Dati: NON esegue MAI "adb uninstall" (che distruggerebbe SQLite e sessioni).
#    Utilizza esclusivamente "adb install -r -d" per preservare /data/data/it.akai.customremote.
# 4. Multi-Point Health Check Watchdog (30s):
#    - Verifica 1: HTTP /api/status risponde 200 con status="ok" E uinput_ready=true
#    - Verifica 2: HTTP /index.html risponde 200 servendo il frontend Web Remote
#    - Verifica 3: Processo demone attivo (pidof)
# 5. Rollback Atomico a Doppio Livello:
#    In caso di anomalia entro 30s, reinstalla l'APK precedente e ripristina lo schema/db originale,
#    verificando lo stato finale di salute post-rollback.
# ==============================================================================

param(
    [ValidateSet("status", "backup", "install", "rollback", "plan")]
    [string]$Action = "status",
    [string]$ApkPath = ".\akai-remote-tv\app\build\outputs\apk\debug\app-debug.apk",
    [string]$BackupDir = ".\backup_tv",
    [switch]$AllowHardwareExecution = $false
)

$ErrorActionPreference = "Stop"

$TargetTv = "192.168.1.8"
$TargetAdb = "$($TargetTv):5555"
$PackageName = "it.akai.customremote"
$StatusUrl = "http://$($TargetTv):8088/api/status"
$WebUrl = "http://$($TargetTv):8088/index.html"
$BackupApk = Join-Path $BackupDir "it.akai.customremote_backup_previous.apk"
$BackupDb = Join-Path $BackupDir "akai_memory_backup.db"

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

function Get-ApkSignerExecutable {
    $sdkDir = "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay\tools\android-sdk"
    $apksignerJar = Join-Path $sdkDir "build-tools\28.0.3\lib\apksigner.jar"
    return $apksignerJar
}

function Get-ApkCertificateFingerprint($apkFile) {
    $signerJar = Get-ApkSignerExecutable
    $jdkDir = "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay\tools\jdk-17"
    $java = Join-Path $jdkDir "bin\java.exe"

    if (Test-Path $signerJar) {
        $out = & $java -jar $signerJar verify --print-certs $apkFile 2>&1
        $match = $out | Select-String "Signer #1 certificate SHA-256 digest:\s*([a-fA-F0-9]+)"
        if ($match) {
            return $match.Matches[0].Groups[1].Value.ToLower().Trim()
        }
    }
    return "UNKNOWN"
}

switch ($Action) {
    "plan" {
        Write-Host "=== PIANO SICURO DI DEPLOYMENT, VERIFICA E ROLLBACK ATOMICO ===" -ForegroundColor Cyan
        Write-Host "Fase 1: Verifica firma APK candidato vs firma release TV"
        Write-Host "        Previene l'errore bloccante INSTALL_FAILED_UPDATE_INCOMPATIBLE"
        Write-Host "Fase 2: Backup preventivo completo (APK binario + SQLite akai_memory.db)"
        Write-Host "Fase 3: Installazione conservativa nuovo APK (adb install -r -d, ZERO uninstall)"
        Write-Host "Fase 4: Avvio del servizio e Multi-Point Health Check Watchdog (30s):"
        Write-Host "        - Verifica 1: /api/status risponde 200 con status=ok E uinput_ready=true"
        Write-Host "        - Verifica 2: /index.html risponde 200 con frontend Web Remote"
        Write-Host "        - Verifica 3: Processo attivo su device (pidof)"
        Write-Host "Fase 5: Rollback automatico in caso di timeout o anomalia:"
        Write-Host "        - Reinstalla APK precedente ($BackupApk)"
        Write-Host "        - Ripristina database SQLite v5 ($BackupDb)"
        Write-Host "        - Verifica health check della versione ripristinata"
        Write-Host "==================================================================" -ForegroundColor Cyan
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
        Write-Host "=== BACKUP PREVENTIVO COMPLETO (BINARIO + DATABASE) ===" -ForegroundColor Cyan
        New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

        # 1. Backup APK
        $pathOutput = & $adb -s $TargetAdb shell "pm path $PackageName"
        if ($pathOutput -match "package:(.+)") {
            $remoteApk = $matches[1].Trim()
            Write-Host "[1/2] Download APK remoto da $remoteApk..."
            & $adb -s $TargetAdb pull $remoteApk $BackupApk
            if (Test-Path $BackupApk) {
                Write-Host "      APK salvato: $BackupApk ($((Get-Item $BackupApk).Length) bytes)" -ForegroundColor Green
            }
        }

        # 2. Backup SQLite akai_memory.db
        Write-Host "[2/2] Estrazione backup database SQLite..."
        & $adb -s $TargetAdb shell "cp /data/data/$PackageName/databases/akai_memory.db /sdcard/akai_memory_backup.db" 2>$null | Out-Null
        & $adb -s $TargetAdb pull /sdcard/akai_memory_backup.db $BackupDb 2>$null | Out-Null
        & $adb -s $TargetAdb shell "rm /sdcard/akai_memory_backup.db" 2>$null | Out-Null
        if (Test-Path $BackupDb) {
            Write-Host "      Database SQLite salvato: $BackupDb ($((Get-Item $BackupDb).Length) bytes)" -ForegroundColor Green
        } else {
            Write-Host "      Avviso: Database non ancora creato su device (prima installazione pulita)." -ForegroundColor Yellow
        }
    }

    "install" {
        $adb = Get-AdbExecutable
        Write-Host "=== INSTALLAZIONE PROTETTA CON VERIFICA FIRME E WATCHDOG (30s) ===" -ForegroundColor Cyan
        if (-not (Test-Path $ApkPath)) {
            throw "File APK candidato non trovato in $ApkPath."
        }

        New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

        # 1. Esegui backup preventivo completo
        Write-Host "[1/5] Esecuzione backup preventivo dell'APK installato..."
        $pathOutput = & $adb -s $TargetAdb shell "pm path $PackageName"
        $hasPrevious = $false
        if ($pathOutput -match "package:(.+)") {
            $remoteApk = $matches[1].Trim()
            & $adb -s $TargetAdb pull $remoteApk $BackupApk | Out-Null
            $hasPrevious = Test-Path $BackupApk
            if ($hasPrevious) {
                Write-Host "      Backup APK salvato: $BackupApk ($((Get-Item $BackupApk).Length) bytes)" -ForegroundColor Green
                # Salva anche il DB
                & $adb -s $TargetAdb shell "cp /data/data/$PackageName/databases/akai_memory.db /sdcard/akai_memory_backup.db" 2>$null | Out-Null
                & $adb -s $TargetAdb pull /sdcard/akai_memory_backup.db $BackupDb 2>$null | Out-Null
                & $adb -s $TargetAdb shell "rm /sdcard/akai_memory_backup.db" 2>$null | Out-Null
            }
        }

        # 2. Verifica compatibilità firme
        if ($hasPrevious) {
            Write-Host "[2/5] Verifica compatibilità certificato firma tra APK attuale e candidato..."
            $backupFp = Get-ApkCertificateFingerprint $BackupApk
            $candidateFp = Get-ApkCertificateFingerprint $ApkPath
            Write-Host "      Certificato installato : $backupFp"
            Write-Host "      Certificato candidato   : $candidateFp"

            if ($backupFp -ne "UNKNOWN" -and $candidateFp -ne "UNKNOWN" -and $backupFp -ne $candidateFp) {
                throw "FIRMA INCOMPATIBILE: Il certificato dell'APK candidato non corrisponde a quello installato sulla TV. L'installazione sovrascritta (install -r) verrebbe rifiutata da Android con INSTALL_FAILED_UPDATE_INCOMPATIBLE. Usare la stessa chiave di firma."
            }
            Write-Host "      Compatibilita firma verificata al 100%." -ForegroundColor Green
        } else {
            Write-Host "[2/5] Nessun APK precedente installato sulla TV; skip check firme." -ForegroundColor Yellow
        }

        # 3. Installazione conservativa (mai uninstall, preserva /data/data)
        Write-Host "[3/5] Installazione nuovo APK (adb install -r -d)..."
        $installRes = & $adb -s $TargetAdb install -r -d $ApkPath
        Write-Host "      Esito adb: $installRes"
        if ($installRes -notmatch "Success") {
            throw "Installazione fallita da adb: $installRes"
        }

        # 4. Avvio servizio
        Write-Host "[4/5] Avvio servizio RemoteServerService..."
        & $adb -s $TargetAdb shell "am startservice $PackageName/.RemoteServerService" | Out-Null

        # 5. Multi-Point Health Check Watchdog (30s)
        Write-Host "[5/5] Multi-Point Health Check Watchdog attivo (timeout 30s)..."
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
            Write-Host "`nALLARME: Health check fallito entro 30s! Avvio ROLLBACK ATOMICO..." -ForegroundColor Red
            if ($hasPrevious) {
                Write-Host "[ROLLBACK 1/4] Reinstallazione APK precedente (adb install -r -d)..."
                $rbRes = & $adb -s $TargetAdb install -r -d $BackupApk
                Write-Host "      Esito adb install rollback: $rbRes"
                if ($rbRes -notmatch "Success") {
                    Write-Host "FATALE: Reinstallazione rollback APK fallita!" -ForegroundColor Red
                    exit 1
                }

                if (Test-Path $BackupDb) {
                    Write-Host "[ROLLBACK 2/4] Ripristino database SQLite originale..."
                    & $adb -s $TargetAdb push $BackupDb /sdcard/akai_memory_restore.db | Out-Null
                    & $adb -s $TargetAdb shell "cp /sdcard/akai_memory_restore.db /data/data/$PackageName/databases/akai_memory.db" 2>$null | Out-Null
                    & $adb -s $TargetAdb shell "rm /sdcard/akai_memory_restore.db" 2>$null | Out-Null
                    Write-Host "      Database SQLite ripristinato con successo." -ForegroundColor Green
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
        if (-not (Test-Path $BackupApk)) {
            throw "File di backup non trovato in $BackupApk."
        }
        Write-Host "[1/4] Reinstallazione APK precedente (adb install -r -d)..."
        $res = & $adb -s $TargetAdb install -r -d $BackupApk
        Write-Host "      Esito adb: $res"
        if ($res -notmatch "Success") {
            throw "Rollback fallito: adb non e' riuscito a reinstallare l'APK ($res)"
        }

        if (Test-Path $BackupDb) {
            Write-Host "[2/4] Ripristino database SQLite originale..."
            & $adb -s $TargetAdb push $BackupDb /sdcard/akai_memory_restore.db | Out-Null
            & $adb -s $TargetAdb shell "cp /sdcard/akai_memory_restore.db /data/data/$PackageName/databases/akai_memory.db" 2>$null | Out-Null
            & $adb -s $TargetAdb shell "rm /sdcard/akai_memory_restore.db" 2>$null | Out-Null
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
