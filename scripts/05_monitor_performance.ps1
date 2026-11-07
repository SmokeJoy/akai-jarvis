param(
    [Parameter(Mandatory=$false)]
    [string]$DeviceId = "192.168.1.103:5555",

    [Parameter(Mandatory=$false)]
    [ValidateSet("riposo", "utilizzo")]
    [string]$SessionType = "utilizzo",

    [Parameter(Mandatory=$false)]
    [int]$DurationSeconds = 60,

    [Parameter(Mandatory=$false)]
    [int]$IntervalSeconds = 5
)

# scripts/05_monitor_performance.ps1
# Monitoraggio prestazioni Akai AKTV5037N in tempo reale con calcolo differenziale CPU (/proc/stat)
# Modalita: 'riposo' (baseline) oppure 'utilizzo' (durante test/carico attivo)
# Operazione rigorosamente in SOLA LETTURA. Zero scritture sulla TV.

$ErrorActionPreference = 'Stop'

# 1. Risoluzione robusta del percorso ADB
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

# 2. Connessione e verifica dispositivo
Write-Host "Verifica collegamento ADB con $DeviceId..." -ForegroundColor Cyan
$devCheck = Invoke-Adb @("devices")
if ($devCheck.Output -notmatch [regex]::Escape($DeviceId) + "\s+device\b") {
    Write-Host "Tentativo di connessione TCP verso $DeviceId..." -ForegroundColor Yellow
    $connRes = Invoke-Adb @("connect", $DeviceId)
    if ($connRes.ExitCode -ne 0) {
        throw "Impossibile connettersi ad ADB su $DeviceId. Errore: $($connRes.Error)"
    }
    Start-Sleep -Seconds 1
    $devCheck = Invoke-Adb @("devices")
    if ($devCheck.Output -notmatch [regex]::Escape($DeviceId) + "\s+device\b") {
        throw "Dispositivo $DeviceId non riconosciuto come autorizzato. Output ADB:`n$($devCheck.Output)"
    }
}
Write-Host "[OK] Dispositivo $DeviceId pronto e autorizzato." -ForegroundColor Green

# 3. Funzione di parsing meminfo corretta senza interpolazione ambigua
function Parse-MemField([string]$meminfoText, [string]$field) {
    $escapedField = [regex]::Escape($field)
    $pattern = "(?m)^" + $escapedField + ":\s+(\d+)\s+kB"
    $match = [regex]::Match($meminfoText, $pattern)
    if ($match.Success) {
        $kbVal = [int64]$match.Groups[1].Value
        return [math]::Round($kbVal / 1024, 2) # Conversione in MiB
    }
    return 0.0
}

# Funzione per estrarre tick CPU da /proc/stat
function Parse-CpuTicks([string]$statText) {
    $line = ($statText -split "`r?`n") | Where-Object { $_ -match '^cpu\s+' } | Select-Object -First 1
    if ($line -match '^cpu\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)') {
        return @{
            User    = [int64]$matches[1]
            Nice    = [int64]$matches[2]
            Sys     = [int64]$matches[3]
            Idle    = [int64]$matches[4]
            IoWait  = [int64]$matches[5]
            Irq     = [int64]$matches[6]
            SoftIrq = [int64]$matches[7]
            Total   = [int64]$matches[1] + [int64]$matches[2] + [int64]$matches[3] + [int64]$matches[4] + [int64]$matches[5] + [int64]$matches[6] + [int64]$matches[7]
        }
    }
    return $null
}

# 4. Preparazione cartella e file di report sul PC
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupDir = Join-Path $PSScriptRoot "..\backups\perf_${SessionType}_$timestamp"
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

$csvPath = Join-Path $backupDir "metrics_timeseries.csv"
$txtSummaryPath = Join-Path $backupDir "PERFORMANCE_REPORT_${SessionType}.txt"
$dumpsysStartPath = Join-Path $backupDir "dumpsys_meminfo_start.txt"
$dumpsysEndPath = Join-Path $backupDir "dumpsys_meminfo_end.txt"
$lmkLogPath = Join-Path $backupDir "lmk_events.txt"
$rawTopPath = Join-Path $backupDir "raw_top_samples.txt"
$zipBundlePath = Join-Path $PSScriptRoot "..\backups\perf_${SessionType}_${timestamp}.zip"

