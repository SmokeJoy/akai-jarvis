param([string]$DeviceId = "")
# Legge dati via ADB e scrive solo sul PC. NON e' un backup del firmware.
$ErrorActionPreference = 'Stop'
$adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
if (-not $adb) { throw 'ADB non trovato. Esegui adb version in un nuovo terminale.' }
$lines = @(& $adb devices)
$active = @($lines | ForEach-Object { if ($_ -match '^([^\s]+)\s+device\s*$') { $Matches[1] } })
if (-not $DeviceId) {
    if ($active.Count -ne 1) { throw "Dispositivi autorizzati: $($active.Count). Usa -DeviceId se ce ne sono piu' di uno." }
    $DeviceId = $active[0]
}
if ($active -notcontains $DeviceId) { throw "Il dispositivo '$DeviceId' non risulta connesso e autorizzato." }
$root = Join-Path $PSScriptRoot '..\backups'
$dir = Join-Path $root ('audit_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$failures = @()
function Save-Read([string]$Name, [string[]]$Arguments) {
    $content = @(& $adb -s $DeviceId @Arguments 2>&1)
    $status = $LASTEXITCODE
    $content | Out-File -FilePath (Join-Path $dir $Name) -Encoding UTF8
    if ($status -ne 0) { $script:failures += $Name; Write-Warning "Lettura fallita: $Name (exit $status)" }
}
Save-Read 'getprop.txt' @('shell','getprop')
Save-Read 'cpuinfo.txt' @('shell','cat','/proc/cpuinfo')
Save-Read 'meminfo.txt' @('shell','cat','/proc/meminfo')
Save-Read 'free_ram.txt' @('shell','free','-m')
Save-Read 'partitions.txt' @('shell','cat','/proc/partitions')
Save-Read 'storage_df.txt' @('shell','df','-h')
Save-Read 'packages_all_details.txt' @('shell','pm','list','packages','-f','-u')
Save-Read 'packages_third_party.txt' @('shell','pm','list','packages','-3')
Save-Read 'packages_system.txt' @('shell','pm','list','packages','-s')
Save-Read 'packages_disabled.txt' @('shell','pm','list','packages','-d')
Save-Read 'current_launcher.txt' @('shell','cmd','package','resolve-activity','-a','android.intent.action.MAIN','-c','android.intent.category.HOME')
Save-Read 'settings_global.txt' @('shell','settings','list','global')
Save-Read 'settings_system.txt' @('shell','settings','list','system')
Save-Read 'settings_secure.txt' @('shell','settings','list','secure')
Save-Read 'dumpsys_meminfo.txt' @('shell','dumpsys','meminfo')
function Prop([string]$key) { ((& $adb -s $DeviceId shell getprop $key) | Out-String).Trim() }
$summary = @"
AKAI TV — AUDIT (SOLA LETTURA)
Modello: $(Prop 'ro.product.model')
Dispositivo: $(Prop 'ro.product.device')
Board: $(Prop 'ro.product.board')
Piattaforma: $(Prop 'ro.board.platform')
Android: $(Prop 'ro.build.version.release')
SDK: $(Prop 'ro.build.version.sdk')
Cartella audit locale: $dir
Letture fallite: $($failures.Count)
"@
$summary | Out-File (Join-Path $dir 'AUDIT_SUMMARY.txt') -Encoding UTF8
Write-Host $summary -ForegroundColor Green
if ($failures.Count -gt 0) { Write-Warning "Alcuni file non sono stati acquisiti: $($failures -join ', ')" }
Write-Warning 'I log completi possono includere identificatori del dispositivo, indirizzi e impostazioni private. Condividi inizialmente solo AUDIT_SUMMARY.txt.'
Write-Warning 'Questo audit NON crea un firmware di ripristino.'
