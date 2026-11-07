param([string]$DeviceId = "")
# Cattura dati diagnostici in sola lettura. Non usa grep sul televisore.
$ErrorActionPreference = 'Stop'
$adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
if (-not $adb) { throw 'ADB non trovato.' }
$lines = @(& $adb devices)
$active = @($lines | ForEach-Object { if ($_ -match '^([^\s]+)\s+device\s*$') { $Matches[1] } })
if (-not $DeviceId) {
    if ($active.Count -ne 1) { throw 'Indica -DeviceId; serve un unico dispositivo autorizzato.' }
    $DeviceId = $active[0]
}
if ($active -notcontains $DeviceId) { throw 'TV non autorizzata o non presente.' }
Read-Host 'Quando appare il popup Eco, premi INVIO qui'
$backupDir = Join-Path $PSScriptRoot '..\backups'
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$window = @(& $adb -s $DeviceId shell dumpsys window 2>&1)
$windowExit = $LASTEXITCODE
$activity = @(& $adb -s $DeviceId shell dumpsys activity activities 2>&1)
$activityExit = $LASTEXITCODE
$wfile = Join-Path $backupDir "eco_window_$stamp.txt"
$afile = Join-Path $backupDir "eco_activity_$stamp.txt"
$window | Out-File $wfile -Encoding UTF8
$activity | Out-File $afile -Encoding UTF8
$keywords = 'mCurrentFocus|mFocusedApp|mFocusedWindow|mTopFocusedDisplay|mResumedActivity|topResumedActivity|ResumedActivity|mFocusedActivity'
$summary = @($window + $activity | Select-String -Pattern $keywords | ForEach-Object { $_.Line })
$summaryFile = Join-Path $backupDir "eco_summary_$stamp.txt"
$summary | Out-File $summaryFile -Encoding UTF8
Write-Host "Riepilogo: $summaryFile" -ForegroundColor Green
Write-Host "Dati completi: $wfile ; $afile"
if ($windowExit -ne 0 -or $activityExit -ne 0) { Write-Warning 'Uno o piu comandi dumpsys hanno segnalato errore. Verifica i file.' }
Write-Warning 'Se il popup e un Toast o una finestra di sistema, il focus potrebbe non identificare il processo responsabile.'