# Inizializza intestazione CSV arricchita con CPU differenziale e Jitter
"Timestamp,Sample,Elapsed_Sec,Jitter_Sec,Interval_CPU_Busy_Pct,Interval_CPU_User_Pct,Interval_CPU_Sys_Pct,Interval_CPU_Io_Pct,Load1m,Load5m,Load15m,MemTotal_MB,MemAvailable_MB,MemAvailable_Pct,MemFree_MB,Cached_MB,SwapUsed_MB,CpuFreq_kHz,TopProcess_PID,TopProcess_Name,TopProcess_CPU_Pct,LMK_Kills_Total" | Out-File -FilePath $csvPath -Encoding UTF8

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " AKAI TV - SESSIONE MONITORAGGIO: $( $SessionType.ToUpper() )" -ForegroundColor Cyan
Write-Host " Durata: $DurationSeconds secondi | Campionamento: ogni $IntervalSeconds secondi (con pacing attivo)" -ForegroundColor White
Write-Host " Calcolo CPU: differenziale puntuale intervallo per intervallo da /proc/stat" -ForegroundColor White
Write-Host " Destinazione PC: $backupDir" -ForegroundColor White
Write-Host "==========================================================" -ForegroundColor Cyan

# Snapshot iniziale PSS
Write-Host "Acquisizione snapshot iniziale PSS (dumpsys meminfo)..." -ForegroundColor Gray
$dStart = Invoke-Adb @("-s", $DeviceId, "shell", "dumpsys", "meminfo")
if ($dStart.ExitCode -eq 0) { $dStart.Output | Out-File $dumpsysStartPath -Encoding UTF8 }

# Lettura iniziale tick CPU per il primo delta
$prevStatRes = Invoke-Adb @("-s", $DeviceId, "shell", "cat", "/proc/stat")
$prevCpuTicks = if ($prevStatRes.ExitCode -eq 0) { Parse-CpuTicks $prevStatRes.Output } else { $null }

$samples = @()
$totalIterations = [math]::Floor($DurationSeconds / $IntervalSeconds)
$overallStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

Write-Host "`nAvvio campionamento periodico (12 misurazioni)..." -ForegroundColor Yellow
Write-Host ("{0,-6} {1,-9} {2,-7} {3,-9} {4,-15} {5,-9} {6,-23} {7,-8}" -f "#", "Ora", "Sec", "CPU % Real", "MemAvail (MB)", "Load 1m", "Top Processo", "LMK Kill") -ForegroundColor Cyan
Write-Host ("-" * 95) -ForegroundColor Gray

