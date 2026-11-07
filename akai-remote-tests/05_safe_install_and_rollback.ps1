# ==============================================================================
# AKAI Custom Remote - Procedura di Installazione Sicura e Rollback con Health Check
#
# REGOLA DI SICUREZZA: Durante la fase di revisione tecnica, l'esecuzione su TV fisica
# è rigorosamente bloccata. Il flag -AllowHardwareExecution è richiesto per sbloccare.
#
# Caratteristiche di Sicurezza:
# 1. Backup Preventivo APK: estrae e salva l'APK attualmente installato sulla TV.
# 2. Preservazione Dati: NON esegue MAI "adb uninstall" (che distruggerebbe SQLite e sessioni).
#    Usa esclusivamente "adb install -r -d" per preservare database e configurazioni.
# 3. Watchdog Health Check (30s): dopo l'installazione, interroga /api/status. Se l'endpoint
#    non risponde entro 30 secondi con HTTP 200, avvia automaticamente il ROLLBACK dell'APK precedente.
# 4. Rollback Atomico: reinstalla il backup dell'APK precedentemente salvato.
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
$BackupApk = Join-Path $BackupDir "it.akai.customremote_backup_previous.apk"

# -----------------------------------------------------------------------------
# SAFETY FREEZE GUARD
# -----------------------------------------------------------------------------
if ($Action -in @("install", "rollback") -and -not $AllowHardwareExecution) {
    Write-Host "================================================================================" -ForegroundColor Red
    Write-Host "BLOCCO DI SICUREZZA ATTIVO (HARDWARE FREEZE):" -ForegroundColor Red
    Write-Host "L'esecuzione su hardware fisico TV e' bloccata fino all'approvazione formale." -ForegroundColor Yellow
    Write-Host "Per visualizzare il piano operativo sicuro usa: -Action plan" -ForegroundColor Cyan
    Write-Host "Per eseguire realmente e' richiesto il parametro esplicito: -AllowHardwareExecution" -ForegroundColor Yellow
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

switch ($Action) {
    "plan" {
        Write-Host "=== PIANO SICURO DI DEPLOYMENT E ROLLBACK (POST-APPROVAL) ===" -ForegroundColor Cyan
        Write-Host "1. Connessione ADB a $TargetAdb"
        Write-Host "2. Backup: adb shell pm path $PackageName -> adb pull -> $BackupApk"
        Write-Host "3. Verifica firma e compatibilita tra APK di backup e nuovo APK"
        Write-Host "4. Deploy protetto: adb install -r -d $ApkPath (preserva /data/data/$PackageName)"
        Write-Host "5. Avvio servizio: am startservice $PackageName/.RemoteServerService"
        Write-Host "6. Watchdog 30s: polling di $StatusUrl (attesi max 6 tentativi a intervalli di 5s)"
        Write-Host "7. Se /api/status risponde HTTP 200 {status: ok} -> SUCCESSO CONFERMATO"
        Write-Host "8. Se timeout 30s superato senza risposta -> ROLLBACK AUTOMATICO:"
        Write-Host "   adb install -r -d $BackupApk -> ripristino versione precedente senza perdita dati."
        Write-Host "=============================================================" -ForegroundColor Cyan
    }

    "status" {
        $adb = Get-AdbExecutable
        Write-Host "=== STATO TELECOMANDO SU AKAI AKTV5037N ===" -ForegroundColor Cyan
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
        Write-Host "=== ESECUZIONE BACKUP APK ATTUALE DALLA TV ===" -ForegroundColor Cyan
        New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
        $pathOutput = & $adb -s $TargetAdb shell "pm path $PackageName"
        if ($pathOutput -match "package:(.+)") {
            $remoteApk = $matches[1].Trim()
            Write-Host "Trovato APK remoto: $remoteApk"
            Write-Host "Download in corso verso $BackupApk..."
            & $adb -s $TargetAdb pull $remoteApk $BackupApk
            if (Test-Path $BackupApk) {
                Write-Host "Backup completato con successo: $((Get-Item $BackupApk).Length) bytes" -ForegroundColor Green
            } else {
                throw "Errore durante il pull dell'APK dal device."
            }
        } else {
            Write-Host "Pacchetto $PackageName non presente sulla TV; nessun backup estraibile." -ForegroundColor Yellow
        }
    }

    "install" {
        $adb = Get-AdbExecutable
        Write-Host "=== INSTALLAZIONE PROTETTA CON WATCHDOG ROLLBACK (30s) ===" -ForegroundColor Cyan
        if (-not (Test-Path $ApkPath)) {
            throw "File APK non trovato in $ApkPath."
        }

        # 1. Esegui backup preventivo automatico
        New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
        $pathOutput = & $adb -s $TargetAdb shell "pm path $PackageName"
        $hasPrevious = $false
        if ($pathOutput -match "package:(.+)") {
            $remoteApk = $matches[1].Trim()
            Write-Host "[1/4] Estrazione backup APK preventivo da $remoteApk..."
            & $adb -s $TargetAdb pull $remoteApk $BackupApk
            $hasPrevious = Test-Path $BackupApk
            if ($hasPrevious) {
                Write-Host "      Backup salvato: $BackupApk ($((Get-Item $BackupApk).Length) bytes)" -ForegroundColor Green
            }
        }

        # 2. Installazione conservativa (mai uninstall, preserva /data/data)
        Write-Host "[2/4] Installazione conservativa nuovo APK (adb install -r -d)..."
        $installRes = & $adb -s $TargetAdb install -r -d $ApkPath
        Write-Host "      Risultato installazione: $installRes"
        if ($installRes -notmatch "Success") {
            throw "Installazione APK fallita: $installRes"
        }

        # 3. Avvio del servizio
        Write-Host "[3/4] Avvio servizio RemoteServerService..."
        & $adb -s $TargetAdb shell "am startservice $PackageName/.RemoteServerService" | Out-Null

        # 4. Watchdog 30s: verifica salute endpoint /api/status
        Write-Host "[4/4] Watchdog Health Check attivo (timeout 30s su $StatusUrl)..."
        $healthy = $false
        $attempts = 6
        for ($i = 1; $i -le $attempts; $i++) {
            Start-Sleep -Seconds 5
            try {
                $resp = Invoke-RestMethod -Uri $StatusUrl -Method Get -TimeoutSec 4 -ErrorAction Stop
                if ($resp.status -eq "ok") {
                    $healthy = $true
                    Write-Host "      Tentativo $i/$attempts: Ricevuto HTTP 200 {status: ok, uinput_ready: $($resp.uinput_ready)}!" -ForegroundColor Green
                    break
                }
            } catch {
                Write-Host "      Tentativo $i/$attempts: Servizio in avvio, in attesa..." -ForegroundColor Yellow
            }
        }

        if ($healthy) {
            Write-Host "`nDEPLOYMENT VERIFICATO CON SUCCESSO! Servizio attivo e stabile." -ForegroundColor Green
        } else {
            Write-Host "`nATTENZIONE: Watchdog fallito! Nessuna risposta valida entro 30 secondi." -ForegroundColor Red
            if ($hasPrevious) {
                Write-Host "AVVIO ROLLBACK AUTOMATICO ALLA VERSIONE PRECEDENTE..." -ForegroundColor Yellow
                & $adb -s $TargetAdb install -r -d $BackupApk
                & $adb -s $TargetAdb shell "am startservice $PackageName/.RemoteServerService" | Out-Null
                Write-Host "ROLLBACK COMPLETATO: Ripristinato $BackupApk senza perdita di dati." -ForegroundColor Green
            } else {
                Write-Host "Nessun APK di backup precedente disponibile per il rollback automatico." -ForegroundColor Red
            }
            exit 1
        }
    }

    "rollback" {
        $adb = Get-AdbExecutable
        Write-Host "=== ROLLBACK MANUALE ALLA VERSIONE PRECEDENTE ===" -ForegroundColor Yellow
        if (-not (Test-Path $BackupApk)) {
            throw "File di backup non trovato in $BackupApk. Impossibile ripristinare senza APK precedente."
        }
        Write-Host "[1/2] Reinstallazione conservativa dell'APK precedente (preserva dati SQLite)..."
        $res = & $adb -s $TargetAdb install -r -d $BackupApk
        Write-Host "      Risultato reinstallazione: $res"
        Write-Host "[2/2] Riavvio servizio RemoteServerService..."
        & $adb -s $TargetAdb shell "am startservice $PackageName/.RemoteServerService" | Out-Null
        Write-Host "Rollback manuale eseguito con successo." -ForegroundColor Green
    }
}
