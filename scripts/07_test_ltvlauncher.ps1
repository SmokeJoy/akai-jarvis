param(
    [Parameter(Mandatory=$false)]
    [string]$DeviceId = "192.168.1.103:5555",

    [Parameter(Mandatory=$false)]
    [ValidateSet("install", "launch", "rollback", "uninstall", "compare")]
    [string]$Action = "compare"
)

# scripts/07_test_ltvlauncher.ps1
# Gestione controllata e reversibile del collaudo di LTvLauncher
# NON cambia il launcher predefinito e NON modifica la partizione di sistema.

$ErrorActionPreference = 'Stop'

# Risoluzione percorso ADB
$adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
if (-not $adb) {
    $wingetAdb = Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Path
    if ($wingetAdb) { $adb = $wingetAdb }
}
if (-not $adb) { throw 'ADB non trovato: verifica che platform-tools sia installato.' }

$apkPath = Join-Path $PSScriptRoot "..\downloads\LTvLauncher-armeabi-v7a-release.apk"
$expectedHash = "99EEDB0136BD5EA5B17A6FA955B693FC44093A53BFBF353CF37277F9A45ED710"

$cultraviewPkg = "cn.cultraview.launcher.technical.open"
$cultraviewAct = "com.cultraview.launcher.technical.open.ui.MainActivity"

$ltvPkg = "com.leanbitlab.ltvL"
$ltvAct = "com.leanbitlab.ltvL.MainActivity"

# Connessione
Write-Host "Verifica collegamento ADB con $DeviceId..." -ForegroundColor Cyan
& $adb connect $DeviceId | Out-Null
Start-Sleep -Milliseconds 500

switch ($Action) {
    "install" {
        Write-Host "Verifica integrità SHA-256 APK locale..." -ForegroundColor Yellow
        if (-not (Test-Path $apkPath)) { throw "File APK non trovato in: $apkPath" }
        $actualHash = (Get-FileHash -Path $apkPath -Algorithm SHA256).Hash
        if ($actualHash -ne $expectedHash) {
            throw "Hash SHA-256 non corrispondente! Atteso: $expectedHash, Calcolato: $actualHash"
        }
        Write-Host "[OK] Hash SHA-256 verificato con successo." -ForegroundColor Green
        Write-Host "Installazione di LTvLauncher in parallelo (in /data/app, senza toccare /system)..." -ForegroundColor Cyan
        & $adb -s $DeviceId install -r $apkPath
        Write-Host "Installazione completata. Cultraview originale rimane intatto in /system/app." -ForegroundColor Green
    }

    "launch" {
        Write-Host "Avvio esplicito di LTvLauncher a schermo (senza impostarlo come predefinito)..." -ForegroundColor Cyan
        & $adb -s $DeviceId shell am start -n "$ltvPkg/$ltvAct"
        Write-Host "LTvLauncher avviato a schermo per il collaudo." -ForegroundColor Green
    }

    "rollback" {
        Write-Host "RIPRISTINO IMMEDIATO: richiamo a schermo del launcher stock Cultraview..." -ForegroundColor Yellow
        & $adb -s $DeviceId shell am start -n "$cultraviewPkg/$cultraviewAct"
        Write-Host "Schermata Cultraview originale ripristinata a schermo." -ForegroundColor Green
    }

    "uninstall" {
        Write-Host "Disinstallazione pulita di LTvLauncher dal dispositivo..." -ForegroundColor Yellow
        & $adb -s $DeviceId uninstall $ltvPkg
        Write-Host "LTvLauncher rimosso completamente. Nessuna traccia residua su /data." -ForegroundColor Green
        # Riavviamo Cultraview per sicurezza
        & $adb -s $DeviceId shell am start -n "$cultraviewPkg/$cultraviewAct"
    }

    "compare" {
        Write-Host "Rilevamento metriche comparative PSS..." -ForegroundColor Cyan
        $cultraMem = (& $adb -s $DeviceId shell dumpsys meminfo $cultraviewPkg 2>&1)
        $ltvMem    = (& $adb -s $DeviceId shell dumpsys meminfo $ltvPkg 2>&1)
        
        function Format-MemSummary([string[]]$rawMem, [string]$label) {
            $totalLine = $rawMem | Where-Object { $_ -match '^\s*TOTAL\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)' } | Select-Object -First 1
            if ($totalLine -and $totalLine -match '^\s*TOTAL\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)') {
                $pssMB = [math]::Round([int64]$matches[1] / 1024, 1)
                $privDirtyMB = [math]::Round([int64]$matches[2] / 1024, 1)
                $swapMB = [math]::Round([int64]$matches[4] / 1024, 1)
                Write-Host "[$label] PSS Totale: $pssMB MB | RAM Privata: $privDirtyMB MB | Swap ZRAM: $swapMB MB" -ForegroundColor Green
            } else {
                Write-Host "[$label] Dati memoria non disponibili (processo non attivo)" -ForegroundColor Yellow
            }
        }
        
        Write-Host "`n--- CONFRONTO MEMORIA DEI DUE LAUNCHER ---" -ForegroundColor Cyan
        Format-MemSummary $ltvMem "LTvLauncher"
        Format-MemSummary $cultraMem "Cultraview Stock"
        
        $meminfo = & $adb -s $DeviceId shell cat /proc/meminfo
        $avail = ($meminfo | Where-Object { $_ -match 'MemAvailable:\s+(\d+)' })
        Write-Host "`nStato attuale memoria di sistema:" -ForegroundColor Gray
        $avail
    }
}