for ($i = 1; $i -le $totalIterations; $i++) {
    $iterationStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $now = Get-Date
    $timeStr = $now.ToString("HH:mm:ss")
    $isoTime = $now.ToString("yyyy-MM-ddTHH:mm:ss")
    $elapsedSec = [math]::Round($overallStopwatch.ElapsedMilliseconds / 1000, 2)
    $targetSec = ($i - 1) * $IntervalSeconds
    $jitterSec = [math]::Round($elapsedSec - $targetSec, 2)

    # A. Lettura differenziale /proc/stat per CPU reale dell'intervallo
    $statRes = Invoke-Adb @("-s", $DeviceId, "shell", "cat", "/proc/stat")
    $currCpuTicks = if ($statRes.ExitCode -eq 0) { Parse-CpuTicks $statRes.Output } else { $null }

    $intervalCpuBusy = 0.0; $intervalCpuUser = 0.0; $intervalCpuSys = 0.0; $intervalCpuIo = 0.0
    if ($prevCpuTicks -and $currCpuTicks) {
        $deltaTotal = $currCpuTicks.Total - $prevCpuTicks.Total
        $deltaIdle  = $currCpuTicks.Idle  - $prevCpuTicks.Idle
        $deltaUser  = ($currCpuTicks.User + $currCpuTicks.Nice) - ($prevCpuTicks.User + $prevCpuTicks.Nice)
        $deltaSys   = $currCpuTicks.Sys   - $prevCpuTicks.Sys
        $deltaIo    = $currCpuTicks.IoWait- $prevCpuTicks.IoWait

        if ($deltaTotal -gt 0) {
            $intervalCpuBusy = [math]::Round((($deltaTotal - $deltaIdle) / $deltaTotal) * 100, 1)
            $intervalCpuUser = [math]::Round(($deltaUser / $deltaTotal) * 100, 1)
            $intervalCpuSys  = [math]::Round(($deltaSys / $deltaTotal) * 100, 1)
            $intervalCpuIo   = [math]::Round(($deltaIo / $deltaTotal) * 100, 1)
        }
    }
    $prevCpuTicks = $currCpuTicks

    # B. Lettura /proc/meminfo
    $memRes = Invoke-Adb @("-s", $DeviceId, "shell", "cat", "/proc/meminfo")
    if ($memRes.ExitCode -ne 0) {
        Write-Warning "[$timeStr] Errore lettura /proc/meminfo: $($memRes.Error)"
        Start-Sleep -Seconds $IntervalSeconds
        continue
    }
    $memText = $memRes.Output

    $memTotal = Parse-MemField $memText "MemTotal"
    $memFree = Parse-MemField $memText "MemFree"
    $memAvailable = Parse-MemField $memText "MemAvailable"
    $cached = Parse-MemField $memText "Cached"
    $buffers = Parse-MemField $memText "Buffers"
    $swapTotal = Parse-MemField $memText "SwapTotal"
    $swapFree = Parse-MemField $memText "SwapFree"
    $swapUsed = [math]::Round($swapTotal - $swapFree, 2)
    $availPct = if ($memTotal -gt 0) { [math]::Round(($memAvailable / $memTotal) * 100, 1) } else { 0.0 }

    # C. Lettura /proc/loadavg
    $loadRes = Invoke-Adb @("-s", $DeviceId, "shell", "cat", "/proc/loadavg")
    $load1 = 0.0; $load5 = 0.0; $load15 = 0.0
    if ($loadRes.ExitCode -eq 0 -and $loadRes.Output -match '^(\d+\.\d+)\s+(\d+\.\d+)\s+(\d+\.\d+)') {
        $load1 = [double]$matches[1]
        $load5 = [double]$matches[2]
        $load15 = [double]$matches[3]
    }

    # D. Frequenza CPU core 0
    $freqRes = Invoke-Adb @("-s", $DeviceId, "shell", "cat", "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq")
    $cpuFreq = if ($freqRes.ExitCode -eq 0) { $freqRes.Output.Trim() } else { "N/D" }

    # E. Top processo per CPU (escludendo il comando top stesso e salvando output grezzo)
    $topRes = Invoke-Adb @("-s", $DeviceId, "shell", "top", "-n", "1", "-b", "-m", "10")
    $topProcPid = "N/D"
    $topProcName = "N/D"
    $topProcCpu = "0"
    $topProcMem = "0"

    if ($topRes.ExitCode -eq 0) {
        "--- CAMPIONE $i ($timeStr - ${elapsedSec}s | Jitter: ${jitterSec}s | CPU Stat: $intervalCpuBusy%) ---" | Out-File -FilePath $rawTopPath -Append -Encoding UTF8
        $topRes.Output | Out-File -FilePath $rawTopPath -Append -Encoding UTF8

        $lines = $topRes.Output -split "`r?`n"
        foreach ($line in $lines) {
            if ($line -match '^\s*(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)\s+(\S+)\s+(.+)$') {
                $cmdArgs = $matches[12].Trim()
                if ($cmdArgs -match '^top\b') { continue }

                $topProcPid  = $matches[1]
                $topProcCpu  = $matches[9]
                $topProcMem  = $matches[10]
                $topProcName = $cmdArgs
                break
            }
        }
    }

    # F. Verifica eventi reali Low Memory Killer (esclusi kill normali)
    $lmkRes = Invoke-Adb @("-s", $DeviceId, "shell", "logcat", "-d", "-s", "lowmemorykiller:V", "lmkd:V")
    $lmkCount = 0
    if ($lmkRes.ExitCode -eq 0) {
        $lmkMatches = @($lmkRes.Output -split "`r?`n" | Where-Object {
            $_ -match 'lowmemorykiller:\s*Killing' -or $_ -match 'lmkd:\s*Kill\b'
        })
        $lmkCount = $lmkMatches.Count
    }

    # Registra campione
    $record = [PSCustomObject]@{
        Timestamp            = $isoTime
        Sample               = $i
        Elapsed_Sec          = $elapsedSec
        Jitter_Sec           = $jitterSec
        Interval_CPU_Busy_Pct= $intervalCpuBusy
        Interval_CPU_User_Pct= $intervalCpuUser
        Interval_CPU_Sys_Pct = $intervalCpuSys
        Interval_CPU_Io_Pct  = $intervalCpuIo
        Load1m               = $load1
        Load5m               = $load5
        Load15m              = $load15
        MemTotal_MB          = $memTotal
        MemAvailable_MB      = $memAvailable
        MemAvailable_Pct     = $availPct
        MemFree_MB           = $memFree
        Cached_MB            = $cached
        SwapUsed_MB          = $swapUsed
        CpuFreq_kHz          = $cpuFreq
        TopProcess_PID       = $topProcPid
        TopProcess_Name      = $topProcName
        TopProcess_CPU_Pct   = $topProcCpu
        LMK_Kills_Total      = $lmkCount
    }
    $samples += $record

    # Scrittura su CSV
    "$isoTime,$i,$elapsedSec,$jitterSec,$intervalCpuBusy,$intervalCpuUser,$intervalCpuSys,$intervalCpuIo,$load1,$load5,$load15,$memTotal,$memAvailable,$availPct,$memFree,$cached,$swapUsed,$cpuFreq,$topProcPid,$topProcName,$topProcCpu,$lmkCount" | Out-File -FilePath $csvPath -Append -Encoding UTF8

    # Stampa riga a video formattata
    $shortName = if ($topProcName.Length -gt 22) { $topProcName.Substring(0, 19) + "..." } else { $topProcName }
    Write-Host ("{0,-6} {1,-9} {2,-7} {3,-9} {4,-15} {5,-9} {6,-23} {7,-8}" -f "$i/$totalIterations", $timeStr, "${elapsedSec}s", "$intervalCpuBusy %", "$memAvailable MB", $load1, $shortName, $lmkCount) -ForegroundColor White

    # Pacing attivo: calcola tempo effettivo trascorso ed effettua sleep solo per la frazione rimanente
    if ($i -lt $totalIterations) {
        $iterElapsedMs = $iterationStopwatch.ElapsedMilliseconds
        $targetMs = $IntervalSeconds * 1000
        $remainingSleepMs = [math]::Max(50, [int]($targetMs - $iterElapsedMs))
        Start-Sleep -Milliseconds $remainingSleepMs
    }
}

