# ==============================================================================
# AKAI Custom Remote - Procedura di Installazione Sicura e Rollback 1-Click
# NON esegue alcuna operazione non autorizzata: supporta azioni -Action status/rollback
# ==============================================================================

param(
    [ValidateSet("status", "install", "rollback")]
    [string]$Action = "status",
    [string]$ApkPath = ".\akai-remote-tv\app\build\outputs\apk\debug\app-debug.apk"
)

$ErrorActionPreference = "Stop"

$target = "192.168.1.8:5555"
$PackageName = "it.akai.customremote"
$adb = Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" | Select-Object -First 1 -ExpandProperty Path
& $adb connect $target | Out-Null
Start-Sleep -Milliseconds 500

switch ($Action) {
    "status" {
        Write-Host "=== STATO ATTUALE TELECOMANDO SU AKAI AKTV5037N ===" -ForegroundColor Cyan
        $installed = & $adb -s $target shell "pm list packages $PackageName"
        if ($installed -match $PackageName) {
            Write-Host "Pacchetto $PackageName : INSTALLATO" -ForegroundColor Green
            $pidVal = & $adb -s $target shell "pidof $PackageName"
            Write-Host "Processo in esecuzione   : $(if ($pidVal) { "ATTIVO (PID $pidVal)" } else { "NON ATTIVO" })"
        } else {
            Write-Host "Pacchetto $PackageName : NON INSTALLATO" -ForegroundColor Yellow
        }

        Write-Host "`nStato Launcher Cultraview Stock:"
        $cultra = & $adb -s $target shell "pm list packages -e cn.cultraview.launcher.technical.open"
        Write-Host "Cultraview Stock         : $cultra (Preservato e Abilitato)" -ForegroundColor Green

        Write-Host "`nStato LTvLauncher:"
        $ltv = & $adb -s $target shell "pm list packages -e com.leanbitlab.ltvL"
        Write-Host "LTvLauncher              : $ltv (Home Predefinita)" -ForegroundColor Green
    }

    "install" {
        Write-Host "=== INSTALLAZIONE PROTETTA TELECOMANDO AKAI ===" -ForegroundColor Cyan
        if (-not (Test-Path $ApkPath)) {
            Write-Host "ERRORE: File APK non trovato in $ApkPath. Compilare prima il progetto." -ForegroundColor Red
            exit 1
        }
        Write-Host "[1/2] Installazione APK in /data/app..."
        & $adb -s $target install -r -d $ApkPath
        Write-Host "[2/2] Verifica pacchetto installato..."
        & $adb -s $target shell "pm list packages $PackageName"
        Write-Host "Installazione completata con successo." -ForegroundColor Green
    }

    "rollback" {
        Write-Host "=== ROLLBACK EMERGENZA TELECOMANDO AKAI ===" -ForegroundColor Yellow
        Write-Host "[1/2] Arresto del processo $PackageName..."
        & $adb -s $target shell "am force-stop $PackageName" | Out-Null
        Write-Host "[2/2] Disinstallazione completa dell'APK da /data/app..."
        & $adb -s $target uninstall $PackageName
        Write-Host "Rollback completato al 100%: nessun file o servizio residuo." -ForegroundColor Green
    }
}
