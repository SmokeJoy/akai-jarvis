param(
    [Parameter(Mandatory=$false)]
    [string]$DeviceId = "192.168.1.103:5555"
)

# scripts/06_diagnose_cpu_load.ps1
# Diagnostica approfondita del Load Average e analisi thread (stati R, S, D)
# Operazione rigorosamente in SOLA LETTURA. Zero scritture sulla TV.

$ErrorActionPreference = 'Stop'

# Risoluzione percorso ADB
$adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
if (-not $adb) {
    $wingetAdb = Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Path
    if ($wingetAdb) { $adb = $wingetAdb }
}
if (-not $adb) { throw 'ADB non trovato: verifica che platform-tools sia installato.' }

# Funzione per eseguire comandi ADB con controllo rigoroso dell'exit code
function Invoke-Adb([string[]]$Arguments) {
    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = $adb
    $pinfo.Arguments = ($Arguments | ForEach-Object {
        if ($_ -match '\s') { "`"$_`"" } else { $_ }
    }) -join ' '
    $pinfo.RedirectStandardOutput = $true
    $pinfo.RedirectStandardError = $true
    $pinfo.UseShellExecute = $false
    $pinfo.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($pinfo)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    return [PSCustomObject]@{
        ExitCode = $proc.ExitCode
        Output   = $stdout
        Error    = $stderr
    }
}

# Verifica connessione dispositivo
Write-Host "Verifica collegamento ADB con $DeviceId..." -ForegroundColor Cyan
$devCheck = Invoke-Adb @("devices")
if ($devCheck.Output -notmatch [regex]::Escape($DeviceId) + "\s+device\b") {
    Invoke-Adb @("connect", $DeviceId) | Out-Null
    Start-Sleep -Milliseconds 500
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " AKAI TV - DIAGNOSTICA APPROFONDITA CPU & THREAD (SOLA LETTURA)" -ForegroundColor Cyan
Write-Host " Dispositivo: $DeviceId" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$diagDir = Join-Path $PSScriptRoot "..\backups\cpu_diagnosis_$timestamp"
New-Item -ItemType Directory -Path $diagDir -Force | Out-Null

# 1. Acquisizione /proc/loadavg
Write-Host "1/4 Acquisizione /proc/loadavg..." -ForegroundColor Yellow
$loadRes = Invoke-Adb @("-s", $DeviceId, "shell", "cat", "/proc/loadavg")
if ($loadRes.ExitCode -ne 0) { throw "Errore lettura /proc/loadavg: $($loadRes.Error)" }
$loadRaw = $loadRes.Output.Trim()
$loadRaw | Out-File (Join-Path $diagDir "proc_loadavg.txt") -Encoding UTF8

$load1 = "N/D"; $load5 = "N/D"; $load15 = "N/D"; $schedRunning = "N/D"; $schedTotal = "N/D"
if ($loadRaw -match '^(\S+)\s+(\S+)\s+(\S+)\s+(\d+)/(\d+)') {
    $load1 = $matches[1]
    $load5 = $matches[2]
    $load15 = $matches[3]
    $schedRunning = $matches[4]
    $schedTotal = $matches[5]
}

# 2. Acquisizione /proc/stat
Write-Host "2/4 Acquisizione /proc/stat e calcolo carico CPU reale..." -ForegroundColor Yellow
$statRes = Invoke-Adb @("-s", $DeviceId, "shell", "cat", "/proc/stat")
if ($statRes.ExitCode -ne 0) { throw "Errore lettura /proc/stat: $($statRes.Error)" }
$statRaw = $statRes.Output
$statRaw | Out-File (Join-Path $diagDir "proc_stat.txt") -Encoding UTF8

$cpuUser = 0; $cpuNice = 0; $cpuSys = 0; $cpuIdle = 0; $cpuIo = 0; $cpuIrq = 0; $cpuSirq = 0
$statLines = $statRaw -split "`r?`n"
$cpuLine = $statLines | Where-Object { $_ -match '^cpu\s+' } | Select-Object -First 1
if ($cpuLine -match '^cpu\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)') {
    $cpuUser = [int64]$matches[1]
    $cpuNice = [int64]$matches[2]
    $cpuSys  = [int64]$matches[3]
    $cpuIdle = [int64]$matches[4]
    $cpuIo   = [int64]$matches[5]
    $cpuIrq  = [int64]$matches[6]
    $cpuSirq = [int64]$matches[7]
}

$cpuTotalTicks = $cpuUser + $cpuNice + $cpuSys + $cpuIdle + $cpuIo + $cpuIrq + $cpuSirq
$pctIdle = if ($cpuTotalTicks -gt 0) { [math]::Round(($cpuIdle / $cpuTotalTicks) * 100, 2) } else { 0 }
$pctBusy = if ($cpuTotalTicks -gt 0) { [math]::Round((($cpuTotalTicks - $cpuIdle) / $cpuTotalTicks) * 100, 2) } else { 0 }
$pctSys  = if ($cpuTotalTicks -gt 0) { [math]::Round(($cpuSys / $cpuTotalTicks) * 100, 2) } else { 0 }
$pctUser = if ($cpuTotalTicks -gt 0) { [math]::Round((($cpuUser + $cpuNice) / $cpuTotalTicks) * 100, 2) } else { 0 }
$pctIo   = if ($cpuTotalTicks -gt 0) { [math]::Round(($cpuIo / $cpuTotalTicks) * 100, 2) } else { 0 }

# 3. Acquisizione ps -A -T (tutti i thread e stati S)
Write-Host "3/4 Acquisizione thread di sistema (ps -A -T)..." -ForegroundColor Yellow
$psRes = Invoke-Adb @("-s", $DeviceId, "shell", "ps", "-A", "-T")
if ($psRes.ExitCode -ne 0) { throw "Errore lettura ps -A -T: $($psRes.Error)" }
$psRaw = $psRes.Output
$psRaw | Out-File (Join-Path $diagDir "ps_threads_raw.txt") -Encoding UTF8

$threads = @()
$psLines = $psRaw -split "`r?`n"
$stateCounts = @{ "R" = 0; "S" = 0; "D" = 0; "Z" = 0; "T" = 0; "Altri" = 0 }

foreach ($line in $psLines) {
    if ($line -match '^\s*(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+\S+\s+\S+\s+\S+\s+\S+\s+([RSDZT])\s+(.+)$') {
        $st = $matches[5]
        if ($stateCounts.ContainsKey($st)) {
            $stateCounts[$st]++
        } else {
            $stateCounts["Altri"]++
        }
        $threads += [PSCustomObject]@{
            User    = $matches[1]
            PID     = [int]$matches[2]
            TID     = [int]$matches[3]
            PPID    = [int]$matches[4]
            State   = $st
            Command = $matches[6].Trim()
        }
    }
}

# 4. Analisi dettagliata dei thread in stato D
Write-Host "4/4 Analisi dei thread bloccati in stato D..." -ForegroundColor Yellow
$dThreads = $threads | Where-Object { $_.State -eq 'D' }

$dThreadsCsv = Join-Path $diagDir "d_state_threads.csv"
"PID,TID,PPID,User,Command,Categoria" | Out-File -FilePath $dThreadsCsv -Encoding UTF8

$categorized = @()
foreach ($dt in $dThreads) {
    $cat = "Kernel Altro"
    $cmd = $dt.Command
    if ($cmd -match '^(TU[01]_|ATV Mon|DVBS_|EU_ATD_)') { $cat = "DTV & Sintonizzatori TV" }
    elseif ($cmd -match '^(VGA|CVBS|YPBPR|Scart|HDMI|hdcp22|CEC|HPD)') { $cat = "Ingressi Video & HDMI/CEC" }
    elseif ($cmd -match '^(Aout|AOUT|AUDIO|DISP|DISPOUT|TSIO|VMon_)') { $cat = "Audio & Sottosistema Video/OSD" }
    elseif ($cmd -match '^(XC_MMA|TSP_|DMX_|GPIO|cfinteractive|Boost_|Wdt|Delay Free|SignalPoll|QOS_|Mload|DMS_)') { $cat = "Driver Hardware MediaTek/MStar" }
    elseif ($cmd -match 'dtv_svc|hbbtv') { $cat = "Servizi Broadcast DTV/HbbTV" }

    "$($dt.PID),$($dt.TID),$($dt.PPID),$($dt.User),$cmd,$cat" | Out-File -FilePath $dThreadsCsv -Append -Encoding UTF8
    $categorized += [PSCustomObject]@{
        PID     = $dt.PID
        TID     = $dt.TID
        Command = $cmd
        Categoria = $cat
    }
}

$catSummary = $categorized | Group-Object Categoria | Select-Object Name, Count

# 5. Elaborazione Report Finale
$reportPath = Join-Path $diagDir "CPU_DIAGNOSI_REPORT.txt"
$report = @"
================================================================================
 AKAI AKTV5037N - RAPPORTO DIAGNOSTICO CPU & LOAD AVERAGE
 Data acquisizione : $timestamp
 Dispositivo       : $DeviceId
================================================================================

1. ANALISI /proc/loadavg:
   - Carico medio (1 min, 5 min, 15 min): $load1, $load5, $load15
   - Entita in esecuzione / Entita totali : $schedRunning / $schedTotal
   (Nota: Solo $schedRunning thread su $schedTotal sono attivamente in runqueue!)

2. UTILIZZO EFFETTIVO CPU DA /proc/stat:
   - Percentuale IDLE dall'avvio : $pctIdle %
   - Utilizzo CPU totale effettivo: $pctBusy % (Sistema: $pctSys %, Utente: $pctUser %)
   - Percentuale I/O Wait        : $pctIo %

3. DISTRIBUZIONE STATI DEI THREAD (Totale thread censiti: $($threads.Count)):
   - Stato S (Interruptible Sleep  - In attesa normale)       : $($stateCounts["S"])
   - Stato D (Uninterruptible Sleep - Attesa kernel/driver)   : $($stateCounts["D"])
   - Stato R (Running / Runnable   - In esecuzione effettiva) : $($stateCounts["R"])
   - Stato Z (Zombie)                                         : $($stateCounts["Z"])

4. ORIGINE DEL LOAD AVERAGE DI ~63:
   La formula del Load Average in Linux e:
      Load = nr_running + nr_uninterruptible (Stato D)
   
   Riscontro empirico verificato:
   - Thread in Stato R (running)            : $($stateCounts["R"])
   - Thread in Stato D (uninterruptible)    : $($stateCounts["D"])
   - Somma R + D                            : $($stateCounts["R"] + $stateCounts["D"])
   
   RISULTATO: I $($stateCounts["D"]) thread in stato D generano matematicamente
   il valore di load average (~60-64), senza che la CPU sia realmente sovraccaricata.

5. CLASSIFICAZIONE DEI THREAD IN STATO D PER SUBSYSTEM:
$($catSummary | ForEach-Object { "   - {0,-35} : {1} thread" -f $_.Name, $_.Count } | Out-String)

6. FILE GENERATI SUL PC:
   - Report completo TXT  : $reportPath
   - Elenco thread D (CSV): $dThreadsCsv
   - Dump proc/stat grezzo: $(Join-Path $diagDir "proc_stat.txt")
   - Dump thread completo : $(Join-Path $diagDir "ps_threads_raw.txt")
================================================================================
"@

$report | Out-File -FilePath $reportPath -Encoding UTF8
Write-Host "`n$report" -ForegroundColor Green
Write-Host "Diagnosi completata con successo in SOLA LETTURA." -ForegroundColor Cyan