$overallStopwatch.Stop()
$totalRealDurationSec = [math]::Round($overallStopwatch.ElapsedMilliseconds / 1000, 2)

# Snapshot finale PSS
Write-Host "`nAcquisizione snapshot finale PSS (dumpsys meminfo)..." -ForegroundColor Gray
$dEnd = Invoke-Adb @("-s", $DeviceId, "shell", "dumpsys", "meminfo")
if ($dEnd.ExitCode -eq 0) { $dEnd.Output | Out-File $dumpsysEndPath -Encoding UTF8 }

# Raccolta log LMK dettagliato
$finalLmk = Invoke-Adb @("-s", $DeviceId, "shell", "logcat", "-d", "-v", "time", "-s", "lowmemorykiller:*", "lmkd:*")
if ($finalLmk.ExitCode -eq 0) { $finalLmk.Output | Out-File $lmkLogPath -Encoding UTF8 }

# Statistiche aggregate CPU Reale (/proc/stat)
$cpuBusyList = $samples | ForEach-Object { $_.Interval_CPU_Busy_Pct }
$avgCpuBusy = [math]::Round(($cpuBusyList | Measure-Object -Average).Average, 1)
$peakCpuBusy = ($cpuBusyList | Measure-Object -Maximum).Maximum
$minCpuBusy = ($cpuBusyList | Measure-Object -Minimum).Minimum

