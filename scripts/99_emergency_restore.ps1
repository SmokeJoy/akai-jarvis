param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z_][A-Za-z0-9_.]+$')][string]$PackageName,
    [string]$DeviceId = ""
)
# RIPRISTINO MANUALE MIRATO. NON e' un rollback totale e non deve essere usato durante la fase 1.
$ErrorActionPreference = 'Stop'
$adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
if (-not $adb) {
    $wingetAdb = Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Path
    if ($wingetAdb) { $adb = $wingetAdb }
}
if (-not $adb) { throw 'ADB non trovato.' }
$lines = @(& $adb devices)
$active = @($lines | ForEach-Object { if ($_ -match '^([^\s]+)\s+device\s*$') { $Matches[1] } })
if (-not $DeviceId) {
    if ($active.Count -ne 1) { throw 'Specificare -DeviceId se non vi e un unico dispositivo autorizzato.' }
    $DeviceId = $active[0]
}
if ($active -notcontains $DeviceId) { throw 'Il dispositivo scelto non e autorizzato.' }
$disabled = @(& $adb -s $DeviceId shell pm list packages -d)
if ($disabled -notcontains "package:$PackageName") { throw "Il pacchetto $PackageName non risulta disabilitato: nessuna modifica eseguita." }
Write-Warning "ATTENZIONE: verra riabilitato SOLO $PackageName sul dispositivo $DeviceId."
Write-Warning 'Usalo solo se hai documentato che questo pacchetto e stato disabilitato durante il progetto.'
$confirm = Read-Host "Scrivi esattamente RIPRISTINA per continuare"
if ($confirm -cne 'RIPRISTINA') { Write-Host 'Annullato.'; exit 0 }
$result = & $adb -s $DeviceId shell pm enable --user 0 $PackageName 2>&1
$result | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw 'Ripristino fallito: controllare lo stato del pacchetto.' }
Write-Host 'Richiesta di riabilitazione inviata. Verificare direttamente sulla TV.' -ForegroundColor Green