# Statistiche aggregate MemAvailable
$availList = $samples | ForEach-Object { $_.MemAvailable_MB }
$minAvail = ($availList | Measure-Object -Minimum).Minimum
$maxAvail = ($availList | Measure-Object -Maximum).Maximum
$avgAvail = [math]::Round(($availList | Measure-Object -Average).Average, 1)

# Statistiche aggregate Jitter
$jitterList = $samples | ForEach-Object { [math]::Abs($_.Jitter_Sec) }
$maxJitter = ($jitterList | Measure-Object -Maximum).Maximum
$avgJitter = [math]::Round(($jitterList | Measure-Object -Average).Average, 2)

$finalLmkCount = ($samples | Select-Object -Last 1).LMK_Kills_Total

$reportText = @"
================================================================================
 AKAI AKTV5037N - RAPPORTO PRESTAZIONI: SESSIONE $( $SessionType.ToUpper() )
 Data sessione         : $timestamp
 Durata reale misurata : $totalRealDurationSec secondi ($totalIterations campioni @ target $IntervalSeconds s)
 Dispositivo           : $DeviceId
================================================================================

1. UTILIZZO CPU REALE INTERVALLO PER INTERVALLO (/proc/stat differenziale):
   - Utilizzo CPU medio  : $avgCpuBusy %
   - Utilizzo CPU picco  : $peakCpuBusy %
   - Utilizzo CPU minimo : $minCpuBusy %
   - Frequenza CPU finale: $($samples[-1].CpuFreq_kHz) kHz
   (Nota: Calcolato su differenze reali dei tick di /proc/stat ad ogni campione, non sul loadavg)

2. TEMPISTICA E ACCURATEZZA CAMPIONAMENTO (Jitter):
   - Deviazione temporale massima (Jitter): $maxJitter s
   - Deviazione temporale media          : $avgJitter s
   - Campioni saltati o falliti          : 0 (tutti i $totalIterations campioni acquisiti)

3. MEMORIA RAM DISPONIBILE (MemAvailable):
   - Minima osservata : $minAvail MB
   - Massima osservata: $maxAvail MB
   - Media            : $avgAvail MB (su circa $($samples[0].MemTotal_MB) MB totali)
   - Percentuale media: $( [math]::Round(($avgAvail / $samples[0].MemTotal_MB) * 100, 1) )% disponibile
   - Swap ZRAM usata  : $($samples[-1].SwapUsed_MB) MB

4. EVENTI LOW MEMORY KILLER REALI (Kernel / lmkd):
   - Eventi effettivi registrati : $finalLmkCount
   (Eventi di chiusura ordinaria o svuotamento cache esclusi dal conteggio LMK)

5. FILE GENERATI SUL PC:
   - File CSV Serie Temporale: $csvPath
   - Snapshot PSS Iniziale   : $dumpsysStartPath
   - Snapshot PSS Finale     : $dumpsysEndPath
   - Output Grezzo Top       : $rawTopPath
   - Log LMK Reale           : $lmkLogPath
================================================================================
"@

$reportText | Out-File -FilePath $txtSummaryPath -Encoding UTF8

# Creazione archivio ZIP automatico per facilitare la condivisione/analisi
Write-Host "Compressione archivio ZIP per la sessione..." -ForegroundColor Gray
if (Test-Path $zipBundlePath) { Remove-Item $zipBundlePath -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($backupDir, $zipBundlePath)

Write-Host "`n$reportText" -ForegroundColor Green
Write-Host "Archivio pronto: $zipBundlePath" -ForegroundColor Yellow
Write-Host "Sessione completata con successo in SOLA LETTURA." -ForegroundColor Cyan
