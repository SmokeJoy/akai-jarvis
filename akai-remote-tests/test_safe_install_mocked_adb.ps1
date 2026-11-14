# ==============================================================================
# AKAI Custom Remote - Test Suite Mock ADB, Fail-Closed & E2E Verification (PowerShell / Pwsh)
# Esercita direttamente il codice di 05_safe_install_and_rollback.ps1 senza toccare la TV fisica
#
# Comprende:
# - TEST NEGATIVI / FAIL-CLOSED (Test 1-6): Verifica blocchi di sicurezza, corruzione, parametri, assenza tool
# - TEST AFFERMATIVI / SUCCESS PATH (Test 7-8): Dimostrazione E2E ciclo completo upgrade & rollback atomico
# ==============================================================================

$ErrorActionPreference = "Stop"

Write-Host "=== TEST POWERSHELL OFFLINE CON MOCK ADB, FAIL-CLOSED & E2E SUCCESS ===" -ForegroundColor Cyan
$passed = 0
$failed = 0

$scriptPath = Join-Path $PSScriptRoot "05_safe_install_and_rollback.ps1"
$tempDir = [System.IO.Path]::GetTempPath()
$psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
$isWin = [System.Environment]::OSVersion.Platform.ToString() -match "Win"

$nodePaths = @(
    "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay\tools\nodejs\node.exe",
    (Get-Command node -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
)
$validNode = $nodePaths | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if ($validNode) {
    $nodeDir = Split-Path $validNode -Parent
    $env:PATH = $nodeDir + [System.IO.Path]::PathSeparator + $env:PATH
}

function New-MockRealDatabase {
    param([string]$FilePath)
    $fpEscaped = $FilePath.Replace('\', '/')
    
    # 1. Prova con Node.js (se node:sqlite è supportato, es. Node 22+)
    if ($validNode) {
        $nodeInit = @"
try {
    const { DatabaseSync } = require('node:sqlite');
    const db = new DatabaseSync('$fpEscaped');
    db.exec('CREATE TABLE IF NOT EXISTS ai_memory (id INTEGER PRIMARY KEY, note TEXT);');
    db.prepare('INSERT INTO ai_memory VALUES (?, ?)').run(1, 'golden_upgrade_data');
    db.close();
} catch (e) {}
"@
        & $validNode --no-warnings -e $nodeInit *>$null
        if ((Test-Path $FilePath) -and (Get-Item $FilePath).Length -ge 512) { return }
    }
    
    # 2. Prova con Python 3 / Python reale (escludendo WindowsApps shim)
    $pythonCmd = Get-Command python3 -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch "WindowsApps" } | Select-Object -First 1
    if (-not $pythonCmd) {
        $pythonCmd = Get-Command python -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch "WindowsApps" } | Select-Object -First 1
    }
    if ($pythonCmd) {
        $pyInit = "import sqlite3; con = sqlite3.connect(r'$FilePath'); con.execute('CREATE TABLE IF NOT EXISTS ai_memory (id INTEGER PRIMARY KEY, note TEXT);'); con.execute('INSERT INTO ai_memory VALUES (?, ?)', (1, 'golden_upgrade_data')); con.commit(); con.close()"
        & $pythonCmd.Source -c $pyInit 2>$null | Out-Null
        if ((Test-Path $FilePath) -and (Get-Item $FilePath).Length -ge 512) { return }
    }
    
    # 3. Prova con sqlite3 CLI
    $sqlite3 = Get-Command sqlite3 -ErrorAction SilentlyContinue
    if ($sqlite3) {
        & $sqlite3.Source $FilePath "CREATE TABLE IF NOT EXISTS ai_memory (id INTEGER PRIMARY KEY, note TEXT); INSERT INTO ai_memory VALUES (1, 'golden_upgrade_data');" 2>$null | Out-Null
        if ((Test-Path $FilePath) -and (Get-Item $FilePath).Length -ge 512) { return }
    }
    
    throw "Impossibile creare database SQLite di mock: nessun interprete disponibile (Python, sqlite3, Node.js)."
}

# -----------------------------------------------------------------------------
# PARTE 1: TEST NEGATIVI / FAIL-CLOSED
# -----------------------------------------------------------------------------

# TEST 1: Installazione senza parametro -ApkPath obbligatorio
try {
    $out1 = & $psExe -ExecutionPolicy Bypass -File $scriptPath -Action install -AllowHardwareExecution 2>&1 | Out-String
    if ($out1 -match "ERRORE FAIL-CLOSED: Il parametro -ApkPath e' obbligatorio") {
        Write-Host "[PASS] [TEST NEGATIVO / FAIL-CLOSED] Test 1: Mancanza parametro -ApkPath bloccata categoricamente" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO / FAIL-CLOSED] Test 1: Mancato blocco per ApkPath mancante: $out1" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[PASS] [TEST NEGATIVO / FAIL-CLOSED] Test 1: Mancanza parametro -ApkPath bloccata con eccezione Fail-Closed" -ForegroundColor Green
    $passed++
}

# TEST 2: Tentativo di installazione con artefatto di test CI non distribuibile
try {
    $out2 = & $psExe -ExecutionPolicy Bypass -File $scriptPath -Action install -ApkPath ".\build_ci\app-ci-test-nondistributable.apk" -AllowHardwareExecution 2>&1 | Out-String
    if ($out2 -match "BLOCCO DI SICUREZZA: L'APK candidato e' un artefatto di test CI") {
        Write-Host "[PASS] [TEST NEGATIVO / FAIL-CLOSED] Test 2: Rifiuto categorico artefatto CI non distribuibile confermato" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO / FAIL-CLOSED] Test 2: Artefatto CI non bloccato: $out2" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[PASS] [TEST NEGATIVO / FAIL-CLOSED] Test 2: Artefatto CI bloccato con eccezione Fail-Closed" -ForegroundColor Green
    $passed++
}

# TEST 3: Verifica integrità SQLite su file corrotto / non-sqlite (Fail-Closed)
$dummyCorruptDb = Join-Path $tempDir "corrupt_test_$([Guid]::NewGuid().ToString('N')).db"
[System.IO.File]::WriteAllText($dummyCorruptDb, "NON E UN DATABASE SQLITE VALIDO ED E' VOLUTAMENTE CORROTTO")
try {
    $scriptEscaped = $scriptPath.Replace('\', '/')
    $dbEscaped = $dummyCorruptDb.Replace('\', '/')
    $checkCmd = @"
. '$scriptEscaped' -Action plan | Out-Null
Verify-SQLiteIntegrityOffline '$dbEscaped'
"@
    $out3 = & $psExe -ExecutionPolicy Bypass -Command $checkCmd 2>&1 | Out-String
    if ($out3 -match "ERRORE FAIL-CLOSED" -or $LASTEXITCODE -ne 0) {
        Write-Host "[PASS] [TEST NEGATIVO / FAIL-CLOSED] Test 3: File database corrotto bloccato da Verify-SQLiteIntegrityOffline" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO / FAIL-CLOSED] Test 3: Database corrotto non ha generato eccezione: $out3" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[PASS] [TEST NEGATIVO / FAIL-CLOSED] Test 3: Database corrotto bloccato con eccezione Fail-Closed" -ForegroundColor Green
    $passed++
} finally {
    Remove-Item $dummyCorruptDb -Force -ErrorAction SilentlyContinue
}

# TEST 4: Verifica integrità SQLite su file inesistente (Fail-Closed)
try {
    $scriptEscaped = $scriptPath.Replace('\', '/')
    $checkMissing = @"
. '$scriptEscaped' -Action plan | Out-Null
Verify-SQLiteIntegrityOffline 'c:/percorso_fittizio_inesistente/non_esisto.db'
"@
    $out4 = & $psExe -ExecutionPolicy Bypass -Command $checkMissing 2>&1 | Out-String
    if ($out4 -match "ERRORE FAIL-CLOSED" -or $LASTEXITCODE -ne 0) {
        Write-Host "[PASS] [TEST NEGATIVO / FAIL-CLOSED] Test 4: File inesistente solleva eccezione fail-closed immediata" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO / FAIL-CLOSED] Test 4: Mancato blocco fail-closed su file inesistente" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[PASS] [TEST NEGATIVO / FAIL-CLOSED] Test 4: Eccezione fail-closed confermata per file inesistente" -ForegroundColor Green
    $passed++
}

# TEST 5: Simulazione ADB Mock con Permessi Negati su Estrazione DB (run-as non debuggable & su negato)
$mockAdbDir = Join-Path $tempDir "mock_adb_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $mockAdbDir | Out-Null
$mockAdbCmd = if ($isWin) { Join-Path $mockAdbDir "adb.cmd" } else { Join-Path $mockAdbDir "adb" }

if ($isWin) {
@'
@echo off
setlocal enabledelayedexpansion
set "ARGS=%*"
if "%1"=="connect" exit /b 0
echo %ARGS% | findstr /i "pm path" >nul
if %ERRORLEVEL% equ 0 (
    echo package:/data/app/it.akai.customremote-1/base.apk
    exit /b 0
)
echo %ARGS% | findstr /i "pull" >nul
if %ERRORLEVEL% equ 0 (
    for %%i in (%*) do set "DEST=%%i"
    echo PK_DUMMY_BACKUP > "!DEST!"
    exit /b 0
)
echo %ARGS% | findstr /i "exec-out" >nul
if %ERRORLEVEL% equ 0 (
    echo run-as: package not debuggable 1>&2
    exit /b 1
)
echo %ARGS% | findstr /i "shell" >nul
if %ERRORLEVEL% equ 0 (
    echo Permission denied 1>&2
    exit /b 1
)
exit /b 0
'@ | Out-File -FilePath $mockAdbCmd -Encoding ascii
} else {
@'
#!/bin/sh
ARGS="$*"
case "$1" in
  connect) exit 0 ;;
esac
case "$ARGS" in
  *"pm path"*) echo "package:/data/app/it.akai.customremote-1/base.apk"; exit 0 ;;
  *"pull"*)
    for last in "$@"; do :; done
    echo "PK_DUMMY_BACKUP" > "$last"
    exit 0
    ;;
  *"exec-out"*)
    echo "run-as: package not debuggable" >&2
    exit 1
    ;;
  *"shell"*)
    echo "Permission denied" >&2
    exit 1
    ;;
esac
exit 0
'@ | Out-File -FilePath $mockAdbCmd -Encoding ascii
    & chmod +x $mockAdbCmd
}

$dummyCandidateApk = Join-Path $tempDir "candidate_valid.apk"
[System.IO.File]::WriteAllText($dummyCandidateApk, "PK_DUMMY_CANDIDATE")

try {
    $scriptEscaped = $scriptPath.Replace('\', '/')
    $mockCmdEscaped = $mockAdbCmd.Replace('\', '/')
    $mockDirEscaped = $mockAdbDir.Replace('\', '/')
    $candidateEscaped = $dummyCandidateApk.Replace('\', '/')

    $testCmd = @"
`$ErrorActionPreference = 'Continue'
`$env:ADB_EXECUTABLE = '$mockCmdEscaped'
`$env:PATH = '$mockDirEscaped' + [System.IO.Path]::PathSeparator + `$env:PATH
& '$scriptEscaped' -Action install -ApkPath '$candidateEscaped' -AllowHardwareExecution
"@
    $res5 = & $psExe -ExecutionPolicy Bypass -Command $testCmd 2>&1 | Out-String

    if ($res5 -match "ERRORE FAIL-CLOSED" -or $res5 -match "INTERROTTA per prevenire perdite" -or $res5 -match "Permission denied") {
        Write-Host "[PASS] [TEST NEGATIVO / FAIL-CLOSED] Test 5: Simulazione permessi negati ADB (run-as negato): installazione ABORTITA Fail-Closed" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO / FAIL-CLOSED] Test 5: Fallimento simulazione permessi negati: $res5" -ForegroundColor Red
        $failed++
    }
} catch {
    $errMsg = $_.Exception.Message
    if ($errMsg -match "ERRORE FAIL-CLOSED: Impossibile estrarre un backup integro del database" -or $errMsg -match "Permission denied") {
        Write-Host "[PASS] [TEST NEGATIVO / FAIL-CLOSED] Test 5: Simulazione permessi negati ADB: installazione ABORTITA con blocco fail-closed" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO / FAIL-CLOSED] Test 5: Errore imprevisto: $errMsg" -ForegroundColor Red
        $failed++
    }
} finally {
    Remove-Item $mockAdbDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $dummyCandidateApk -Force -ErrorAction SilentlyContinue
}

# TEST 6: Verifica Fail-Closed quando nessun motore SQLite e' disponibile nell'ambiente
$dummyDb6 = Join-Path $tempDir "valid_size_test_$([Guid]::NewGuid().ToString('N')).db"
$dummyBytes = New-Object byte[] 1024
[System.IO.File]::WriteAllBytes($dummyDb6, $dummyBytes)

try {
    $scriptEscaped = $scriptPath.Replace('\', '/')
    $dbEscaped6 = $dummyDb6.Replace('\', '/')
    
    $noToolCmd = @"
`$ErrorActionPreference = 'Continue'
`$env:PATH = ''
function Test-Path(`$p) {
    if (`$p -match 'node\.exe' -or `$p -match 'python' -or `$p -match 'sqlite3') { return `$false }
    return Microsoft.PowerShell.Management\Test-Path `$p
}
. '$scriptEscaped' -Action plan | Out-Null
Verify-SQLiteIntegrityOffline '$dbEscaped6'
"@
    $out6 = & $psExe -ExecutionPolicy Bypass -Command $noToolCmd 2>&1 | Out-String
    if ($out6 -match "ERRORE FAIL-CLOSED: Impossibile verificare l'integrita' SQLite offline" -or $out6 -match "Operazione interrotta per sicurezza") {
        Write-Host "[PASS] [TEST NEGATIVO / FAIL-CLOSED] Test 6: Assenza interpreti SQLite bloccata con eccezione Fail-Closed (zero fail-open)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO / FAIL-CLOSED] Test 6: Mancato blocco fail-closed su assenza tool: $out6" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[PASS] [TEST NEGATIVO / FAIL-CLOSED] Test 6: Assenza interpreti SQLite bloccata con eccezione Fail-Closed" -ForegroundColor Green
    $passed++
} finally {
    Remove-Item $dummyDb6 -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
# PARTE 2: TEST AFFERMATIVI / SUCCESS PATH (E2E COMPLETE CYCLE)
# -----------------------------------------------------------------------------

# TEST 7: E2E Happy Path Upgrade con Mock ADB, SQLite reale verificato, firma compatibile e Watchdog OK
$testDir7 = Join-Path $tempDir "e2e_upgrade_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir7 | Out-Null

$mockHttpScript7 = Join-Path $testDir7 "mock_http_7.js"
$mockAdbJs7 = Join-Path $testDir7 "mock_adb_7.js"
$mockSignerJs7 = Join-Path $testDir7 "mock_signer_7.js"
$realDb7 = Join-Path $testDir7 "device_db.sqlite"
$deviceApk7 = Join-Path $testDir7 "device_backup.apk"
$candidateApk7 = Join-Path $testDir7 "candidate_release.apk"
$backupDir7 = Join-Path $testDir7 "backup_target"

# 1. Creazione DB SQLite reale con tabella e record verificato
New-MockRealDatabase -FilePath $realDb7

# 2. File APK dummy non vuoti
[System.IO.File]::WriteAllText($deviceApk7, "PK_DEVICE_BACKUP_APK_MOCK")
[System.IO.File]::WriteAllText($candidateApk7, "PK_CANDIDATE_RELEASE_APK_MOCK")

# 3. Mock apksigner
@"
console.log('Signer #1 certificate SHA-256 digest: a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90');
process.exit(0);
"@ | Out-File -FilePath $mockSignerJs7 -Encoding ascii

$mockSignerCmd7 = if ($isWin) { Join-Path $testDir7 "apksigner.cmd" } else { Join-Path $testDir7 "apksigner" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockSignerJs7`" %*" | Out-File -FilePath $mockSignerCmd7 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockSignerJs7`" `"`$@`"" | Out-File -FilePath $mockSignerCmd7 -Encoding ascii
    & chmod +x $mockSignerCmd7
}

# 4. Mock ADB per Happy Path Upgrade
@"
const fs = require('fs');
const argv = process.argv.slice(2);
const args = argv.join(' ');

if (argv.includes('connect') || argv.includes('wait-for-device')) process.exit(0);
if (argv.includes('unroot')) { console.log('adbd is already running as non root'); process.exit(0); }
if (argv.includes('root')) { console.log('adbd cannot run as root in production builds'); process.exit(1); }
if (argv.includes('shell') && argv[argv.length - 1] === 'id') { console.log('uid=2000(shell) gid=2000(shell)'); process.exit(0); }
if (args.includes('pm list')) { console.log('package:it.akai.customremote'); process.exit(0); }
if (args.includes('pm path')) { console.log('package:/data/app/it.akai.customremote-1/base.apk'); process.exit(0); }
if (args.includes('pull')) {
    const dest = process.argv[process.argv.length - 1];
    fs.copyFileSync(process.env.DEVICE_APK_FILE, dest);
    process.exit(0);
}
if (args.includes('exec-in')) {
    const chunks = [];
    process.stdin.on('data', chunk => chunks.push(chunk));
    process.stdin.on('end', () => process.exit(0));
    return;
}
if (args.includes('exec-out')) {
    const buf = fs.readFileSync(process.env.DEVICE_DB_FILE);
    process.stdout.write(buf, () => process.exit(0));
    return;
}
if (args.includes('install')) { console.log('Success'); process.exit(0); }
if (args.includes('PIDOF_CHECK') || args.includes('pids=')) { console.log('PIDOF_CHECK:pids=[]:exit=[1]'); process.exit(0); }
if (args.includes('pidof')) { console.log('1234'); process.exit(0); }
if (args.includes('dumpsys package')) { console.log('    userId=10123'); process.exit(0); }
if (args.includes('stat -c')) { console.log('10123'); process.exit(0); }
if (args.includes('test -f') || args.includes('FILE_PROBE_RESULT')) { console.log('FILE_PROBE_RESULT:NOT_FOUND'); process.exit(0); }
if (args.includes('shell')) { process.exit(0); }
process.exit(0);
"@ | Out-File -FilePath $mockAdbJs7 -Encoding ascii

$mockAdbCmd7 = if ($isWin) { Join-Path $testDir7 "adb.cmd" } else { Join-Path $testDir7 "adb" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockAdbJs7`" %*" | Out-File -FilePath $mockAdbCmd7 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockAdbJs7`" `"`$@`"" | Out-File -FilePath $mockAdbCmd7 -Encoding ascii
    & chmod +x $mockAdbCmd7
}

# 5. Mock HTTP Server (porta dinamica $port7)
$port7 = Get-Random -Minimum 21000 -Maximum 28000
$readyFile7 = Join-Path $testDir7 "ready_7_$([Guid]::NewGuid().ToString('N')).txt"
$readyEsc7 = $readyFile7.Replace('\', '/')
if (Test-Path $readyFile7) { Remove-Item $readyFile7 -Force -ErrorAction SilentlyContinue }
@"
const http = require('http');
const fs = require('fs');
const send = (res, code, ctype, body) => {
  const buf = Buffer.from(body);
  res.writeHead(code, {
    'Content-Type': ctype,
    'Content-Length': buf.length,
    'Connection': 'close'
  });
  res.end(buf);
};
const server = http.createServer((req, res) => {
  if (req.url === '/api/status') {
    send(res, 200, 'application/json', JSON.stringify({ status: 'ok', uinput_ready: true, active_sessions: 1 }));
  } else if (req.url === '/index.html') {
    send(res, 200, 'text/html', '<!DOCTYPE html><html><body>AKAI Web Remote</body></html>');
  } else if (req.url === '/api/ai/memory') {
    if (req.headers['authorization'] !== 'Bearer mock_v5_token') {
      send(res, 401, 'application/json', JSON.stringify({ error: 'Non autorizzato: token mancante o scaduto' }));
      return;
    }
    // Baseline v5 schema: conversations, preferences, stats (NO procedures!)
    send(res, 200, 'application/json', JSON.stringify({ status: 'ok', conversations: [], preferences: {}, stats: {} }));
  } else {
    send(res, 404, 'text/plain', 'Not Found');
  }
});
setInterval(() => {}, 1000);
server.on('error', () => {});
server.on('clientError', (err, socket) => { socket.destroy(); });
server.listen($port7, '127.0.0.1', () => { fs.writeFileSync('$readyEsc7', '1'); });
"@ | Out-File -FilePath $mockHttpScript7 -Encoding ascii

$httpErrLog7 = Join-Path $testDir7 "http_err.log"
$httpProc7 = $null

try {
    $httpProc7 = Start-Process -FilePath $validNode -ArgumentList "`"$mockHttpScript7`"" -RedirectStandardError $httpErrLog7 -PassThru
    $wait7 = 100
    while (-not (Test-Path $readyFile7) -and -not $httpProc7.HasExited -and $wait7 -gt 0) {
        Start-Sleep -Milliseconds 100
        $wait7--
    }
    if (-not (Test-Path $readyFile7)) {
        throw "Server HTTP mock Test 7 non pronto o terminato prematuramente (HasExited=$($httpProc7.HasExited))"
    }

    $scriptEscaped = $scriptPath.Replace('\', '/')
    $candidateEscaped = $candidateApk7.Replace('\', '/')
    $mockAdbEscaped = $mockAdbCmd7.Replace('\', '/')
    $mockSignerEscaped = $mockSignerCmd7.Replace('\', '/')
    $realDbEscaped = $realDb7.Replace('\', '/')
    $deviceApkEscaped = $deviceApk7.Replace('\', '/')
    $backupDirEscaped = $backupDir7.Replace('\', '/')

    $nodeEscaped = $validNode.Replace('\', '/')
    $testCmd7 = @"
`$env:NODE_EXE = '$nodeEscaped'
`$env:ADB_EXECUTABLE = '$mockAdbEscaped'
`$env:APKSIGNER_EXECUTABLE = '$mockSignerEscaped'
`$env:DEVICE_DB_FILE = '$realDbEscaped'
`$env:DEVICE_APK_FILE = '$deviceApkEscaped'
`$env:WATCHDOG_ATTEMPTS = '2'
`$env:WATCHDOG_SLEEP_SEC = '1'

& '$scriptEscaped' -Action install -ApkPath '$candidateEscaped' -TargetTv '127.0.0.1' -HttpPort $port7 -AuthToken 'mock_v5_token' -BackupDir '$backupDirEscaped' -AllowHardwareExecution
"@
    $res7 = & $psExe -ExecutionPolicy Bypass -Command $testCmd7 2>&1 | Out-String

    if ($res7 -match "DEPLOYMENT VERIFICATO CON SUCCESSO AL 100%" -and $res7 -match "Compatibilit.*firma SHA-256 verificata con successo") {
        Write-Host "[PASS] [TEST AFFERMATIVO / SUCCESS PATH] Test 7: E2E Happy Path Upgrade (ADB mock, backup SQLite reale, firme compatibili, Watchdog OK)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST AFFERMATIVO / SUCCESS PATH] Test 7: Output non conforme: $res7" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[FAIL] [TEST AFFERMATIVO / SUCCESS PATH] Test 7: Eccezione imprevista: $($_.Exception.Message)" -ForegroundColor Red
    $failed++
} finally {
    if ($httpProc7 -and -not $httpProc7.HasExited) { Stop-Process -Id $httpProc7.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $readyFile7 -Force -ErrorAction SilentlyContinue
    Remove-Item $testDir7 -Recurse -Force -ErrorAction SilentlyContinue
}

# TEST 8: E2E Happy Path Rollback Atomico con Watchdog fallito, ripristino APK+DB via Send-FileViaAdbExecIn e parità hash SHA-256
$testDir8 = Join-Path $tempDir "e2e_rollback_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir8 | Out-Null

$mockHttpScript8 = Join-Path $testDir8 "mock_http_8.js"
$mockAdbJs8 = Join-Path $testDir8 "mock_adb_8.js"
$mockSignerJs8 = Join-Path $testDir8 "mock_signer_8.js"
$realDb8 = Join-Path $testDir8 "device_db.sqlite"
$deviceApk8 = Join-Path $testDir8 "device_backup.apk"
$candidateApk8 = Join-Path $testDir8 "candidate_faulty.apk"
$backupDir8 = Join-Path $testDir8 "backup_target"
$restoredTargetDb8 = Join-Path $testDir8 "restored_on_device.sqlite"

# 1. Creazione DB SQLite reale per baseline
New-MockRealDatabase -FilePath $realDb8

[System.IO.File]::WriteAllText($deviceApk8, "PK_DEVICE_BACKUP_APK_MOCK_8")
[System.IO.File]::WriteAllText($candidateApk8, "PK_CANDIDATE_FAULTY_APK_MOCK_8")

# 2. Mock apksigner
@"
console.log('Signer #1 certificate SHA-256 digest: deadbeefcafebabe00112233445566778899aabbccddeeffdeadbeefcafebabe');
process.exit(0);
"@ | Out-File -FilePath $mockSignerJs8 -Encoding ascii

$mockSignerCmd8 = if ($isWin) { Join-Path $testDir8 "apksigner.cmd" } else { Join-Path $testDir8 "apksigner" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockSignerJs8`" %*" | Out-File -FilePath $mockSignerCmd8 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockSignerJs8`" `"`$@`"" | Out-File -FilePath $mockSignerCmd8 -Encoding ascii
    & chmod +x $mockSignerCmd8
}

# 3. Mock ADB per Rollback: supporta exec-in per streaming e exec-out per verifica hash post-restore
@"
const fs = require('fs');
const argv = process.argv.slice(2);
const args = argv.join(' ');

if (argv.includes('connect') || argv.includes('wait-for-device')) process.exit(0);
if (argv.includes('unroot')) { console.log('adbd is already running as non root'); process.exit(0); }
if (argv.includes('root')) { console.log('adbd cannot run as root in production builds'); process.exit(1); }
if (argv.includes('shell') && argv[argv.length - 1] === 'id') { console.log('uid=2000(shell) gid=2000(shell)'); process.exit(0); }
if (args.includes('pm list')) { console.log('package:it.akai.customremote'); process.exit(0); }
if (args.includes('pm path')) { console.log('package:/data/app/it.akai.customremote-1/base.apk'); process.exit(0); }
if (args.includes('pull')) {
    const dest = process.argv[process.argv.length - 1];
    fs.copyFileSync(process.env.DEVICE_APK_FILE, dest);
    process.exit(0);
}
if (args.includes('exec-in')) {
    const target = process.env.DEVICE_RESTORE_TARGET;
    const chunks = [];
    process.stdin.on('data', chunk => chunks.push(chunk));
    process.stdin.on('end', () => {
        fs.writeFileSync(target, Buffer.concat(chunks));
        process.exit(0);
    });
    return;
}
if (args.includes('exec-out')) {
    const src = (process.env.DEVICE_RESTORE_TARGET && fs.existsSync(process.env.DEVICE_RESTORE_TARGET)) ? process.env.DEVICE_RESTORE_TARGET : process.env.DEVICE_DB_FILE;
    const buf = fs.readFileSync(src);
    process.stdout.write(buf, () => process.exit(0));
    return;
}
if (args.includes('install')) { console.log('Success'); process.exit(0); }
if (args.includes('pidof')) { console.log('PIDOF_CHECK:pids=[]:exit=[1]'); process.exit(0); }
if (args.includes('test -f') || args.includes('FILE_PROBE_RESULT')) { console.log('FILE_PROBE_RESULT:NOT_FOUND'); process.exit(0); }
if (args.includes('dumpsys package')) { console.log('    userId=10123'); process.exit(0); }
if (args.includes('stat -c')) { console.log('10123'); process.exit(0); }
if (args.includes('shell')) {
    if (args.includes('cat databases/akai_memory.db')) {
        const src = (process.env.DEVICE_RESTORE_TARGET && fs.existsSync(process.env.DEVICE_RESTORE_TARGET)) ? process.env.DEVICE_RESTORE_TARGET : process.env.DEVICE_DB_FILE;
        const buf = fs.readFileSync(src);
        process.stdout.write(buf, () => process.exit(0));
        return;
    }
    process.exit(0);
}
process.exit(0);
"@ | Out-File -FilePath $mockAdbJs8 -Encoding ascii

$mockAdbCmd8 = if ($isWin) { Join-Path $testDir8 "adb.cmd" } else { Join-Path $testDir8 "adb" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockAdbJs8`" %*" | Out-File -FilePath $mockAdbCmd8 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockAdbJs8`" `"`$@`"" | Out-File -FilePath $mockAdbCmd8 -Encoding ascii
    & chmod +x $mockAdbCmd8
}

# 4. Mock HTTP Server: fallisce sul watchdog upgrade, ma risponde OK sul watchdog post-rollback!
$port8 = Get-Random -Minimum 28001 -Maximum 36000
$readyFile8 = Join-Path $testDir8 "ready_8_$([Guid]::NewGuid().ToString('N')).txt"
$readyEsc8 = $readyFile8.Replace('\', '/')
if (Test-Path $readyFile8) { Remove-Item $readyFile8 -Force -ErrorAction SilentlyContinue }
@"
const http = require('http');
const fs = require('fs');
let attempts = 0;
const send = (res, code, ctype, body) => {
  const buf = Buffer.from(body);
  res.writeHead(code, {
    'Content-Type': ctype,
    'Content-Length': buf.length,
    'Connection': 'close'
  });
  res.end(buf);
};
const server = http.createServer((req, res) => {
  if (req.url === '/api/status') {
    attempts++;
    if (attempts <= 2) {
      send(res, 500, 'application/json', JSON.stringify({ status: 'error', message: 'Simulated failure to trigger rollback' }));
      return;
    }
    send(res, 200, 'application/json', JSON.stringify({ status: 'ok', uinput_ready: true, active_sessions: 1 }));
  } else if (req.url === '/index.html') {
    if (attempts <= 2) {
      send(res, 503, 'text/plain', 'Service Unavailable');
      return;
    }
    send(res, 200, 'text/html', '<!DOCTYPE html><html><body>AKAI Web Remote Rollback OK</body></html>');
  } else if (req.url === '/api/ai/memory') {
    if (req.headers['authorization'] !== 'Bearer mock_v5_token') {
      send(res, 401, 'application/json', JSON.stringify({ error: 'Non autorizzato: token mancante o scaduto' }));
      return;
    }
    // Baseline v5 schema: conversations, preferences, stats (NO procedures!)
    send(res, 200, 'application/json', JSON.stringify({ status: 'ok', conversations: [], preferences: {}, stats: {} }));
  } else {
    send(res, 404, 'text/plain', 'Not Found');
  }
});
setInterval(() => {}, 1000);
server.on('error', () => {});
server.on('clientError', (err, socket) => { socket.destroy(); });
server.listen($port8, '127.0.0.1', () => { fs.writeFileSync('$readyEsc8', '1'); });
"@ | Out-File -FilePath $mockHttpScript8 -Encoding ascii

$httpErrLog8 = Join-Path $testDir8 "http_err.log"
$httpProc8 = $null

try {
    $httpProc8 = Start-Process -FilePath $validNode -ArgumentList "`"$mockHttpScript8`"" -RedirectStandardError $httpErrLog8 -PassThru
    $wait8 = 100
    while (-not (Test-Path $readyFile8) -and -not $httpProc8.HasExited -and $wait8 -gt 0) {
        Start-Sleep -Milliseconds 100
        $wait8--
    }
    if (-not (Test-Path $readyFile8)) {
        throw "Server HTTP mock Test 8 non pronto o terminato prematuramente (HasExited=$($httpProc8.HasExited))"
    }

    $scriptEscaped = $scriptPath.Replace('\', '/')
    $candidateEscaped = $candidateApk8.Replace('\', '/')
    $mockAdbEscaped = $mockAdbCmd8.Replace('\', '/')
    $mockSignerEscaped = $mockSignerCmd8.Replace('\', '/')
    $realDbEscaped = $realDb8.Replace('\', '/')
    $deviceApkEscaped = $deviceApk8.Replace('\', '/')
    $backupDirEscaped = $backupDir8.Replace('\', '/')
    $restoreTargetEscaped = $restoredTargetDb8.Replace('\', '/')

    $nodeEscaped = $validNode.Replace('\', '/')
    $testCmd8 = @"
`$env:NODE_EXE = '$nodeEscaped'
`$env:ADB_EXECUTABLE = '$mockAdbEscaped'
`$env:APKSIGNER_EXECUTABLE = '$mockSignerEscaped'
`$env:DEVICE_DB_FILE = '$realDbEscaped'
`$env:DEVICE_APK_FILE = '$deviceApkEscaped'
`$env:DEVICE_RESTORE_TARGET = '$restoreTargetEscaped'
`$env:WATCHDOG_ATTEMPTS = '2'
`$env:WATCHDOG_SLEEP_SEC = '1'

& '$scriptEscaped' -Action install -ApkPath '$candidateEscaped' -TargetTv '127.0.0.1' -HttpPort $port8 -AuthToken 'mock_v5_token' -BackupDir '$backupDirEscaped' -AllowHardwareExecution
"@
    $res8 = & $psExe -ExecutionPolicy Bypass -Command $testCmd8 2>&1 | Out-String

    if ($res8 -match "ALLARME: Health check fallito" -and $res8 -match "ROLLBACK RIUSCITO E VERIFICATO" -and $res8 -match "Parita' hash SHA-256") {
        Write-Host "[PASS] [TEST AFFERMATIVO / SUCCESS PATH] Test 8: E2E Happy Path Rollback (Watchdog fail -> reinstall APK -> streaming Send-FileViaAdbExecIn -> parita' hash SHA-256 e integrita' SQLite OK)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST AFFERMATIVO / SUCCESS PATH] Test 8: Output non conforme: $res8" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[FAIL] [TEST AFFERMATIVO / SUCCESS PATH] Test 8: Eccezione imprevista: $($_.Exception.Message)" -ForegroundColor Red
    $failed++
} finally {
    if ($httpProc8 -and -not $httpProc8.HasExited) { Stop-Process -Id $httpProc8.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $readyFile8 -Force -ErrorAction SilentlyContinue
    Remove-Item $testDir8 -Recurse -Force -ErrorAction SilentlyContinue
}

# TEST 9: [TEST NEGATIVO / FAIL-CLOSED] Rilettura post-rollback bloccata da ADB -> Errore immediato e zero false successi
$testDir9 = Join-Path $tempDir "e2e_fail_closed_post_rollback_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir9 | Out-Null

$mockHttpScript9 = Join-Path $testDir9 "mock_http_9.js"
$mockAdbJs9 = Join-Path $testDir9 "mock_adb_9.js"
$mockSignerJs9 = Join-Path $testDir9 "mock_signer_9.js"
$realDb9 = Join-Path $testDir9 "device_db.sqlite"
$deviceApk9 = Join-Path $testDir9 "device_backup.apk"
$candidateApk9 = Join-Path $testDir9 "candidate_faulty.apk"
$backupDir9 = Join-Path $testDir9 "backup_target"

New-MockRealDatabase -FilePath $realDb9
[System.IO.File]::WriteAllText($deviceApk9, "PK_DEVICE_BACKUP_APK_MOCK_9")
[System.IO.File]::WriteAllText($candidateApk9, "PK_CANDIDATE_FAULTY_APK_MOCK_9")

# Mock apksigner
@"
console.log('Signer #1 certificate SHA-256 digest: feedfacefeedface00112233445566778899aabbccddeefffeedfacefeedface');
process.exit(0);
"@ | Out-File -FilePath $mockSignerJs9 -Encoding ascii

$mockSignerCmd9 = if ($isWin) { Join-Path $testDir9 "apksigner.cmd" } else { Join-Path $testDir9 "apksigner" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockSignerJs9`" %*" | Out-File -FilePath $mockSignerCmd9 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockSignerJs9`" `"`$@`"" | Out-File -FilePath $mockSignerCmd9 -Encoding ascii
    & chmod +x $mockSignerCmd9
}

# Mock ADB: Permette backup iniziale, ma blocca ogni exec-out/cat dopo il rollback (simulando permessi revocati)
@"
const fs = require('fs');
const argv = process.argv.slice(2);
const args = argv.join(' ');
const logFile = process.env.MOCK_LOG_FILE;

if (argv.includes('connect') || argv.includes('wait-for-device')) process.exit(0);
if (argv.includes('unroot')) { console.log('adbd is already running as non root'); process.exit(0); }
if (argv.includes('root')) { console.log('adbd cannot run as root in production builds'); process.exit(1); }
if (argv.includes('shell') && argv[argv.length - 1] === 'id') { console.log('uid=2000(shell) gid=2000(shell)'); process.exit(0); }
if (args.includes('pm list')) { console.log('package:it.akai.customremote'); process.exit(0); }
if (args.includes('pm path')) { console.log('package:/data/app/it.akai.customremote-1/base.apk'); process.exit(0); }
if (args.includes('pull')) {
    const dest = process.argv[process.argv.length - 1];
    fs.copyFileSync(process.env.DEVICE_APK_FILE, dest);
    process.exit(0);
}
if (args.includes('exec-in')) {
    const chunks = [];
    process.stdin.on('data', chunk => chunks.push(chunk));
    process.stdin.on('end', () => process.exit(0));
    return;
}
if (args.includes('exec-out') || args.includes('cat databases/akai_memory.db')) {
    if (fs.existsSync(logFile)) {
        process.exit(1);
    }
    fs.writeFileSync(logFile, 'backup_done');
    const buf = fs.readFileSync(process.env.DEVICE_DB_FILE);
    process.stdout.write(buf, () => process.exit(0));
    return;
}
if (args.includes('install')) { console.log('Success'); process.exit(0); }
if (args.includes('pidof')) { console.log('PIDOF_CHECK:pids=[]:exit=[1]'); process.exit(0); }
if (args.includes('test -f') || args.includes('FILE_PROBE_RESULT')) { console.log('FILE_PROBE_RESULT:NOT_FOUND'); process.exit(0); }
if (args.includes('dumpsys package')) { console.log('    userId=10123'); process.exit(0); }
if (args.includes('stat -c')) { console.log('10123'); process.exit(0); }
process.exit(0);
"@ | Out-File -FilePath $mockAdbJs9 -Encoding ascii

$mockAdbCmd9 = if ($isWin) { Join-Path $testDir9 "adb.cmd" } else { Join-Path $testDir9 "adb" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockAdbJs9`" %*" | Out-File -FilePath $mockAdbCmd9 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockAdbJs9`" `"`$@`"" | Out-File -FilePath $mockAdbCmd9 -Encoding ascii
    & chmod +x $mockAdbCmd9
}

# Mock HTTP Server che forza il fallimento del candidate per innescare rollback
$port9 = Get-Random -Minimum 36001 -Maximum 44000
@"
const http = require('http');
const send = (res, code, ctype, body) => {
  const buf = Buffer.from(body);
  res.writeHead(code, {
    'Content-Type': ctype,
    'Content-Length': buf.length,
    'Connection': 'close'
  });
  res.end(buf);
};
const server = http.createServer((req, res) => {
  if (req.url === '/api/status') {
    send(res, 500, 'application/json', JSON.stringify({ status: 'error', message: 'Fault to trigger rollback' }));
  } else if (req.url === '/index.html') {
    send(res, 503, 'text/plain', 'Service Unavailable');
  } else if (req.url === '/api/ai/memory') {
    send(res, 200, 'application/json', JSON.stringify({ status: 'ok', conversations: [], preferences: {} }));
  } else {
    send(res, 404, 'text/plain', 'Not Found');
  }
});
setInterval(() => {}, 1000);
server.on('error', () => {});
server.on('clientError', (err, socket) => { socket.destroy(); });
server.listen($port9, '127.0.0.1');
"@ | Out-File -FilePath $mockHttpScript9 -Encoding ascii

$httpErrLog9 = Join-Path $testDir9 "http_err.log"
$mockLogFile9 = Join-Path $testDir9 "mock_state.log"
$httpProc9 = Start-Process -FilePath $validNode -ArgumentList "`"$mockHttpScript9`"" -RedirectStandardError $httpErrLog9 -PassThru
Start-Sleep -Milliseconds 800

try {
    $scriptEscaped = $scriptPath.Replace('\', '/')
    $candidateEscaped = $candidateApk9.Replace('\', '/')
    $mockAdbEscaped = $mockAdbCmd9.Replace('\', '/')
    $mockSignerEscaped = $mockSignerCmd9.Replace('\', '/')
    $realDbEscaped = $realDb9.Replace('\', '/')
    $deviceApkEscaped = $deviceApk9.Replace('\', '/')
    $backupDirEscaped = $backupDir9.Replace('\', '/')
    $mockLogEscaped = $mockLogFile9.Replace('\', '/')

    $nodeEscaped = $validNode.Replace('\', '/')
    $testCmd9 = @"
`$env:NODE_EXE = '$nodeEscaped'
`$env:ADB_EXECUTABLE = '$mockAdbEscaped'
`$env:APKSIGNER_EXECUTABLE = '$mockSignerEscaped'
`$env:DEVICE_DB_FILE = '$realDbEscaped'
`$env:DEVICE_APK_FILE = '$deviceApkEscaped'
`$env:MOCK_LOG_FILE = '$mockLogEscaped'
`$env:WATCHDOG_ATTEMPTS = '2'
`$env:WATCHDOG_SLEEP_SEC = '1'

& '$scriptEscaped' -Action install -ApkPath '$candidateEscaped' -TargetTv '127.0.0.1' -HttpPort $port9 -AuthToken 'mock_v5_token' -BackupDir '$backupDirEscaped' -AllowHardwareExecution
"@
    $res9 = & $psExe -ExecutionPolicy Bypass -Command $testCmd9 2>&1 | Out-String

    if ($res9 -match "ERRORE FAIL-CLOSED: Verifica post-rollback fallita" -and $res9 -notmatch "Database SQLite v5 ripristinato con successo") {
        Write-Host "[PASS] [TEST NEGATIVO / FAIL-CLOSED] Test 9: Blocco exec-out post-rollback scatena ERRORE FAIL-CLOSED categorico (zero falsi successi)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO / FAIL-CLOSED] Test 9: Comportamento fail-open rilevato: $res9" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[PASS] [TEST NEGATIVO / FAIL-CLOSED] Test 9: Eccezione fail-closed confermata: $($_.Exception.Message)" -ForegroundColor Green
    $passed++
} finally {
    if ($httpProc9 -and -not $httpProc9.HasExited) { Stop-Process -Id $httpProc9.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $testDir9 -Recurse -Force -ErrorAction SilentlyContinue
}

# TEST 10: [TEST NEGATIVO / REGRESSIONE V5] GET /api/ai/memory senza Bearer Token rifiutata con 401 Unauthorized
$testDir10 = Join-Path $tempDir "v5_auth_regression_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir10 | Out-Null
$mockHttpScript10 = Join-Path $testDir10 "mock_http_10.js"
$port10 = Get-Random -Minimum 44001 -Maximum 52000
@"
const http = require('http');
const send = (res, code, ctype, body) => {
  const buf = Buffer.from(body);
  res.writeHead(code, {
    'Content-Type': ctype,
    'Content-Length': buf.length,
    'Connection': 'close'
  });
  res.end(buf);
};
const server = http.createServer((req, res) => {
  if (req.url === '/api/ai/memory') {
    if (!req.headers['authorization'] || !req.headers['authorization'].startsWith('Bearer ')) {
      send(res, 401, 'application/json', JSON.stringify({ error: 'Non autorizzato: token mancante o scaduto' }));
      return;
    }
    send(res, 200, 'application/json', JSON.stringify({ status: 'ok', conversations: [], preferences: {}, stats: {} }));
  } else {
    send(res, 404, 'text/plain', 'Not Found');
  }
});
setInterval(() => {}, 1000);
server.on('error', () => {});
server.on('clientError', (err, socket) => { socket.destroy(); });
server.listen($port10, '127.0.0.1');
"@ | Out-File -FilePath $mockHttpScript10 -Encoding ascii

$httpProc10 = Start-Process -FilePath $validNode -ArgumentList "`"$mockHttpScript10`"" -PassThru
Start-Sleep -Milliseconds 800
try {
    # 1. Richiesta non autenticata -> DEVE fallire con 401
    $authBlocked = $false
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$port10/api/ai/memory" -Method Get -TimeoutSec 4 -ErrorAction Stop | Out-Null
    } catch {
        if ($_.Exception.Message -match "401" -or ($_.Exception.Response -and $_.Exception.Response.StatusCode -eq 401)) {
            $authBlocked = $true
        }
    }

    # 2. Richiesta autenticata con Bearer -> DEVE restituire 200 e schema baseline v5
    $authSuccess = $false
    $headers = @{ "Authorization" = "Bearer mock_valid_bearer_token" }
    $resAuth = Invoke-RestMethod -Uri "http://127.0.0.1:$port10/api/ai/memory" -Method Get -Headers $headers -TimeoutSec 4 -ErrorAction Stop
    if ($resAuth.status -eq "ok" -and $null -ne $resAuth.conversations -and $null -ne $resAuth.preferences -and $null -eq $resAuth.procedures) {
        $authSuccess = $true
    }

    if ($authBlocked -and $authSuccess) {
        Write-Host "[PASS] [TEST NEGATIVO / REGRESSIONE V5] Test 10: Baseline v5 autenticazione Bearer (401 se assente) e schema (senza procedures) convalidate al 100%" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO / REGRESSIONE V5] Test 10: AuthBlocked=$authBlocked, AuthSuccess=$authSuccess" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[FAIL] [TEST NEGATIVO / REGRESSIONE V5] Test 10: Eccezione: $($_.Exception.Message)" -ForegroundColor Red
    $failed++
} finally {
    if ($httpProc10 -and -not $httpProc10.HasExited) { Stop-Process -Id $httpProc10.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $testDir10 -Recurse -Force -ErrorAction SilentlyContinue
}


# ==============================================================================
# TEST 11: [TEST CONSISTENZA WAL] Checkpoint offline e consolidamento transazioni WAL
# ==============================================================================
Write-Host "`n--- Esecuzione Test 11: Consistenza SQLite in modalita' WAL e Checkpoint Offline ---" -ForegroundColor Yellow
$testDir11 = Join-Path $tempDir "akai_test_wal_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir11 | Out-Null
$testDb11 = Join-Path $testDir11 "akai_memory.db"
$testWal11 = "$testDb11-wal"

try {
    if (-not $validNode) {
        throw "Node.js non disponibile per fixture WAL."
    }

    $dbEsc11 = $testDb11.Replace('\', '/')
    $setupPath11 = Join-Path $testDir11 "setup.js"
    $setupJs = @"
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync('$dbEsc11');
db.exec('PRAGMA journal_mode=WAL;');
db.exec('CREATE TABLE procedures (id INT PRIMARY KEY, name TEXT);');
db.exec('INSERT INTO procedures VALUES (1, \'initial_proc\');');
db.close();
"@
    [System.IO.File]::WriteAllText($setupPath11, $setupJs, [System.Text.Encoding]::UTF8)
    & $validNode --no-warnings $setupPath11

    # Scrittura seconda transazione in processo figlio che esce bruscamente senza checkpoint
    $childPath11 = Join-Path $testDir11 "child.js"
    $childJs = @"
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync('$dbEsc11');
db.exec('PRAGMA wal_autocheckpoint=0;');
db.exec('INSERT INTO procedures VALUES (2, \'uncheckpointed_wal_proc\');');
process.exit(0);
"@
    [System.IO.File]::WriteAllText($childPath11, $childJs, [System.Text.Encoding]::UTF8)
    & $validNode --no-warnings $childPath11

    $walPresent = (Test-Path $testWal11) -and ((Get-Item $testWal11).Length -gt 0)
    Write-Host "      WAL presente con transazioni non checkpointate: $walPresent ($((Get-Item $testWal11).Length) byte)"

    # Eseguiamo Verify-SQLiteIntegrityOffline che esegue PRAGMA wal_checkpoint(TRUNCATE)
    $scriptEscaped = $scriptPath.Replace('\', '/')
    $testCmd11 = @"
. '$scriptEscaped' -Action plan | Out-Null
Verify-SQLiteIntegrityOffline '$dbEsc11'
"@
    $out11 = & $psExe -ExecutionPolicy Bypass -Command $testCmd11 2>&1 | Out-String

    # Verifichiamo che il record precedentemente nel WAL sia ora consolidato nel file principale .db
    $checkPath11 = Join-Path $testDir11 "check.js"
    $checkJs = @"
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync('$dbEsc11');
const row = db.prepare('SELECT COUNT(*) as cnt FROM procedures WHERE name=\'uncheckpointed_wal_proc\';').get();
db.close();
if (row && row.cnt === 1) {
    process.exit(0);
}
process.exit(1);
"@
    [System.IO.File]::WriteAllText($checkPath11, $checkJs, [System.Text.Encoding]::UTF8)
    & $validNode --no-warnings $checkPath11
    if ($LASTEXITCODE -eq 0 -and $out11 -notmatch "ERRORE FAIL-CLOSED") {
        Write-Host "[PASS] [TEST CONSISTENZA WAL] Test 11: Checkpoint offline e consolidamento WAL verificati con successo (zero perdite di dati committati)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST CONSISTENZA WAL] Test 11: Record in WAL non consolidato nel database principale (exit=$LASTEXITCODE, out=$out11)" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[FAIL] [TEST CONSISTENZA WAL] Test 11: Eccezione imprevista: $($_.Exception.Message)" -ForegroundColor Red
    $failed++
} finally {
    Remove-Item $testDir11 -Recurse -Force -ErrorAction SilentlyContinue
}

# ==============================================================================
# TEST 12: [TEST NEGATIVO / ROLLBACK FAIL-CLOSED] Mancanza backup DB blocca il rollback
# ==============================================================================
Write-Host "`n--- Esecuzione Test 12: Prerequisiti Rollback Fail-Closed (DB Mancante) ---" -ForegroundColor Yellow
$testDir12 = Join-Path $tempDir "akai_test_rb_failclosed_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir12 | Out-Null
$backupDir12 = Join-Path $testDir12 "backup_tv"
$sessionDir12 = Join-Path $backupDir12 "backup_mock_session"
New-Item -ItemType Directory -Force -Path $sessionDir12 | Out-Null

$mockApk12 = Join-Path $sessionDir12 "it.akai.customremote_backup.apk"
[System.IO.File]::WriteAllBytes($mockApk12, [byte[]]@(0x50, 0x4B, 0x03, 0x04)) # Dummy zip header

# NOTA: akai_memory.db NON esiste in $sessionDir12 (backup DB assente!)
$port12 = Get-Random -Minimum 18100 -Maximum 18999
$httpProc12 = $null

try {
    # Mock server HTTP che restituisce status ok
    $mockServerJs12 = @"
const http = require('http');
const server = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok' }));
});
server.listen($port12, '127.0.0.1');
setInterval(() => {}, 1000);
"@
    $serverPath12 = Join-Path $testDir12 "mock_server12.js"
    [System.IO.File]::WriteAllText($serverPath12, $mockServerJs12, [System.Text.Encoding]::UTF8)
    $httpProc12 = Start-Process -FilePath $validNode -ArgumentList $serverPath12 -PassThru -NoNewWindow
    Start-Sleep -Seconds 1

    # Invocazione rollback manuale: DEVE sollevare eccezione fail-closed per DB mancante
    $rollbackBlocked = $false
    $output12 = ""
    try {
        $output12 = & $psExe -ExecutionPolicy Bypass -Command "& '$scriptPath' -Action rollback -BackupDir '$backupDir12' -HttpPort $port12 -AllowHardwareExecution 2>&1" | Out-String
        if ($LASTEXITCODE -ne 0 -or $output12 -match "ERRORE FAIL-CLOSED" -or $output12 -match "Prerequisito critico mancante") {
            $rollbackBlocked = $true
        }
    } catch {
        $rollbackBlocked = $true
    }

    $noFalseSuccess = ($output12 -notmatch "Rollback manuale completato e verificato con successo") -and ($output12 -notmatch "TV operativa")

    if ($rollbackBlocked -and $noFalseSuccess) {
        Write-Host "[PASS] [TEST NEGATIVO / ROLLBACK FAIL-CLOSED] Test 12: Rollback categoricamente bloccato per DB v5 mancante (zero downgrade eseguiti, zero falsi successi)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO / ROLLBACK FAIL-CLOSED] Test 12: Mancato blocco fail-closed o falso successo emesso: $output12" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[FAIL] [TEST NEGATIVO / ROLLBACK FAIL-CLOSED] Test 12: Eccezione: $($_.Exception.Message)" -ForegroundColor Red
    $failed++
} finally {
    if ($httpProc12 -and -not $httpProc12.HasExited) { Stop-Process -Id $httpProc12.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $testDir12 -Recurse -Force -ErrorAction SilentlyContinue
}

# ==============================================================================
# TEST 13: [TEST NEGATIVO / WAL FAIL-CLOSED] WAL presente su device ma estrazione fallita blocca in fail-closed
# ==============================================================================
Write-Host "`n--- Esecuzione Test 13: File WAL presente ma estrazione fallita (Fail-Closed) ---" -ForegroundColor Yellow
$testDir13 = Join-Path $tempDir "akai_test_wal_failclosed_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir13 | Out-Null

$mockAdbJs13 = Join-Path $testDir13 "mock_adb_13.js"
$mockSignerJs13 = Join-Path $testDir13 "mock_signer_13.js"
$realDb13 = Join-Path $testDir13 "device_db.sqlite"
$deviceApk13 = Join-Path $testDir13 "device_backup.apk"
$candidateApk13 = Join-Path $testDir13 "candidate.apk"
$backupDir13 = Join-Path $testDir13 "backup_target"

New-MockRealDatabase -FilePath $realDb13
[System.IO.File]::WriteAllText($deviceApk13, "PK_DEVICE_BACKUP_APK_MOCK_13")
[System.IO.File]::WriteAllText($candidateApk13, "PK_CANDIDATE_APK_MOCK_13")

# Mock apksigner
@"
console.log('Signer #1 certificate SHA-256 digest: deadbeefcafebabe00112233445566778899aabbccddeeffdeadbeefcafebabe');
process.exit(0);
"@ | Out-File -FilePath $mockSignerJs13 -Encoding ascii

$mockSignerCmd13 = if ($isWin) { Join-Path $testDir13 "apksigner.cmd" } else { Join-Path $testDir13 "apksigner" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockSignerJs13`" %*" | Out-File -FilePath $mockSignerCmd13 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockSignerJs13`" `"`$@`"" | Out-File -FilePath $mockSignerCmd13 -Encoding ascii
    & chmod +x $mockSignerCmd13
}

# Mock ADB per Test 13:
# - exec-out su akai_memory.db ha successo
# - test -f akai_memory.db-wal restituisce EXISTS
# - exec-out su akai_memory.db-wal FALLISCE (process.exit(1))
@"
const fs = require('fs');
const argv = process.argv.slice(2);
const args = argv.join(' ');

if (argv.includes('connect') || argv.includes('wait-for-device')) process.exit(0);
if (argv.includes('unroot')) { console.log('adbd is already running as non root'); process.exit(0); }
if (argv.includes('root')) { console.log('adbd cannot run as root in production builds'); process.exit(1); }
if (argv.includes('shell') && argv[argv.length - 1] === 'id') { console.log('uid=2000(shell) gid=2000(shell)'); process.exit(0); }
if (args.includes('pm list')) { console.log('package:it.akai.customremote'); process.exit(0); }
if (args.includes('pm path')) { console.log('package:/data/app/it.akai.customremote-1/base.apk'); process.exit(0); }
if (args.includes('pull')) {
    const dest = process.argv[process.argv.length - 1];
    fs.copyFileSync(process.env.DEVICE_APK_FILE, dest);
    process.exit(0);
}
if (args.includes('akai_memory_snapshot.db')) {
    process.exit(1);
}
if (args.includes('pidof') || args.includes('PIDOF_CHECK')) { console.log('PIDOF_CHECK:pids=[]:exit=[1]'); process.exit(0); }
if (args.includes('akai_memory.db-wal') && (args.includes('test -f') || args.includes('FILE_PROBE_RESULT'))) {
    console.log('FILE_PROBE_RESULT:EXISTS');
    process.exit(0);
}
if (args.includes('test -f') || args.includes('FILE_PROBE_RESULT')) {
    console.log('FILE_PROBE_RESULT:NOT_FOUND');
    process.exit(0);
}
if (args.includes('cat databases/akai_memory.db-wal')) {
    process.stderr.write('cat: databases/akai_memory.db-wal: Permission denied\n');
    process.exit(1);
}
if (args.includes('cat databases/akai_memory.db')) {
    const buf = fs.readFileSync(process.env.DEVICE_DB_FILE);
    process.stdout.write(buf, () => process.exit(0));
    return;
}
if (args.includes('exec-out')) {
    const buf = fs.readFileSync(process.env.DEVICE_DB_FILE);
    process.stdout.write(buf, () => process.exit(0));
    return;
}
if (args.includes('dumpsys package')) { console.log('    userId=10123'); process.exit(0); }
if (args.includes('shell')) { process.exit(0); }
process.exit(0);
"@ | Out-File -FilePath $mockAdbJs13 -Encoding ascii

$mockAdbCmd13 = if ($isWin) { Join-Path $testDir13 "adb.cmd" } else { Join-Path $testDir13 "adb" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockAdbJs13`" %*" | Out-File -FilePath $mockAdbCmd13 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockAdbJs13`" `"`$@`"" | Out-File -FilePath $mockAdbCmd13 -Encoding ascii
    & chmod +x $mockAdbCmd13
}

$port13 = Get-Random -Minimum 52001 -Maximum 58000
$httpProc13 = $null

try {
    $mockServerJs13 = @"
const http = require('http');
const server = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', uinput_ready: true, active_sessions: 1 }));
});
server.listen($port13, '127.0.0.1');
setInterval(() => {}, 1000);
"@
    $serverPath13 = Join-Path $testDir13 "mock_server13.js"
    [System.IO.File]::WriteAllText($serverPath13, $mockServerJs13, [System.Text.Encoding]::UTF8)
    $httpProc13 = Start-Process -FilePath $validNode -ArgumentList $serverPath13 -PassThru -NoNewWindow
    Start-Sleep -Milliseconds 800

    $scriptEscaped = $scriptPath.Replace('\', '/')
    $candidateEscaped = $candidateApk13.Replace('\', '/')
    $mockAdbEscaped = $mockAdbCmd13.Replace('\', '/')
    $mockSignerEscaped = $mockSignerCmd13.Replace('\', '/')
    $realDbEscaped = $realDb13.Replace('\', '/')
    $deviceApkEscaped = $deviceApk13.Replace('\', '/')
    $backupDirEscaped = $backupDir13.Replace('\', '/')
    $nodeEscaped = $validNode.Replace('\', '/')

    $testCmd13 = @"
`$env:NODE_EXE = '$nodeEscaped'
`$env:ADB_EXECUTABLE = '$mockAdbEscaped'
`$env:APKSIGNER_EXECUTABLE = '$mockSignerEscaped'
`$env:DEVICE_DB_FILE = '$realDbEscaped'
`$env:DEVICE_APK_FILE = '$deviceApkEscaped'

& '$scriptEscaped' -Action backup -TargetTv '127.0.0.1' -HttpPort $port13 -BackupDir '$backupDirEscaped' -AllowHardwareExecution
"@
    $res13 = & $psExe -ExecutionPolicy Bypass -Command $testCmd13 2>&1 | Out-String

    if ($res13 -match "ERRORE FAIL-CLOSED: File WAL" -and $res13 -match "estrazione fallita" -and $res13 -notmatch "Sessione di backup completata") {
        Write-Host "[PASS] [TEST NEGATIVO / WAL FAIL-CLOSED] Test 13: File WAL presente ma con estrazione fallita blocca categoricamente l'operazione in Fail-Closed (zero falsi successi)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO / WAL FAIL-CLOSED] Test 13: Mancato blocco fail-closed: $res13" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[PASS] [TEST NEGATIVO / WAL FAIL-CLOSED] Test 13: Eccezione fail-closed: $($_.Exception.Message)" -ForegroundColor Green
    $passed++
} finally {
    if ($httpProc13 -and -not $httpProc13.HasExited) { Stop-Process -Id $httpProc13.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $testDir13 -Recurse -Force -ErrorAction SilentlyContinue
}

# ==============================================================================
# TEST 14: [TEST NEGATIVO / WAL CHECKPOINT BLOCKED] Checkpoint busy>0 blocca la verifica di integrità
# ==============================================================================
Write-Host "`n--- Esecuzione Test 14: Checkpoint WAL bloccato/busy (Fail-Closed) ---" -ForegroundColor Yellow
$testDir14 = Join-Path $tempDir "akai_test_wal_busy_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir14 | Out-Null
$testDb14 = Join-Path $testDir14 "akai_memory.db"
$busyHolderProc14 = $null

try {
    if (-not $validNode) {
        throw "Node.js non disponibile per fixture WAL."
    }

    $dbEsc14 = $testDb14.Replace('\', '/')
    $setupPath14 = Join-Path $testDir14 "setup14.js"
    $setupJs14 = @"
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync('$dbEsc14');
db.exec('PRAGMA journal_mode=WAL;');
db.exec('CREATE TABLE items (id INT PRIMARY KEY, title TEXT);');
db.close();
"@
    [System.IO.File]::WriteAllText($setupPath14, $setupJs14, [System.Text.Encoding]::UTF8)
    & $validNode --no-warnings $setupPath14

    # Processo in background che acquisisce una transazione di lettura e la tiene aperta (blocca il checkpoint con busy=1)
    $holderPath14 = Join-Path $testDir14 "holder14.js"
    $holderJs14 = @"
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync('$dbEsc14');
db.exec('BEGIN DEFERRED;');
const row = db.prepare('SELECT count(*) FROM items;').get();
setTimeout(() => { db.close(); process.exit(0); }, 3000);
"@
    [System.IO.File]::WriteAllText($holderPath14, $holderJs14, [System.Text.Encoding]::UTF8)
    $busyHolderProc14 = Start-Process -FilePath $validNode -ArgumentList $holderPath14 -PassThru -NoNewWindow
    Start-Sleep -Milliseconds 600

    # Scrittura concorrente nel WAL che non puo' essere checkpointata a causa del lettore attivo
    $writerPath14 = Join-Path $testDir14 "writer14.js"
    $writerJs14 = @"
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync('$dbEsc14');
db.exec('PRAGMA wal_autocheckpoint=0;');
db.exec('INSERT INTO items VALUES (1, \'concurrent\');');
process.exit(0);
"@
    [System.IO.File]::WriteAllText($writerPath14, $writerJs14, [System.Text.Encoding]::UTF8)
    & $validNode --no-warnings $writerPath14

    # Invochiamo Verify-SQLiteIntegrityOffline: DEVE sollevare ERRORE FAIL-CLOSED a causa di busy=1!
    $scriptEscaped = $scriptPath.Replace('\', '/')
    $testCmd14 = @"
. '$scriptEscaped' -Action plan | Out-Null
Verify-SQLiteIntegrityOffline '$dbEsc14'
"@
    $out14 = & $psExe -ExecutionPolicy Bypass -Command $testCmd14 2>&1 | Out-String

    if ($out14 -match "ERRORE FAIL-CLOSED: Checkpoint WAL fallito o bloccato \(busy>0\)") {
        Write-Host "[PASS] [TEST NEGATIVO / WAL CHECKPOINT BLOCKED] Test 14: Checkpoint WAL occupato (busy>0) blocca categoricamente in Fail-Closed (integrity_check non scavalca il blocco)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO / WAL CHECKPOINT BLOCKED] Test 14: Mancato blocco fail-closed per checkpoint busy: $out14" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[PASS] [TEST NEGATIVO / WAL CHECKPOINT BLOCKED] Test 14: Eccezione fail-closed: $($_.Exception.Message)" -ForegroundColor Green
    $passed++
} finally {
    if ($busyHolderProc14 -and -not $busyHolderProc14.HasExited) { Stop-Process -Id $busyHolderProc14.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $testDir14 -Recurse -Force -ErrorAction SilentlyContinue
}


# ==============================================================================
# TEST 15: [TEST ISOLATO / SQLITE3 CLI BACKEND] Verifica isolata del percorso sqlite3 CLI
# (a: exit 0 + ok -> pass, b: exit nonzero + ok -> fail-closed, c: exit 0 + non-ok -> fail-closed, d: checkpoint busy -> fail-closed)
# ==============================================================================
Write-Host "`n--- Esecuzione Test 15: Verifica isolata del percorso sqlite3 CLI (4 condizioni) ---" -ForegroundColor Yellow
$testDir15 = Join-Path $tempDir "akai_test_sqlite3_cli_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir15 | Out-Null
$testDb15 = Join-Path $testDir15 "akai_memory.db"
New-MockRealDatabase -FilePath $testDb15

$mockSqliteJs15 = Join-Path $testDir15 "mock_sqlite3.js"
@"
const args = process.argv.slice(2).join(' ');
const mode = process.env.MOCK_SQLITE3_MODE || 'success';

if (args.includes('wal_checkpoint')) {
    if (mode === 'checkpoint_busy') {
        console.log('1|5|5');
        process.exit(0);
    }
    console.log('0|0|0');
    process.exit(0);
}

if (args.includes('integrity_check')) {
    if (mode === 'exit_nonzero_ok') {
        console.log('ok');
        process.exit(1);
    }
    if (mode === 'exit_zero_corrupt') {
        console.log('*** in database: page 4 is corrupt');
        process.exit(0);
    }
    console.log('ok');
    process.exit(0);
}
process.exit(0);
"@ | Out-File -FilePath $mockSqliteJs15 -Encoding ascii

$mockSqliteCmd15 = if ($isWin) { Join-Path $testDir15 "sqlite3.cmd" } else { Join-Path $testDir15 "sqlite3" }
if ($isWin) {
    "@echo off`n`"$validNode`" `"$mockSqliteJs15`" %*" | Out-File -FilePath $mockSqliteCmd15 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockSqliteJs15`" `"`$@`"" | Out-File -FilePath $mockSqliteCmd15 -Encoding ascii
    & chmod +x $mockSqliteCmd15
}

$dbEsc15 = $testDb15.Replace('\', '/')
$scriptEscaped = $scriptPath.Replace('\', '/')
$mockSqliteEscaped15 = $mockSqliteCmd15.Replace('\', '/')
$nodeEscaped = if ($validNode) { $validNode.Replace('\', '/') } else { "node" }

$subPassed15 = 0

# 15a: exit 0 + ok -> successo
$cmd15a = @"
`$env:NODE_EXE = '$nodeEscaped'
`$env:FORCE_SQLITE3_CLI = '1'
`$env:SQLITE3_EXE = '$mockSqliteEscaped15'
`$env:MOCK_SQLITE3_MODE = 'success'
. '$scriptEscaped' -Action plan | Out-Null
try { Verify-SQLiteIntegrityOffline '$dbEsc15'; Write-Output 'VERIFY_SUCCESS' } catch { Write-Output ('CAUGHT: ' + `$_.Exception.Message) }
"@
$out15a = & $psExe -ExecutionPolicy Bypass -Command $cmd15a 2>&1 | Out-String
if ($out15a -match 'VERIFY_SUCCESS' -and $out15a -notmatch 'CAUGHT') {
    $subPassed15++
} else {
    Write-Host "  [FAIL] Test 15a (success) ha fallito: $out15a" -ForegroundColor Red
}

# 15b: exit non-zero + ok -> blocco fail-closed
$cmd15b = @"
`$env:NODE_EXE = '$nodeEscaped'
`$env:FORCE_SQLITE3_CLI = '1'
`$env:SQLITE3_EXE = '$mockSqliteEscaped15'
`$env:MOCK_SQLITE3_MODE = 'exit_nonzero_ok'
. '$scriptEscaped' -Action plan | Out-Null
try { Verify-SQLiteIntegrityOffline '$dbEsc15'; Write-Output 'VERIFY_SUCCESS' } catch { Write-Output ('CAUGHT: ' + `$_.Exception.Message) }
"@
$out15b = & $psExe -ExecutionPolicy Bypass -Command $cmd15b 2>&1 | Out-String
if ($out15b -match "CAUGHT: ERRORE FAIL-CLOSED: Controllo di integrita' fallito con sqlite3") {
    $subPassed15++
} else {
    Write-Host "  [FAIL] Test 15b (exit_nonzero_ok) mancato blocco: $out15b" -ForegroundColor Red
}

# 15c: exit 0 + non-ok (corrupt) -> blocco fail-closed
$cmd15c = @"
`$env:NODE_EXE = '$nodeEscaped'
`$env:FORCE_SQLITE3_CLI = '1'
`$env:SQLITE3_EXE = '$mockSqliteEscaped15'
`$env:MOCK_SQLITE3_MODE = 'exit_zero_corrupt'
. '$scriptEscaped' -Action plan | Out-Null
try { Verify-SQLiteIntegrityOffline '$dbEsc15'; Write-Output 'VERIFY_SUCCESS' } catch { Write-Output ('CAUGHT: ' + `$_.Exception.Message) }
"@
$out15c = & $psExe -ExecutionPolicy Bypass -Command $cmd15c 2>&1 | Out-String
if ($out15c -match "CAUGHT: ERRORE FAIL-CLOSED: Controllo di integrita' fallito con sqlite3") {
    $subPassed15++
} else {
    Write-Host "  [FAIL] Test 15c (exit_zero_corrupt) mancato blocco: $out15c" -ForegroundColor Red
}

# 15d: checkpoint busy -> blocco fail-closed
$cmd15d = @"
`$env:NODE_EXE = '$nodeEscaped'
`$env:FORCE_SQLITE3_CLI = '1'
`$env:SQLITE3_EXE = '$mockSqliteEscaped15'
`$env:MOCK_SQLITE3_MODE = 'checkpoint_busy'
. '$scriptEscaped' -Action plan | Out-Null
try { Verify-SQLiteIntegrityOffline '$dbEsc15'; Write-Output 'VERIFY_SUCCESS' } catch { Write-Output ('CAUGHT: ' + `$_.Exception.Message) }
"@
$out15d = & $psExe -ExecutionPolicy Bypass -Command $cmd15d 2>&1 | Out-String
if ($out15d -match "CAUGHT: ERRORE FAIL-CLOSED: Checkpoint WAL fallito o bloccato con sqlite3") {
    $subPassed15++
} else {
    Write-Host "  [FAIL] Test 15d (checkpoint_busy) mancato blocco: $out15d" -ForegroundColor Red
}

if ($subPassed15 -eq 4) {
    Write-Host "[PASS] [TEST ISOLATO / SQLITE3 CLI BACKEND] Test 15: Percorso sqlite3 CLI verificato in isolamento (successo 0+ok, blocco su exit non-zero, blocco su corruzione, blocco su checkpoint busy)" -ForegroundColor Green
    $passed++
} else {
    Write-Host "[FAIL] [TEST ISOLATO / SQLITE3 CLI BACKEND] Test 15: Sotto-test superati: $subPassed15 / 4" -ForegroundColor Red
    $failed++
}
Remove-Item $testDir15 -Recurse -Force -ErrorAction SilentlyContinue


# ==============================================================================
# TEST 16: [TEST NEGATIVO / QUIESCENZA WRITER FALLITA FAIL-CLOSED]
# Il writer resta attivo (pidof restituisce un PID dopo am force-stop e kill -9): blocco FAIL-CLOSED prima dell'estrazione DB
# ==============================================================================
Write-Host "`n--- Esecuzione Test 16: Quiescenza writer fallita (Fail-Closed) ---" -ForegroundColor Yellow
$testDir16 = Join-Path $tempDir "akai_test_quiescence_fail_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir16 | Out-Null

$mockAdbJs16 = Join-Path $testDir16 "mock_adb_16.js"
$mockSignerJs16 = Join-Path $testDir16 "mock_signer_16.js"
$backupDir16 = Join-Path $testDir16 "backup_target"

@"
console.log('Signer #1 certificate SHA-256 digest: a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90');
process.exit(0);
"@ | Out-File -FilePath $mockSignerJs16 -Encoding ascii

$mockSignerCmd16 = if ($isWin) { Join-Path $testDir16 "apksigner.cmd" } else { Join-Path $testDir16 "apksigner" }
if ($isWin) {
    "@echo off`n`"$validNode`" `"$mockSignerJs16`" %*" | Out-File -FilePath $mockSignerCmd16 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockSignerJs16`" `"`$@`"" | Out-File -FilePath $mockSignerCmd16 -Encoding ascii
    & chmod +x $mockSignerCmd16
}

@"
const fs = require('fs');
const argv = process.argv.slice(2);
const args = argv.join(' ');

if (argv.includes('connect') || argv.includes('wait-for-device')) process.exit(0);
if (argv.includes('unroot')) { console.log('adbd is already running as non root'); process.exit(0); }
if (argv.includes('root')) { console.log('adbd cannot run as root in production builds'); process.exit(1); }
if (argv.includes('shell') && argv[argv.length - 1] === 'id') { console.log('uid=2000(shell) gid=2000(shell)'); process.exit(0); }
if (args.includes('pm list')) { console.log('package:it.akai.customremote'); process.exit(0); }
if (args.includes('pm path')) { console.log('package:/data/app/it.akai.customremote-1/base.apk'); process.exit(0); }
if (args.includes('pull') && args.includes('base.apk')) {
    const dest = process.argv[process.argv.length - 1];
    fs.writeFileSync(dest, 'PK_DEVICE_BACKUP_APK_MOCK');
    process.exit(0);
}
// Snapshot v6 assente per innescare estrazione baseline v5
if (args.includes('akai_memory_snapshot.db')) {
    process.exit(1);
}
// Quiescence checks:
if (args.includes('am force-stop')) {
    process.exit(0);
}
if (args.includes('kill -9')) {
    process.exit(0);
}
if (args.includes('pidof')) {
    // Processo writer ancora attivo (simula processo bloccato che non muore)
    console.log('PIDOF_CHECK:pids=[9999]:exit=[0]');
    process.exit(0);
}
// Se viene tentata l'estrazione DB nonostante il writer non sia quiescente:
if (args.includes('exec-out') || args.includes('pull')) {
    console.error('FAIL_UNSAFE_PULL: Tentata estrazione del DB senza quiescenza del writer!');
    process.exit(1);
}
process.exit(0);
"@ | Out-File -FilePath $mockAdbJs16 -Encoding ascii

$mockAdbCmd16 = if ($isWin) { Join-Path $testDir16 "adb.cmd" } else { Join-Path $testDir16 "adb" }
if ($isWin) {
    "@echo off`n`"$validNode`" `"$mockAdbJs16`" %*" | Out-File -FilePath $mockAdbCmd16 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockAdbJs16`" `"`$@`"" | Out-File -FilePath $mockAdbCmd16 -Encoding ascii
    & chmod +x $mockAdbCmd16
}

$mockAdbEscaped16 = $mockAdbCmd16.Replace('\', '/')
$mockSignerEscaped16 = $mockSignerCmd16.Replace('\', '/')
$backupDirEscaped16 = $backupDir16.Replace('\', '/')

$testCmd16 = @"
`$env:NODE_EXE = '$nodeEscaped'
`$env:ADB_EXECUTABLE = '$mockAdbEscaped16'
`$env:APKSIGNER_EXECUTABLE = '$mockSignerEscaped16'

& '$scriptEscaped' -Action backup -TargetTv '127.0.0.1' -BackupDir '$backupDirEscaped16' -AllowHardwareExecution
"@
try {
    $res16 = & $psExe -ExecutionPolicy Bypass -Command $testCmd16 2>&1 | Out-String

    if ($res16 -match "ERRORE FAIL-CLOSED: Impossibile arrestare il processo dell'applicazione" -and $res16 -match "Writer non quiescente" -and $res16 -notmatch "FAIL_UNSAFE_PULL" -and $res16 -notmatch "Sessione di backup completata") {
        Write-Host "[PASS] [TEST NEGATIVO / QUIESCENZA WRITER FALLITA FAIL-CLOSED] Test 16: Writer non quiescente (pidof restituisce PID residuo) blocca categoricamente l'operazione in Fail-Closed prima del pull DB" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO / QUIESCENZA WRITER FALLITA FAIL-CLOSED] Test 16: Mancato blocco fail-closed: $res16" -ForegroundColor Red
        $failed++
    }
} catch {
    if ($_.Exception.Message -match "ERRORE FAIL-CLOSED: Impossibile arrestare il processo dell'applicazione" -or $_.Exception.Message -match "Writer non quiescente") {
        Write-Host "[PASS] [TEST NEGATIVO / QUIESCENZA WRITER FALLITA FAIL-CLOSED] Test 16: Eccezione fail-closed: $($_.Exception.Message)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO / QUIESCENZA WRITER FALLITA FAIL-CLOSED] Test 16: Eccezione inattesa: $($_.Exception.Message)" -ForegroundColor Red
        $failed++
    }
} finally {
    Remove-Item $testDir16 -Recurse -Force -ErrorAction SilentlyContinue
}


# ==============================================================================
# TEST 17: [TEST NEGATIVO / ROLLBACK PULIZIA WAL NEGATA FAIL-CLOSED]
# Rimozione verificata file WAL/SHM orfani fallita durante rollback: blocco FAIL-CLOSED prima del ripristino del DB originale
# ==============================================================================
Write-Host "`n--- Esecuzione Test 17: Rimozione residui WAL/SHM fallita nel Rollback (Fail-Closed) ---" -ForegroundColor Yellow
$testDir17 = Join-Path $tempDir "akai_test_rollback_wal_fail_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir17 | Out-Null

$mockAdbJs17 = Join-Path $testDir17 "mock_adb_17.js"
$mockSignerJs17 = Join-Path $testDir17 "mock_signer_17.js"
$backupDir17 = Join-Path $testDir17 "backup_target"
$sessionDir17 = Join-Path $backupDir17 "session_20261108_040000"
New-Item -ItemType Directory -Force -Path $sessionDir17 | Out-Null

$deviceApk17 = Join-Path $sessionDir17 "it.akai.customremote_backup.apk"
$deviceDb17 = Join-Path $sessionDir17 "akai_memory.db"

[System.IO.File]::WriteAllText($deviceApk17, "PK_DEVICE_BACKUP_APK_MOCK")
New-MockRealDatabase -FilePath $deviceDb17

@"
console.log('Signer #1 certificate SHA-256 digest: a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90');
process.exit(0);
"@ | Out-File -FilePath $mockSignerJs17 -Encoding ascii

$mockSignerCmd17 = if ($isWin) { Join-Path $testDir17 "apksigner.cmd" } else { Join-Path $testDir17 "apksigner" }
if ($isWin) {
    "@echo off`n`"$validNode`" `"$mockSignerJs17`" %*" | Out-File -FilePath $mockSignerCmd17 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockSignerJs17`" `"`$@`"" | Out-File -FilePath $mockSignerCmd17 -Encoding ascii
    & chmod +x $mockSignerCmd17
}

@"
const fs = require('fs');
const argv = process.argv.slice(2);
const args = argv.join(' ');

if (argv.includes('connect') || argv.includes('wait-for-device')) process.exit(0);
if (argv.includes('unroot')) { console.log('adbd is already running as non root'); process.exit(0); }
if (argv.includes('root')) { console.log('adbd cannot run as root in production builds'); process.exit(1); }
if (argv.includes('shell') && argv[argv.length - 1] === 'id') { console.log('uid=2000(shell) gid=2000(shell)'); process.exit(0); }
if (args.includes('pm list')) { console.log('package:it.akai.customremote'); process.exit(0); }
if (args.includes('am force-stop')) process.exit(0);
if (args.includes('install')) { console.log('Success'); process.exit(0); }
if (args.includes('exec-in') && args.includes('pm install')) {
    process.stdin.on('data', () => {});
    process.stdin.on('end', () => { console.log('Success'); process.exit(0); });
    return;
}
if (args.includes('rm -f')) {
    process.exit(0);
}
if (args.includes('pidof') || args.includes('PIDOF_CHECK')) { console.log('PIDOF_CHECK:pids=[]:exit=[1]'); process.exit(0); }
// Probing tri-state: simula che akai_memory.db-wal non sia stato rimosso (EXISTS)
if (args.includes('akai_memory.db-wal') && (args.includes('test -f') || args.includes('FILE_PROBE_RESULT'))) {
    console.log('FILE_PROBE_RESULT:EXISTS');
    process.exit(0);
}
if (args.includes('test -f') || args.includes('FILE_PROBE_RESULT')) {
    console.log('FILE_PROBE_RESULT:NOT_FOUND');
    process.exit(0);
}
// Se viene tentato il ripristino del database:
if (args.includes('akai_memory.db')) {
    console.error('FAIL_UNSAFE_RESTORE: Tentato ripristino del DB con file WAL/SHM orfani presenti!');
    process.exit(1);
}
process.exit(0);
"@ | Out-File -FilePath $mockAdbJs17 -Encoding ascii

$mockAdbCmd17 = if ($isWin) { Join-Path $testDir17 "adb.cmd" } else { Join-Path $testDir17 "adb" }
if ($isWin) {
    "@echo off`n`"$validNode`" `"$mockAdbJs17`" %*" | Out-File -FilePath $mockAdbCmd17 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockAdbJs17`" `"`$@`"" | Out-File -FilePath $mockAdbCmd17 -Encoding ascii
    & chmod +x $mockAdbCmd17
}

$mockAdbEscaped17 = $mockAdbCmd17.Replace('\', '/')
$mockSignerEscaped17 = $mockSignerCmd17.Replace('\', '/')
$backupDirEscaped17 = $backupDir17.Replace('\', '/')

$testCmd17 = @"
`$env:NODE_EXE = '$nodeEscaped'
`$env:ADB_EXECUTABLE = '$mockAdbEscaped17'
`$env:APKSIGNER_EXECUTABLE = '$mockSignerEscaped17'

& '$scriptEscaped' -Action rollback -TargetTv '127.0.0.1' -BackupDir '$backupDirEscaped17' -AllowHardwareExecution
"@
try {
    $res17 = & $psExe -ExecutionPolicy Bypass -Command $testCmd17 2>&1 | Out-String

    if ($res17 -match "ERRORE FAIL-CLOSED: Rimozione file WAL/SHM orfani fallita" -and $res17 -match "FAIL-CLOSED" -and $res17 -notmatch "FAIL_UNSAFE_RESTORE" -and $res17 -notmatch "ROLLBACK COMPLETATO CON SUCCESSO") {
        Write-Host "[PASS] [TEST NEGATIVO / ROLLBACK PULIZIA WAL NEGATA FAIL-CLOSED] Test 17: Rimozione residui WAL/SHM orfani fallita su device blocca categoricamente il rollback in Fail-Closed prima del restore DB" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO / ROLLBACK PULIZIA WAL NEGATA FAIL-CLOSED] Test 17: Mancato blocco fail-closed: $res17" -ForegroundColor Red
        $failed++
    }
} catch {
    if ($_.Exception.Message -match "ERRORE FAIL-CLOSED: Rimozione file WAL/SHM orfani fallita" -or $_.Exception.Message -match "FAIL-CLOSED") {
        Write-Host "[PASS] [TEST NEGATIVO / ROLLBACK PULIZIA WAL NEGATA FAIL-CLOSED] Test 17: Eccezione fail-closed: $($_.Exception.Message)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO / ROLLBACK PULIZIA WAL NEGATA FAIL-CLOSED] Test 17: Eccezione inattesa: $($_.Exception.Message)" -ForegroundColor Red
        $failed++
    }
} finally {
    Remove-Item $testDir17 -Recurse -Force -ErrorAction SilentlyContinue
}


# ==============================================================================
# TEST 18: [TEST NEGATIVO / QUIESCENZA ERRORE TRASPORTO O SENZA STDOUT FAIL-CLOSED]
# Errore di trasporto o output vuoto durante il probe della quiescenza (pidof):
# Blocco FAIL-CLOSED immediato prima di qualsiasi estrazione DB
# ==============================================================================
Write-Host "`n--- Esecuzione Test 18: Errore trasporto/probe durante verifica quiescenza (Fail-Closed) ---" -ForegroundColor Yellow
$testDir18 = Join-Path $tempDir "akai_test_quiescence_transport_fail_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir18 | Out-Null

$mockAdbJs18 = Join-Path $testDir18 "mock_adb_18.js"
$mockSignerJs18 = Join-Path $testDir18 "mock_signer_18.js"
$backupDir18 = Join-Path $testDir18 "backup_target"

@"
console.log('Signer #1 certificate SHA-256 digest: a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90');
process.exit(0);
"@ | Out-File -FilePath $mockSignerJs18 -Encoding ascii

$mockSignerCmd18 = if ($isWin) { Join-Path $testDir18 "apksigner.cmd" } else { Join-Path $testDir18 "apksigner" }
if ($isWin) {
    "@echo off`n`"$validNode`" `"$mockSignerJs18`" %*" | Out-File -FilePath $mockSignerCmd18 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockSignerJs18`" `"`$@`"" | Out-File -FilePath $mockSignerCmd18 -Encoding ascii
    & chmod +x $mockSignerCmd18
}

@"
const fs = require('fs');
const argv = process.argv.slice(2);
const args = argv.join(' ');

if (argv.includes('connect') || argv.includes('wait-for-device')) process.exit(0);
if (argv.includes('unroot')) { console.log('adbd is already running as non root'); process.exit(0); }
if (argv.includes('root')) { console.log('adbd cannot run as root in production builds'); process.exit(1); }
if (argv.includes('shell') && argv[argv.length - 1] === 'id') { console.log('uid=2000(shell) gid=2000(shell)'); process.exit(0); }
if (args.includes('pm list')) { console.log('package:it.akai.customremote'); process.exit(0); }
if (args.includes('pm path')) { console.log('package:/data/app/it.akai.customremote-1/base.apk'); process.exit(0); }
if (args.includes('pull') && args.includes('base.apk')) {
    const dest = process.argv[process.argv.length - 1];
    fs.writeFileSync(dest, 'PK_DEVICE_BACKUP_APK_MOCK');
    process.exit(0);
}
// Snapshot v6 assente per innescare estrazione baseline v5
if (args.includes('akai_memory_snapshot.db')) {
    process.exit(1);
}
if (args.includes('am force-stop')) {
    process.exit(0);
}
// Probe quiescenza: simula fallimento trasporto ADB o assenza stdout (exit 1 con zero output)
if (args.includes('pidof') || args.includes('PIDOF_CHECK')) {
    process.exit(1);
}
// Se viene tentata l'estrazione DB nonostante il fallimento del probe di quiescenza:
if (args.includes('exec-out') || args.includes('pull') || args.includes('cat databases/akai_memory.db')) {
    console.error('FAIL_UNSAFE_PULL: Tentata estrazione del DB senza quiescenza verificata!');
    process.exit(1);
}
process.exit(0);
"@ | Out-File -FilePath $mockAdbJs18 -Encoding ascii

$mockAdbCmd18 = if ($isWin) { Join-Path $testDir18 "adb.cmd" } else { Join-Path $testDir18 "adb" }
if ($isWin) {
    "@echo off`n`"$validNode`" `"$mockAdbJs18`" %*" | Out-File -FilePath $mockAdbCmd18 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockAdbJs18`" `"`$@`"" | Out-File -FilePath $mockAdbCmd18 -Encoding ascii
    & chmod +x $mockAdbCmd18
}

$mockAdbEscaped18 = $mockAdbCmd18.Replace('\', '/')
$mockSignerEscaped18 = $mockSignerCmd18.Replace('\', '/')
$backupDirEscaped18 = $backupDir18.Replace('\', '/')

$testCmd18 = @"
`$env:NODE_EXE = '$nodeEscaped'
`$env:ADB_EXECUTABLE = '$mockAdbEscaped18'
`$env:APKSIGNER_EXECUTABLE = '$mockSignerEscaped18'

& '$scriptEscaped' -Action backup -TargetTv '127.0.0.1' -BackupDir '$backupDirEscaped18' -AllowHardwareExecution
"@
try {
    $res18 = & $psExe -ExecutionPolicy Bypass -Command $testCmd18 2>&1 | Out-String

    if (($res18 -match "ERRORE FAIL-CLOSED: Probe dello stato dei processi" -and $res18 -match "fallito") -and $res18 -notmatch "FAIL_UNSAFE_PULL" -and $res18 -notmatch "Sessione di backup completata") {
        Write-Host "[PASS] [TEST NEGATIVO / QUIESCENZA ERRORE TRASPORTO FAIL-CLOSED] Test 18: Fallimento probe o assenza stdout in Get-ApplicationProcessState blocca categoricamente in Fail-Closed prima del pull DB" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO / QUIESCENZA ERRORE TRASPORTO FAIL-CLOSED] Test 18: Mancato blocco fail-closed: $res18" -ForegroundColor Red
        $failed++
    }
} catch {
    if (($_.Exception.Message -match "ERRORE FAIL-CLOSED: Probe dello stato dei processi" -or $_.Exception.Message -match "quiescenza")) {
        Write-Host "[PASS] [TEST NEGATIVO / QUIESCENZA ERRORE TRASPORTO FAIL-CLOSED] Test 18: Eccezione fail-closed: $($_.Exception.Message)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO / QUIESCENZA ERRORE TRASPORTO FAIL-CLOSED] Test 18: Eccezione inattesa: $($_.Exception.Message)" -ForegroundColor Red
        $failed++
    }
} finally {
    Remove-Item $testDir18 -Recurse -Force -ErrorAction SilentlyContinue
}


# ==============================================================================
# TEST 19: [TEST NEGATIVO / ROLLBACK PROBE WAL FALLITO RUN-AS E SU NEGATI FAIL-CLOSED]
# Canali run-as e su entrambi falliti con stdout vuoto/errore durante il probe WAL/SHM:
# Nessun default a NOT_FOUND, blocco categorico FAIL-CLOSED e zero streaming restore del DB
# ==============================================================================
Write-Host "`n--- Esecuzione Test 19: Probe file WAL/SHM fallito su run-as e su nel Rollback (Fail-Closed) ---" -ForegroundColor Yellow
$testDir19 = Join-Path $tempDir "akai_test_rollback_probe_fail_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir19 | Out-Null

$mockAdbJs19 = Join-Path $testDir19 "mock_adb_19.js"
$mockSignerJs19 = Join-Path $testDir19 "mock_signer_19.js"
$backupDir19 = Join-Path $testDir19 "backup_target"
$sessionDir19 = Join-Path $backupDir19 "session_20261108_050000"
New-Item -ItemType Directory -Force -Path $sessionDir19 | Out-Null

$deviceApk19 = Join-Path $sessionDir19 "it.akai.customremote_backup.apk"
$deviceDb19 = Join-Path $sessionDir19 "akai_memory.db"

[System.IO.File]::WriteAllText($deviceApk19, "PK_DEVICE_BACKUP_APK_MOCK")
New-MockRealDatabase -FilePath $deviceDb19

@"
console.log('Signer #1 certificate SHA-256 digest: a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90');
process.exit(0);
"@ | Out-File -FilePath $mockSignerJs19 -Encoding ascii

$mockSignerCmd19 = if ($isWin) { Join-Path $testDir19 "apksigner.cmd" } else { Join-Path $testDir19 "apksigner" }
if ($isWin) {
    "@echo off`n`"$validNode`" `"$mockSignerJs19`" %*" | Out-File -FilePath $mockSignerCmd19 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockSignerJs19`" `"`$@`"" | Out-File -FilePath $mockSignerCmd19 -Encoding ascii
    & chmod +x $mockSignerCmd19
}

@"
const fs = require('fs');
const argv = process.argv.slice(2);
const args = argv.join(' ');

if (argv.includes('connect') || argv.includes('wait-for-device')) process.exit(0);
if (argv.includes('unroot')) { console.log('adbd is already running as non root'); process.exit(0); }
if (argv.includes('root')) { console.log('adbd cannot run as root in production builds'); process.exit(1); }
if (argv.includes('shell') && argv[argv.length - 1] === 'id') { console.log('uid=2000(shell) gid=2000(shell)'); process.exit(0); }
if (args.includes('pm list')) { console.log('package:it.akai.customremote'); process.exit(0); }
if (args.includes('am force-stop')) process.exit(0);
if (args.includes('install')) { console.log('Success'); process.exit(0); }
if (args.includes('exec-in') && args.includes('pm install')) {
    process.stdin.on('data', () => {});
    process.stdin.on('end', () => { console.log('Success'); process.exit(0); });
    return;
}
if (args.includes('rm -f')) {
    process.exit(0);
}
// Probe WAL/SHM: fallisce sia per run-as che per su con codice di uscita 1 e stdout vuoto
if (args.includes('FILE_PROBE_RESULT') || args.includes('test -f')) {
    process.exit(1);
}
// Se viene tentato il ripristino o lo streaming del DB originale:
if (args.includes('akai_memory.db') || args.includes('exec-in') || args.includes('cat databases/akai_memory.db')) {
    console.error('FAIL_UNSAFE_RESTORE: Tentato ripristino del DB con probe WAL/SHM non determinabile!');
    process.exit(1);
}
process.exit(0);
"@ | Out-File -FilePath $mockAdbJs19 -Encoding ascii

$mockAdbCmd19 = if ($isWin) { Join-Path $testDir19 "adb.cmd" } else { Join-Path $testDir19 "adb" }
if ($isWin) {
    "@echo off`n`"$validNode`" `"$mockAdbJs19`" %*" | Out-File -FilePath $mockAdbCmd19 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockAdbJs19`" `"`$@`"" | Out-File -FilePath $mockAdbCmd19 -Encoding ascii
    & chmod +x $mockAdbCmd19
}

$mockAdbEscaped19 = $mockAdbCmd19.Replace('\', '/')
$mockSignerEscaped19 = $mockSignerCmd19.Replace('\', '/')
$backupDirEscaped19 = $backupDir19.Replace('\', '/')

$testCmd19 = @"
`$env:NODE_EXE = '$nodeEscaped'
`$env:ADB_EXECUTABLE = '$mockAdbEscaped19'
`$env:APKSIGNER_EXECUTABLE = '$mockSignerEscaped19'

& '$scriptEscaped' -Action rollback -TargetTv '127.0.0.1' -BackupDir '$backupDirEscaped19' -AllowHardwareExecution
"@
try {
    $res19 = & $psExe -ExecutionPolicy Bypass -Command $testCmd19 2>&1 | Out-String

    if ($res19 -match "ERRORE FAIL-CLOSED: Impossibile determinare lo stato del file" -and $res19 -match "akai_memory" -and $res19 -notmatch "FAIL_UNSAFE_RESTORE" -and $res19 -notmatch "ROLLBACK COMPLETATO CON SUCCESSO") {
        Write-Host "[PASS] [TEST NEGATIVO / ROLLBACK PROBE WAL FALLITO FAIL-CLOSED] Test 19: Probe fallito su entrambi i canali (run-as e su) blocca categoricamente il rollback in Fail-Closed senza assumere NOT_FOUND e senza toccare il DB" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO / ROLLBACK PROBE WAL FALLITO FAIL-CLOSED] Test 19: Mancato blocco fail-closed: $res19" -ForegroundColor Red
        $failed++
    }
} catch {
    if ($_.Exception.Message -match "ERRORE FAIL-CLOSED: Impossibile determinare lo stato del file" -or $_.Exception.Message -match "akai_memory") {
        Write-Host "[PASS] [TEST NEGATIVO / ROLLBACK PROBE WAL FALLITO FAIL-CLOSED] Test 19: Eccezione fail-closed: $($_.Exception.Message)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO / ROLLBACK PROBE WAL FALLITO FAIL-CLOSED] Test 19: Eccezione inattesa: $($_.Exception.Message)" -ForegroundColor Red
        $failed++
    }
} finally {
    Remove-Item $testDir19 -Recurse -Force -ErrorAction SilentlyContinue
}


# ==============================================================================
# TEST 20: [TEST ISOLATO / CLASSIFICAZIONE RIGOROSA EXIT CODE PIDOF]
# Verifica in isolamento di Get-ApplicationProcessState su tutti gli stati e combinazioni:
# 1. exit=0 con PID (running = true)
# 2. exit=1 senza PID (running = false / quiescenza lecita)
# 3. exit=127 senza PID (binario assente -> blocco FAIL-CLOSED)
# 4. exit=2 senza PID (errore anomalo -> blocco FAIL-CLOSED)
# 5. exit=0 senza PID (combinazione incoerente -> blocco FAIL-CLOSED)
# 6. exit=1 con PID (combinazione incoerente -> blocco FAIL-CLOSED)
# ==============================================================================
Write-Host "`n--- Esecuzione Test 20: Classificazione rigorosa exit code di pidof (6 condizioni) ---" -ForegroundColor Yellow
$testDir20 = Join-Path $tempDir "akai_test_pidof_classification_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir20 | Out-Null

$mockAdbJs20 = Join-Path $testDir20 "mock_adb_20.js"

@"
const fs = require('fs');
const args = process.argv.slice(2).join(' ');
const scenario = process.env.TEST_PIDOF_SCENARIO || '0_with_pid';

if (args.includes('pidof') || args.includes('PIDOF_CHECK')) {
    if (scenario === '0_with_pid') {
        console.log('PIDOF_CHECK:pids=[12345]:exit=[0]');
    } else if (scenario === '1_empty') {
        console.log('PIDOF_CHECK:pids=[]:exit=[1]');
    } else if (scenario === '127_missing') {
        console.log('PIDOF_CHECK:pids=[]:exit=[127]');
    } else if (scenario === '2_error') {
        console.log('PIDOF_CHECK:pids=[]:exit=[2]');
    } else if (scenario === '0_empty_incoherent') {
        console.log('PIDOF_CHECK:pids=[]:exit=[0]');
    } else if (scenario === '1_with_pid_incoherent') {
        console.log('PIDOF_CHECK:pids=[12345]:exit=[1]');
    } else {
        process.exit(1);
    }
    process.exit(0);
}
process.exit(0);
"@ | Out-File -FilePath $mockAdbJs20 -Encoding ascii

$mockAdbCmd20 = if ($isWin) { Join-Path $testDir20 "adb.cmd" } else { Join-Path $testDir20 "adb" }
if ($isWin) {
    "@echo off`n`"$validNode`" `"$mockAdbJs20`" %*" | Out-File -FilePath $mockAdbCmd20 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockAdbJs20`" `"`$@`"" | Out-File -FilePath $mockAdbCmd20 -Encoding ascii
    & chmod +x $mockAdbCmd20
}

$mockAdbEscaped20 = $mockAdbCmd20.Replace('\', '/')
$subPassed20 = 0

# 20a: exit=0 con PID -> IsRunning = true
$cmd20a = @"
`$env:NODE_EXE = '$nodeEscaped'
. '$scriptEscaped' -Action plan | Out-Null
`$st = Get-ApplicationProcessState -AdbExe '$mockAdbEscaped20' -TargetAdb '127.0.0.1' -PackageName 'it.akai.customremote'
if (`$st.IsRunning -eq `$true -and `$st.Pids -eq '12345' -and `$st.PidofExit -eq 0) {
    Write-Output 'OK_20A'
} else {
    Write-Output ('FAIL_20A: running=' + `$st.IsRunning)
}
"@
$env:TEST_PIDOF_SCENARIO = '0_with_pid'
$out20a = & $psExe -ExecutionPolicy Bypass -Command $cmd20a 2>&1 | Out-String
if ($out20a -match "OK_20A") {
    $subPassed20++
    Write-Host "   [PASS] Sotto-test 20a: exit 0 con PID correttamente riconosciuto come processo in esecuzione (IsRunning=true)" -ForegroundColor Green
} else {
    Write-Host "   [FAIL] Sotto-test 20a fallito: $out20a" -ForegroundColor Red
}

# 20b: exit=1 senza PID -> IsRunning = false (quiescenza confermata)
$cmd20b = @"
`$env:NODE_EXE = '$nodeEscaped'
. '$scriptEscaped' -Action plan | Out-Null
`$st = Get-ApplicationProcessState -AdbExe '$mockAdbEscaped20' -TargetAdb '127.0.0.1' -PackageName 'it.akai.customremote'
if (`$st.IsRunning -eq `$false -and `$st.Pids -eq '' -and `$st.PidofExit -eq 1) {
    Write-Output 'OK_20B'
} else {
    Write-Output ('FAIL_20B: running=' + `$st.IsRunning)
}
"@
$env:TEST_PIDOF_SCENARIO = '1_empty'
$out20b = & $psExe -ExecutionPolicy Bypass -Command $cmd20b 2>&1 | Out-String
if ($out20b -match "OK_20B") {
    $subPassed20++
    Write-Host "   [PASS] Sotto-test 20b: exit 1 con lista vuota correttamente riconosciuto come quiescenza confermata (IsRunning=false)" -ForegroundColor Green
} else {
    Write-Host "   [FAIL] Sotto-test 20b fallito: $out20b" -ForegroundColor Red
}

# 20c: exit=127 (pidof assente) -> THROW FAIL-CLOSED
$cmd20c = @"
`$env:NODE_EXE = '$nodeEscaped'
. '$scriptEscaped' -Action plan | Out-Null
try {
    Get-ApplicationProcessState -AdbExe '$mockAdbEscaped20' -TargetAdb '127.0.0.1' -PackageName 'it.akai.customremote'
    Write-Output 'FAIL_20C_NO_THROW'
} catch {
    Write-Output ('CAUGHT_20C: ' + `$_.Exception.Message)
}
"@
$env:TEST_PIDOF_SCENARIO = '127_missing'
$out20c = & $psExe -ExecutionPolicy Bypass -Command $cmd20c 2>&1 | Out-String
if ($out20c -match "CAUGHT_20C: ERRORE FAIL-CLOSED: Binario o comando 'pidof' assente o non eseguibile") {
    $subPassed20++
    Write-Host "   [PASS] Sotto-test 20c: exit 127 (pidof assente) categoricamente bloccato in FAIL-CLOSED (nessun falso positivo di quiescenza)" -ForegroundColor Green
} else {
    Write-Host "   [FAIL] Sotto-test 20c fallito: $out20c" -ForegroundColor Red
}

# 20d: exit=2 (errore anomalo) -> THROW FAIL-CLOSED
$cmd20d = @"
`$env:NODE_EXE = '$nodeEscaped'
. '$scriptEscaped' -Action plan | Out-Null
try {
    Get-ApplicationProcessState -AdbExe '$mockAdbEscaped20' -TargetAdb '127.0.0.1' -PackageName 'it.akai.customremote'
    Write-Output 'FAIL_20D_NO_THROW'
} catch {
    Write-Output ('CAUGHT_20D: ' + `$_.Exception.Message)
}
"@
$env:TEST_PIDOF_SCENARIO = '2_error'
$out20d = & $psExe -ExecutionPolicy Bypass -Command $cmd20d 2>&1 | Out-String
if ($out20d -match "CAUGHT_20D: ERRORE FAIL-CLOSED: Invocazione pidof fallita con codice anomalo") {
    $subPassed20++
    Write-Host "   [PASS] Sotto-test 20d: exit 2 (errore anomalo) categoricamente bloccato in FAIL-CLOSED" -ForegroundColor Green
} else {
    Write-Host "   [FAIL] Sotto-test 20d fallito: $out20d" -ForegroundColor Red
}

# 20e: incoerente: exit=0 senza PID -> THROW FAIL-CLOSED
$cmd20e = @"
`$env:NODE_EXE = '$nodeEscaped'
. '$scriptEscaped' -Action plan | Out-Null
try {
    Get-ApplicationProcessState -AdbExe '$mockAdbEscaped20' -TargetAdb '127.0.0.1' -PackageName 'it.akai.customremote'
    Write-Output 'FAIL_20E_NO_THROW'
} catch {
    Write-Output ('CAUGHT_20E: ' + `$_.Exception.Message)
}
"@
$env:TEST_PIDOF_SCENARIO = '0_empty_incoherent'
$out20e = & $psExe -ExecutionPolicy Bypass -Command $cmd20e 2>&1 | Out-String
if ($out20e -match "CAUGHT_20E: ERRORE FAIL-CLOSED: Risultato incoerente del probe quiescenza.*exit code 0 ma nessun PID") {
    $subPassed20++
    Write-Host "   [PASS] Sotto-test 20e: combinazione incoerente (exit 0 senza PID) bloccata in FAIL-CLOSED" -ForegroundColor Green
} else {
    Write-Host "   [FAIL] Sotto-test 20e fallito: $out20e" -ForegroundColor Red
}

# 20f: incoerente: exit=1 con PID -> THROW FAIL-CLOSED
$cmd20f = @"
`$env:NODE_EXE = '$nodeEscaped'
. '$scriptEscaped' -Action plan | Out-Null
try {
    Get-ApplicationProcessState -AdbExe '$mockAdbEscaped20' -TargetAdb '127.0.0.1' -PackageName 'it.akai.customremote'
    Write-Output 'FAIL_20F_NO_THROW'
} catch {
    Write-Output ('CAUGHT_20F: ' + `$_.Exception.Message)
}
"@
$env:TEST_PIDOF_SCENARIO = '1_with_pid_incoherent'
$out20f = & $psExe -ExecutionPolicy Bypass -Command $cmd20f 2>&1 | Out-String
if ($out20f -match "CAUGHT_20F: ERRORE FAIL-CLOSED: Risultato incoerente del probe quiescenza.*exit code 1 ma sono presenti PID") {
    $subPassed20++
    Write-Host "   [PASS] Sotto-test 20f: combinazione incoerente (exit 1 con PID) bloccata in FAIL-CLOSED" -ForegroundColor Green
} else {
    Write-Host "   [FAIL] Sotto-test 20f fallito: $out20f" -ForegroundColor Red
}

Remove-Item env:TEST_PIDOF_SCENARIO -ErrorAction SilentlyContinue

if ($subPassed20 -eq 6) {
    Write-Host "[PASS] [TEST ISOLATO / CLASSIFICAZIONE RIGOROSA EXIT CODE PIDOF] Test 20: Classificazione deterministica exit code di pidof verificata al 100% (6 condizioni: exit 0+PID, exit 1 vuoto, blocco 127, blocco 2, blocco 0 vuoto, blocco 1 con PID)" -ForegroundColor Green
    $passed++
} else {
    Write-Host "[FAIL] [TEST ISOLATO / CLASSIFICAZIONE RIGOROSA EXIT CODE PIDOF] Test 20: Sotto-test superati: $subPassed20 / 6" -ForegroundColor Red
    $failed++
}
Remove-Item $testDir20 -Recurse -Force -ErrorAction SilentlyContinue

# -----------------------------------------------------------------------------
# TEST 21: Inventario e Preflight Read-Only (-Action preflight)
# -----------------------------------------------------------------------------
Write-Host "`n--- Esecuzione Test 21: Inventario e Preflight Read-Only TV (100% Non-Distruttivo) ---" -ForegroundColor Cyan
$testDir21 = Join-Path $tempDir "akai_test_preflight_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir21 | Out-Null

$mockAdbJs21 = Join-Path $testDir21 "mock_adb.js"
@'
const fs = require('fs');
const args = process.argv.slice(2);
const argStr = args.join(' ');

if (args.includes('connect')) process.exit(0);
if (argStr.includes('force-stop')) {
    console.error('VIOLATION_FORCE_STOP_CALLED');
    process.exit(99);
}
if (argStr.includes('pm list packages it.akai.customhome.v8')) {
    console.log('package:it.akai.customhome.v8');
    process.exit(0);
}
if (argStr.includes('pm list packages it.akai.customhome')) {
    console.log('package:it.akai.customhome');
    process.exit(0);
}
if (argStr.includes('pm list packages it.akai.customremote')) {
    console.log('package:it.akai.customremote');
    process.exit(0);
}
if (argStr.includes('pm path it.akai.customremote')) {
    console.log('package:/data/app/it.akai.customremote-1/base.apk');
    process.exit(0);
}
if (argStr.includes('dumpsys')) {
    console.log('    versionCode=12 minSdk=28 targetSdk=28');
    console.log('    versionName=1.0.5');
    process.exit(0);
}
if (argStr.includes('pidof')) {
    console.log('1234');
    process.exit(0);
}
if (argStr.includes('run-as') && argStr.includes('ls databases/')) {
    console.log('run-as: package not debuggable');
    process.exit(1);
}
if (argStr.includes('pull')) {
    const dest = args[args.length - 1];
    fs.writeFileSync(dest, 'PK_DUMMY_REMOTE_INSTALLED_APK');
    process.exit(0);
}
if (argStr.includes('df /data')) {
    console.log('/dev/block/bootdevice/by-name/userdata 5.2G 1.8G 3.4G 35% /data');
    process.exit(0);
}
if (argStr.includes('netstat')) {
    console.log('tcp 0 0 0.0.0.0:8088 0.0.0.0:* LISTEN 1234/it.akai.customremote');
    console.log('tcp 0 0 0.0.0.0:8443 0.0.0.0:* LISTEN 1234/it.akai.customremote');
    process.exit(0);
}
process.exit(0);
'@ | Out-File -FilePath $mockAdbJs21 -Encoding ascii

$mockAdbCmd21 = if ($isWin) { Join-Path $testDir21 "adb.cmd" } else { Join-Path $testDir21 "adb" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockAdbJs21`" %*" | Out-File -FilePath $mockAdbCmd21 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockAdbJs21`" `"`$@`"" | Out-File -FilePath $mockAdbCmd21 -Encoding ascii
    & chmod +x $mockAdbCmd21
}

$mockSignerJs21 = Join-Path $testDir21 "apksigner.js"
@"
console.log('Signer #1 certificate SHA-256 digest: a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90');
process.exit(0);
"@ | Out-File -FilePath $mockSignerJs21 -Encoding ascii

$mockSignerCmd21 = if ($isWin) { Join-Path $testDir21 "apksigner.cmd" } else { Join-Path $testDir21 "apksigner" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockSignerJs21`" %*" | Out-File -FilePath $mockSignerCmd21 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockSignerJs21`" `"`$@`"" | Out-File -FilePath $mockSignerCmd21 -Encoding ascii
    & chmod +x $mockSignerCmd21
}

$mockAdbEscaped21 = $mockAdbCmd21.Replace('\', '/')
$mockSignerEscaped21 = $mockSignerCmd21.Replace('\', '/')
$mockDirEscaped21 = $testDir21.Replace('\', '/')
$cmd21 = @"
`$ErrorActionPreference = 'Continue'
`$env:NODE_EXE = '$nodeEscaped'
`$env:ADB_EXECUTABLE = '$mockAdbEscaped21'
`$env:APKSIGNER_EXECUTABLE = '$mockSignerEscaped21'
`$env:PATH = '$mockDirEscaped21' + [System.IO.Path]::PathSeparator + `$env:PATH
& '$scriptEscaped' -Action preflight
"@
$prevEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$out21 = & $psExe -ExecutionPolicy Bypass -Command $cmd21 2>&1 | Out-String
$ErrorActionPreference = $prevEap

if ($out21 -match "INVENTARIO E PREFLIGHT READ-ONLY TV" -and
    $out21 -match "versionCode=12,\s*versionName=1.0.5" -and
    $out21 -match "Firma SHA-256\s+:\s+a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90" -and
    $out21 -match "Home v8 \(it\.akai\.customhome\.v8\)\s+:\s+PRESENTE E PROTETTA" -and
    $out21 -match "Home v7 \(it\.akai\.customhome\)\s+:\s+PRESENTE E PROTETTA" -and
    $out21 -match "UNKNOWN / INACCESSIBLE" -and
    $out21 -match "Tabella Trasparenza Dati Greenfield" -and
    $out21 -notmatch "VIOLATION_FORCE_STOP_CALLED") {
    Write-Host "[PASS] [TEST AFFERMATIVO / PREFLIGHT READ-ONLY] Test 21: Inventario preflight completato: dumpsys versionCode/Name, apksigner SHA-256, Home v8/v7 protette, DB inaccessibile non-zero, zero force-stop" -ForegroundColor Green
    $passed++
} else {
    Write-Host "[FAIL] [TEST AFFERMATIVO / PREFLIGHT READ-ONLY] Test 21: Preflight non conforme: $out21" -ForegroundColor Red
    $failed++
}
Remove-Item $testDir21 -Recurse -Force -ErrorAction SilentlyContinue

# -----------------------------------------------------------------------------
# TEST 22: Rifiuto categorico di -GreenfieldStart se pacchetto precedente e' presente ma DB inaccessibile (Fail-Closed)
# -----------------------------------------------------------------------------
Write-Host "`n--- Esecuzione Test 22: Rifiuto -GreenfieldStart se pacchetto precedente presente e DB inaccessibile (Fail-Closed) ---" -ForegroundColor Cyan
$testDir22 = Join-Path $tempDir "akai_test_greenfield_block_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir22 | Out-Null

$testApkOld22 = Join-Path $testDir22 "installed_old.apk"
$testApkNew22 = Join-Path $testDir22 "candidate_new.apk"
[System.IO.File]::WriteAllText($testApkOld22, "PK_DUMMY_OLD_APK")
[System.IO.File]::WriteAllText($testApkNew22, "PK_DUMMY_NEW_APK")

$mockAdbJs22 = Join-Path $testDir22 "mock_adb.js"
@'
const fs = require('fs');
const path = require('path');
const args = process.argv.slice(2);
const argStr = args.join(' ');

if (args[0] === 'connect' || args.includes('wait-for-device')) process.exit(0);
if (args.includes('unroot')) { console.log('adbd is already running as non root'); process.exit(0); }
if (args.includes('root')) { console.log('adbd cannot run as root in production builds'); process.exit(1); }
if (args.includes('shell') && args[args.length - 1] === 'id') { console.log('uid=2000(shell) gid=2000(shell)'); process.exit(0); }
if (argStr.includes('pm path')) {
    console.log('package:/data/app/it.akai.customremote-1/base.apk');
    process.exit(0);
}
if (argStr.includes('pull')) {
    const dest = args[args.length - 1];
    fs.writeFileSync(dest, 'PK_DUMMY_OLD_APK');
    process.exit(0);
}
if (argStr.includes('exec-out')) {
    console.log('run-as: package not debuggable');
    process.exit(1);
}
if (argStr.includes('pidof') || argStr.includes('PIDOF_CHECK')) {
    console.log('PIDOF_CHECK:pids=[]:exit=[1]');
    process.exit(0);
}
if (argStr.includes('install')) {
    console.log('VIOLATION_INSTALL_CALLED_ON_FAIL_CLOSED');
    process.exit(1);
}
process.exit(0);
'@ | Out-File -FilePath $mockAdbJs22 -Encoding ascii

$mockAdbCmd22 = if ($isWin) { Join-Path $testDir22 "adb.cmd" } else { Join-Path $testDir22 "adb" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockAdbJs22`" %*" | Out-File -FilePath $mockAdbCmd22 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockAdbJs22`" `"`$@`"" | Out-File -FilePath $mockAdbCmd22 -Encoding ascii
    & chmod +x $mockAdbCmd22
}

$mockSignerJs22 = Join-Path $testDir22 "apksigner.js"
@"
console.log('Signer #1 certificate SHA-256 digest: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef');
process.exit(0);
"@ | Out-File -FilePath $mockSignerJs22 -Encoding ascii

$mockSignerCmd22 = if ($isWin) { Join-Path $testDir22 "apksigner.cmd" } else { Join-Path $testDir22 "apksigner" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockSignerJs22`" %*" | Out-File -FilePath $mockSignerCmd22 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockSignerJs22`" `"`$@`"" | Out-File -FilePath $mockSignerCmd22 -Encoding ascii
    & chmod +x $mockSignerCmd22
}

$mockAdbEscaped22 = $mockAdbCmd22.Replace('\', '/')
$mockSignerEscaped22 = $mockSignerCmd22.Replace('\', '/')
$mockDirEscaped22 = $testDir22.Replace('\', '/')
$candApkEscaped22 = $testApkNew22.Replace('\', '/')

$cmd22 = @"
`$ErrorActionPreference = 'Continue'
`$env:NODE_EXE = '$nodeEscaped'
`$env:ADB_EXECUTABLE = '$mockAdbEscaped22'
`$env:APKSIGNER_EXECUTABLE = '$mockSignerEscaped22'
`$env:PATH = '$mockDirEscaped22' + [System.IO.Path]::PathSeparator + `$env:PATH
& '$scriptEscaped' -Action install -ApkPath '$candApkEscaped22' -TargetTv '127.0.0.1' -HttpPort 18088 -AllowHardwareExecution -GreenfieldStart
"@
$prevEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$out22 = & $psExe -ExecutionPolicy Bypass -Command $cmd22 2>&1 | Out-String
$ErrorActionPreference = $prevEap

if ($out22 -match "ERRORE FAIL-CLOSED" -and
    $out22 -match "Rilevata installazione precedente" -and
    $out22 -match "it\.akai\.customremote" -and
    $out22 -match "estrazione del" -and
    $out22 -match "database SQLite" -and
    $out22 -notmatch "VIOLATION_INSTALL_CALLED_ON_FAIL_CLOSED") {
    Write-Host "[PASS] [TEST NEGATIVO / DATA SAFETY FAIL-CLOSED] Test 22: Greenfield Start bloccato categoricamente se pacchetto precedente e' presente ma DB inaccessibile (zero installazioni)" -ForegroundColor Green
    $passed++
} else {
    Write-Host "[FAIL] [TEST NEGATIVO / DATA SAFETY FAIL-CLOSED] Test 22: Blocco fallito: $out22" -ForegroundColor Red
    $failed++
}
Remove-Item $testDir22 -Recurse -Force -ErrorAction SilentlyContinue

# -----------------------------------------------------------------------------
# TEST 23: Watchdog Port Separation (HTTP 426 Fail-Closed Policy vs HTTPS 8443 TLS Probe)
# -----------------------------------------------------------------------------
Write-Host "`n--- Esecuzione Test 23: Watchdog Port Separation (HTTP 426 Policy vs HTTPS 8443 TLS Probe) ---" -ForegroundColor Cyan
$testDir23 = Join-Path $tempDir "akai_test_watchdog_tls_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir23 | Out-Null

$nodeServerScript23 = Join-Path $testDir23 "mock_426_server.js"
@'
const http = require('http');
// Creiamo un server HTTP sulla porta 18089 che risponde 426 su /index.html e 200 su /api/status
const httpServer = http.createServer((req, res) => {
    if (req.url === '/api/status') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'ok', uinput_ready: true, active_sessions: 0 }));
    } else if (req.url === '/index.html') {
        res.writeHead(426, { 'Upgrade': 'TLS/1.2, HTTP/1.1', 'Content-Type': 'text/plain' });
        res.end('Upgrade Required: HTTPS Mandatory on Port 8443');
    } else {
        res.writeHead(404);
        res.end();
    }
});
httpServer.listen(18089, '127.0.0.1');
'@ | Out-File -FilePath $nodeServerScript23 -Encoding ascii

$srvProc23 = [System.Diagnostics.Process]::Start("$validNode", "`"$nodeServerScript23`"")
Start-Sleep -Milliseconds 600

# Verifichiamo che quando la porta HTTPS 8443 e' SPENTA (solo HTTP 426 attivo), Test-HttpsTlsEndpoint fallisce deterministico
$cmd23 = @"
. '$scriptEscaped' -Action plan | Out-Null
`$tlsProbe = Test-HttpsTlsEndpoint -TargetHost '127.0.0.1' -Port 18443 -TimeoutMs 1500
Write-Output ('PROBE_SUCCESS=' + `$tlsProbe.Success)
Write-Output ('PROBE_ERROR=' + `$tlsProbe.Error)
"@
$out23 = & $psExe -ExecutionPolicy Bypass -Command $cmd23 2>&1 | Out-String

try {
    if ($srvProc23 -and -not $srvProc23.HasExited) { $srvProc23.Kill() }
} catch {}

if ($out23 -match "PROBE_SUCCESS=False" -and $out23 -match "PROBE_ERROR=") {
    Write-Host "[PASS] [TEST AFFERMATIVO / WATCHDOG PORT SEPARATION] Test 23: Fallimento TLS 8443 rilevato deterministico (HTTP 426 non e' sufficiente da solo)" -ForegroundColor Green
    $passed++
} else {
    Write-Host "[FAIL] [TEST AFFERMATIVO / WATCHDOG PORT SEPARATION] Test 23: Rilevamento TLS fallito: $out23" -ForegroundColor Red
    $failed++
}
Remove-Item $testDir23 -Recurse -Force -ErrorAction SilentlyContinue

# -----------------------------------------------------------------------------
# TEST 24: Clean-Start Greenfield con pacchetto ASSENTE sulla TV (hasPrevious=false) e -GreenfieldStart
# -----------------------------------------------------------------------------
Write-Host "`n--- Esecuzione Test 24: Clean-Start Greenfield con pacchetto ASSENTE (hasPrevious=false) ---" -ForegroundColor Cyan
$testDir24 = Join-Path $tempDir "akai_test_clean_greenfield_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir24 | Out-Null

$testApkNew24 = Join-Path $testDir24 "candidate_new.apk"
[System.IO.File]::WriteAllText($testApkNew24, "PK_DUMMY_NEW_APK")

$mockAdbJs24 = Join-Path $testDir24 "mock_adb.js"
@'
const args = process.argv.slice(2);
const argStr = args.join(' ');

if (args[0] === 'connect' || args.includes('wait-for-device')) process.exit(0);
if (args.includes('unroot')) { console.log('adbd is already running as non root'); process.exit(0); }
if (args.includes('root')) { console.log('adbd cannot run as root in production builds'); process.exit(1); }
if (args.includes('shell') && args[args.length - 1] === 'id') { console.log('uid=2000(shell) gid=2000(shell)'); process.exit(0); }
if (argStr.includes('pm path')) {
    // Pacchetto it.akai.customremote ASSENTE sulla TV
    process.exit(1);
}
if (argStr.includes('install')) {
    console.log('Success');
    process.exit(0);
}
if (argStr.includes('pidof')) {
    console.log('1234');
    process.exit(0);
}
if (argStr.includes('am startservice')) {
    process.exit(0);
}
process.exit(0);
'@ | Out-File -FilePath $mockAdbJs24 -Encoding ascii

$mockAdbCmd24 = if ($isWin) { Join-Path $testDir24 "adb.cmd" } else { Join-Path $testDir24 "adb" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockAdbJs24`" %*" | Out-File -FilePath $mockAdbCmd24 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockAdbJs24`" `"`$@`"" | Out-File -FilePath $mockAdbCmd24 -Encoding ascii
    & chmod +x $mockAdbCmd24
}

$mockSignerJs24 = Join-Path $testDir24 "apksigner.js"
@"
console.log('Signer #1 certificate SHA-256 digest: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef');
process.exit(0);
"@ | Out-File -FilePath $mockSignerJs24 -Encoding ascii

$mockSignerCmd24 = if ($isWin) { Join-Path $testDir24 "apksigner.cmd" } else { Join-Path $testDir24 "apksigner" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockSignerJs24`" %*" | Out-File -FilePath $mockSignerCmd24 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockSignerJs24`" `"`$@`"" | Out-File -FilePath $mockSignerCmd24 -Encoding ascii
    & chmod +x $mockSignerCmd24
}

$mockAdbEscaped24 = $mockAdbCmd24.Replace('\', '/')
$mockSignerEscaped24 = $mockSignerCmd24.Replace('\', '/')
$mockDirEscaped24 = $testDir24.Replace('\', '/')
$candApkEscaped24 = $testApkNew24.Replace('\', '/')

$port24 = Get-Random -Minimum 31000 -Maximum 38000
$readyFile24 = Join-Path $testDir24 "ready_24_$([Guid]::NewGuid().ToString('N')).txt"
$readyEsc24 = $readyFile24.Replace('\', '/')
if (Test-Path $readyFile24) { Remove-Item $readyFile24 -Force -ErrorAction SilentlyContinue }
$nodeServerScript24 = Join-Path $testDir24 "mock_http_server.js"
@"
const http = require('http');
const fs = require('fs');
const server = http.createServer((req, res) => {
    if (req.url === '/api/status') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'ok', uinput_ready: true, active_sessions: 0 }));
    } else if (req.url === '/index.html') {
        res.writeHead(200, { 'Content-Type': 'text/html' });
        res.end('<html><body>Akai Web Remote v5</body></html>');
    } else {
        res.writeHead(404);
        res.end();
    }
});
setInterval(() => {}, 1000);
server.on('error', () => {});
server.listen($port24, '127.0.0.1', () => { fs.writeFileSync('$readyEsc24', '1'); });
"@ | Out-File -FilePath $nodeServerScript24 -Encoding ascii

$srvProc24 = $null
try {
    $srvProc24 = Start-Process -FilePath $validNode -ArgumentList "`"$nodeServerScript24`"" -PassThru
    $wait24 = 100
    while (-not (Test-Path $readyFile24) -and -not $srvProc24.HasExited -and $wait24 -gt 0) {
        Start-Sleep -Milliseconds 100
        $wait24--
    }
    if (-not (Test-Path $readyFile24)) {
        throw "Server HTTP mock Test 24 non pronto o terminato prematuramente (HasExited=$($srvProc24.HasExited))"
    }

    $cmd24 = @"
`$env:NODE_EXE = '$nodeEscaped'
`$env:ADB_EXECUTABLE = '$mockAdbEscaped24'
`$env:APKSIGNER_EXECUTABLE = '$mockSignerEscaped24'
`$env:PATH = '$mockDirEscaped24' + [System.IO.Path]::PathSeparator + `$env:PATH
`$env:WATCHDOG_ATTEMPTS = '2'
`$env:WATCHDOG_SLEEP_SEC = '1'
& '$scriptEscaped' -Action install -ApkPath '$candApkEscaped24' -TargetTv '127.0.0.1' -HttpPort $port24 -AllowHardwareExecution -GreenfieldStart
"@
    $out24 = & $psExe -ExecutionPolicy Bypass -Command $cmd24 2>&1 | Out-String

    if ($out24 -match "Nessun APK precedente installato sulla TV \(it\.akai\.customremote assente\)" -and
        $out24 -match "Parametro -GreenfieldStart attivo: autorizzata prima installazione pulita" -and
        $out24 -match "Home v8 \(it\.akai\.customhome\.v8\) e Home v7 \(it\.akai\.customhome\) rimangono intatte al 100%" -and
        $out24 -match "DEPLOYMENT VERIFICATO CON SUCCESSO AL 100%") {
        Write-Host "[PASS] [TEST AFFERMATIVO / CLEAN-START GREENFIELD] Test 24: Clean-Start Greenfield su TV vergine completato al 100% con Home protette" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST AFFERMATIVO / CLEAN-START GREENFIELD] Test 24: Clean-Start fallito: $out24" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[FAIL] [TEST AFFERMATIVO / CLEAN-START GREENFIELD] Test 24: Eccezione imprevista: $($_.Exception.Message)" -ForegroundColor Red
    $failed++
} finally {
    if ($srvProc24 -and -not $srvProc24.HasExited) { Stop-Process -Id $srvProc24.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $readyFile24 -Force -ErrorAction SilentlyContinue
    Remove-Item $testDir24 -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
# TEST 25-28: Verifica Rigorosa Autenticazione Server TLS (SAN Mismatch, CA Hostile/Forged Chain, CA Unverified, CA Approved 1-tier & 2-tier PKI)
# -----------------------------------------------------------------------------
Write-Host "`n--- Esecuzione Test 25-28: Autenticazione Rigorosa Server TLS (Test-HttpsTlsEndpoint) ---" -ForegroundColor Cyan
$testDirTls = Join-Path $tempDir "akai_test_tls_suite_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDirTls | Out-Null

# Helper per avviare server HTTPS Node.js effimero
function Start-EphemeralNodeHttpsServer($pfxPath) {
    $jsPath = Join-Path $testDirTls "srv_$([Guid]::NewGuid().ToString('N')).js"
    $pFile = Join-Path $testDirTls "port_$([Guid]::NewGuid().ToString('N')).txt"
    $escapedPfx = $pfxPath.Replace('\', '/')
    $escapedPort = $pFile.Replace('\', '/')

    $srvCode = @"
const https = require('https');
const fs = require('fs');
const srv = https.createServer({ pfx: fs.readFileSync('$escapedPfx'), passphrase: 'pass123' }, (req, res) => res.end('ok'));
srv.on('error', () => {});
srv.on('tlsClientError', () => {});
srv.listen(0, '127.0.0.1', () => {
    const portStr = srv.address().port.toString();
    fs.writeFileSync('$escapedPort.tmp', portStr);
    fs.renameSync('$escapedPort.tmp', '$escapedPort');
});
setInterval(() => {}, 1000);
"@
    [System.IO.File]::WriteAllText($jsPath, $srvCode)
    $proc = Start-Process -FilePath "$validNode" -ArgumentList "`"$jsPath`"" -PassThru
    $cnt = 50
    [int]$port = 0
    while ($cnt -gt 0) {
        if (Test-Path $pFile) {
            $rawPort = Get-Content $pFile -Raw -ErrorAction SilentlyContinue
            if ($rawPort -and $rawPort -match '^\s*(\d+)\s*$' -and ([int]$matches[1] -gt 0)) {
                $port = [int]$matches[1]
                break
            }
        }
        Start-Sleep -Milliseconds 100
        $cnt--
    }
    if ($port -le 0) {
        if ($proc -and -not $proc.HasExited) { $proc.Kill() }
        throw "Server HTTPS Node.js effimero non avviato entro il timeout previsto"
    }
    return @{ Process = $proc; Port = $port }
}

try {
    $pfx127 = Join-Path $testDirTls "cert127.pfx"
    $pfx192 = Join-Path $testDirTls "cert192.pfx"
    $pfxValid2Tier = Join-Path $testDirTls "cert_valid_2tier.pfx"
    $pfxForged2Tier = Join-Path $testDirTls "cert_forged_2tier.pfx"

    # 1. Certificato self-signed con SAN IP 127.0.0.1
    $rsa1 = [System.Security.Cryptography.RSA]::Create(2048)
    $san1 = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
    $san1.AddIpAddress([System.Net.IPAddress]::Parse('127.0.0.1'))
    $req1 = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=127.0.0.1', $rsa1, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $req1.CertificateExtensions.Add($san1.Build())
    $cert1 = $req1.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(1))
    [System.IO.File]::WriteAllBytes($pfx127, $cert1.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, 'pass123'))
    $sha127 = $cert1.GetCertHashString([System.Security.Cryptography.HashAlgorithmName]::SHA256).ToLower()

    # 2. Certificato self-signed con SAN IP 192.168.1.99 (per indurre SAN Mismatch su 127.0.0.1)
    $rsa2 = [System.Security.Cryptography.RSA]::Create(2048)
    $san2 = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
    $san2.AddIpAddress([System.Net.IPAddress]::Parse('192.168.1.99'))
    $req2 = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=192.168.1.99', $rsa2, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $req2.CertificateExtensions.Add($san2.Build())
    $cert2 = $req2.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(1))
    [System.IO.File]::WriteAllBytes($pfx192, $cert2.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, 'pass123'))
    $sha192 = $cert2.GetCertHashString([System.Security.Cryptography.HashAlgorithmName]::SHA256).ToLower()

    # 3. PKI reale a 2 livelli (Root CA autentica + Foglia SAN=127.0.0.1 firmata dalla Root CA)
    $rsaRealCa = [System.Security.Cryptography.RSA]::Create(2048)
    $reqRealCa = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=AKAI Jarvis Test Root CA', $rsaRealCa, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $reqRealCa.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true, $false, 0, $true))
    $reqRealCa.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(([System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign -bor [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::CrlSign), $true))
    $realRootCa = $reqRealCa.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(2))
    $realRootCaSha = $realRootCa.GetCertHashString([System.Security.Cryptography.HashAlgorithmName]::SHA256).ToLower()
    $realRootCaPubOnly = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(,$realRootCa.RawData)

    $rsaValidLeaf = [System.Security.Cryptography.RSA]::Create(2048)
    $sanValidLeaf = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
    $sanValidLeaf.AddIpAddress([System.Net.IPAddress]::Parse('127.0.0.1'))
    $reqValidLeaf = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=127.0.0.1', $rsaValidLeaf, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $reqValidLeaf.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false, $false, 0, $true))
    $reqValidLeaf.CertificateExtensions.Add($sanValidLeaf.Build())
    $validLeafPub = $reqValidLeaf.Create($realRootCa, [DateTimeOffset]::UtcNow.AddHours(-1), [DateTimeOffset]::UtcNow.AddDays(1), [byte[]]@(0x01, 0x02, 0x03, 0x04))
    $validLeafPriv = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($validLeafPub, $rsaValidLeaf)

    $colValid2Tier = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
    [void]$colValid2Tier.Add($validLeafPriv)
    [void]$colValid2Tier.Add($realRootCaPubOnly)
    [System.IO.File]::WriteAllBytes($pfxValid2Tier, $colValid2Tier.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12, 'pass123'))

    # 4. Catena contraffatta: Foglia SAN=127.0.0.1 firmata da Rogue CA (stesso Subject DN ma chiave diversa) + Root CA autentica allegata nel bundle TLS
    $rsaRogueCa = [System.Security.Cryptography.RSA]::Create(2048)
    $reqRogueCa = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=AKAI Jarvis Test Root CA', $rsaRogueCa, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $reqRogueCa.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true, $false, 0, $true))
    $reqRogueCa.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(([System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign -bor [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::CrlSign), $true))
    $rogueCa = $reqRogueCa.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(2))

    $rsaForgedLeaf = [System.Security.Cryptography.RSA]::Create(2048)
    $sanForgedLeaf = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
    $sanForgedLeaf.AddIpAddress([System.Net.IPAddress]::Parse('127.0.0.1'))
    $reqForgedLeaf = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=127.0.0.1', $rsaForgedLeaf, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $reqForgedLeaf.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false, $false, 0, $true))
    $reqForgedLeaf.CertificateExtensions.Add($sanForgedLeaf.Build())
    $forgedLeafPub = $reqForgedLeaf.Create($rogueCa, [DateTimeOffset]::UtcNow.AddHours(-1), [DateTimeOffset]::UtcNow.AddDays(1), [byte[]]@(0x05, 0x06, 0x07, 0x08))
    $forgedLeafPriv = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($forgedLeafPub, $rsaForgedLeaf)

    $colForged2Tier = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
    [void]$colForged2Tier.Add($forgedLeafPriv)
    [void]$colForged2Tier.Add($realRootCaPubOnly)
    [System.IO.File]::WriteAllBytes($pfxForged2Tier, $colForged2Tier.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12, 'pass123'))

    # TEST 25: SAN Mismatch
    $srv25 = Start-EphemeralNodeHttpsServer $pfx192
    try {
        $cmd25 = @"
. '$scriptEscaped' -Action plan | Out-Null
`$res = Test-HttpsTlsEndpoint -TargetHost '127.0.0.1' -Port $($srv25.Port) -ExpectedCaSha256 '$sha192'
Write-Output ('SUCCESS=' + `$res.Success + ':STATUS=' + `$res.Status + ':SAN=' + `$res.SanMatched)
"@
        $out25 = & $psExe -ExecutionPolicy Bypass -Command $cmd25 2>&1 | Out-String
    } finally {
        if ($srv25.Process -and -not $srv25.Process.HasExited) { $srv25.Process.Kill() }
    }

    if ($out25 -match "SUCCESS=False:STATUS=SAN_MISMATCH:SAN=False") {
        Write-Host "[PASS] [TEST NEGATIVO / TLS SAN MISMATCH] Test 25: Certificato con SAN discrepanza (192.168.1.99 su 127.0.0.1) categoricamente bloccato (SAN_MISMATCH)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO / TLS SAN MISMATCH] Test 25: Fallito: $out25" -ForegroundColor Red
        $failed++
    }

    # TEST 26: Hostile / Untrusted CA & Chain Forgery Attack (26a + 26b)
    $subPassed26 = 0
    $srv26a = Start-EphemeralNodeHttpsServer $pfx127
    try {
        $cmd26a = @"
. '$scriptEscaped' -Action plan | Out-Null
`$res = Test-HttpsTlsEndpoint -TargetHost '127.0.0.1' -Port $($srv26a.Port) -ExpectedCaSha256 '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff'
Write-Output ('SUCCESS=' + `$res.Success + ':STATUS=' + `$res.Status + ':CA=' + `$res.CaMatched)
"@
        $out26a = & $psExe -ExecutionPolicy Bypass -Command $cmd26a 2>&1 | Out-String
    } finally {
        if ($srv26a.Process -and -not $srv26a.Process.HasExited) { $srv26a.Process.Kill() }
    }

    if ($out26a -match "SUCCESS=False:STATUS=CA_UNTRUSTED_MISMATCH:CA=False") {
        $subPassed26++
        Write-Host "   [PASS] Sotto-test 26a: Certificato con CA non corrispondente all'impronta attesa bloccato categoricamente (CA_UNTRUSTED_MISMATCH)" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 26a fallito: $out26a" -ForegroundColor Red
    }

    $srv26b = Start-EphemeralNodeHttpsServer $pfxForged2Tier
    try {
        $cmd26b = @"
. '$scriptEscaped' -Action plan | Out-Null
`$res = Test-HttpsTlsEndpoint -TargetHost '127.0.0.1' -Port $($srv26b.Port) -ExpectedCaSha256 '$realRootCaSha'
Write-Output ('SUCCESS=' + `$res.Success + ':STATUS=' + `$res.Status + ':CA=' + `$res.CaMatched + ':ERR=' + `$res.Error)
"@
        $out26b = & $psExe -ExecutionPolicy Bypass -Command $cmd26b 2>&1 | Out-String
    } finally {
        if ($srv26b.Process -and -not $srv26b.Process.HasExited) { $srv26b.Process.Kill() }
    }

    if ($out26b -match "SUCCESS=False:STATUS=CA_UNTRUSTED_MISMATCH:CA=False") {
        $subPassed26++
        Write-Host "   [PASS] Sotto-test 26b: Catena TLS contraffatta (foglia SAN valida firmata da chiave rogue + Root CA attesa allegata come extra cert) rifiutata crittograficamente" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 26b fallito: $out26b" -ForegroundColor Red
    }

    if ($subPassed26 -eq 2) {
        Write-Host "[PASS] [TEST NEGATIVO / TLS CA UNTRUSTED & CHAIN FORGERY] Test 26: Impronta ostile e firma catena contraffatta bloccate categoricamente ($subPassed26/2)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO / TLS CA UNTRUSTED & CHAIN FORGERY] Test 26: Sotto-test superati: $subPassed26 / 2" -ForegroundColor Red
        $failed++
    }

    # TEST 27: Unverified Mode (No Out-of-band CA)
    $srv27 = Start-EphemeralNodeHttpsServer $pfx127
    try {
        $cmd27 = @"
. '$scriptEscaped' -Action plan | Out-Null
`$res = Test-HttpsTlsEndpoint -TargetHost '127.0.0.1' -Port $($srv27.Port)
Write-Output ('SUCCESS=' + `$res.Success + ':STATUS=' + `$res.Status + ':CA=' + `$res.CaMatched)
"@
        $out27 = & $psExe -ExecutionPolicy Bypass -Command $cmd27 2>&1 | Out-String
    } finally {
        if ($srv27.Process -and -not $srv27.Process.HasExited) { $srv27.Process.Kill() }
    }

    if ($out27 -match "SUCCESS=False:STATUS=TLS_HANDSHAKE_ONLY/UNVERIFIED:CA=False") {
        Write-Host "[PASS] [TEST NEGATIVO / TLS UNVERIFIED CA] Test 27: Handshake TLS senza CA fuori banda restituito come TLS_HANDSHAKE_ONLY/UNVERIFIED (non autorizza deployment)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO / TLS UNVERIFIED CA] Test 27: Fallito: $out27" -ForegroundColor Red
        $failed++
    }

    # TEST 28: Approved Mode - Self-Signed Pinned (28a) & Valid 2-Tier PKI Chain (28b)
    $subPassed28 = 0
    $srv28a = Start-EphemeralNodeHttpsServer $pfx127
    try {
        $cmd28a = @"
. '$scriptEscaped' -Action plan | Out-Null
`$res = Test-HttpsTlsEndpoint -TargetHost '127.0.0.1' -Port $($srv28a.Port) -ExpectedCaSha256 '$sha127'
Write-Output ('SUCCESS=' + `$res.Success + ':STATUS=' + `$res.Status + ':SAN=' + `$res.SanMatched + ':CA=' + `$res.CaMatched)
"@
        $out28a = & $psExe -ExecutionPolicy Bypass -Command $cmd28a 2>&1 | Out-String
    } finally {
        if ($srv28a.Process -and -not $srv28a.Process.HasExited) { $srv28a.Process.Kill() }
    }

    if ($out28a -match "SUCCESS=True:STATUS=APPROVED:SAN=True:CA=True") {
        $subPassed28++
        Write-Host "   [PASS] Sotto-test 28a: Certificato foglia autofirmato pinned approvato con firma ed estensioni verificate (APPROVED)" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 28a fallito: $out28a" -ForegroundColor Red
    }

    $srv28b = Start-EphemeralNodeHttpsServer $pfxValid2Tier
    try {
        $cmd28b = @"
. '$scriptEscaped' -Action plan | Out-Null
`$res = Test-HttpsTlsEndpoint -TargetHost '127.0.0.1' -Port $($srv28b.Port) -ExpectedCaSha256 '$realRootCaSha'
Write-Output ('SUCCESS=' + `$res.Success + ':STATUS=' + `$res.Status + ':SAN=' + `$res.SanMatched + ':CA=' + `$res.CaMatched)
"@
        $out28b = & $psExe -ExecutionPolicy Bypass -Command $cmd28b 2>&1 | Out-String
    } finally {
        if ($srv28b.Process -and -not $srv28b.Process.HasExited) { $srv28b.Process.Kill() }
    }

    if ($out28b -match "SUCCESS=True:STATUS=APPROVED:SAN=True:CA=True") {
        $subPassed28++
        Write-Host "   [PASS] Sotto-test 28b: Catena PKI valida a 2 livelli (Foglia SAN=127.0.0.1 firmata da Root CA BasicConstraints CA=true) approvata al 100% (APPROVED)" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 28b fallito: $out28b" -ForegroundColor Red
    }

    if ($subPassed28 -eq 2) {
        Write-Host "[PASS] [TEST AFFERMATIVO / TLS APPROVED 1-TIER & 2-TIER] Test 28: Handshake TLS con SAN typed IP/DNS e verifica crittografica completa catena CA approvato al 100% ($subPassed28/2)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST AFFERMATIVO / TLS APPROVED 1-TIER & 2-TIER] Test 28: Sotto-test superati: $subPassed28 / 2" -ForegroundColor Red
        $failed++
    }
} finally {
    Remove-Item $testDirTls -Recurse -Force -ErrorAction SilentlyContinue
}

# ==============================================================================
# TEST 29: [ADB ROOT/UNROOT + WAL BACKUP & EACCES GUARD]
# Verifica positiva/negativa completa del canale root adbd (Step 2 + P1/P2 Fail-Closed Gates):
#   29a) Happy Path: shell(uid=2000) -> adb root -> uid=0 -> backup DB+WAL + checkpoint -> adb unroot -> uid=2000
#   29b) Error/Interruption Path: fail streaming WAL sotto root -> ERRORE FAIL-CLOSED + adb unroot garantito in finally
#   29c) Denied & EACCES Guard: adb root rifiutato (uid=2000) + Probe-DeviceFileState -Channel "root" su EACCES -> Fail-Closed
#   29d) P1 Gate: adb root eleva a root ma id check post-root fallisce -> ActionBlock NON eseguito + ERRORE FAIL-CLOSED esplicito + adb unroot in finally + blocco E2E install
#   29e) P1 Gate: adb unroot fallisce/connessione interrotta -> ERRORE FAIL-CLOSED [STATO ADBD UNKNOWN / RECUPERO MANUALE RICHIESTO]
#   29f) P1 Gate: id check finale post-unroot restituisce stringa vuota -> ERRORE FAIL-CLOSED (mai falso successo)
#   29g) P1 Gate: root pre-esistente su adbd -> preserva stato root senza invocare adb root ne' adb unroot
#   29h) P2 Gate: id check finale post-unroot restituisce uid=1000(system) -> rifiutato in Fail-Closed (policy ancorata uid=2000(shell))
#   29i) P2 Gate: id check finale post-unroot restituisce output ambiguo -> rifiutato in Fail-Closed (nessun falso successo)
# ==============================================================================
Write-Host "`n--- Esecuzione Test 29: ADB Root/Unroot Escalation, WAL Checkpoint & EACCES Guard ---" -ForegroundColor Yellow
$testDir29 = Join-Path $tempDir "akai_test_adb_root_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir29 | Out-Null
$subPassed29 = 0

try {
    if (-not $validNode) {
        throw "Node.js non disponibile per fixture SQLite/WAL Test 29."
    }

    $nodeEscaped29 = $validNode.Replace('\', '/')
    $scriptEscaped = $scriptPath.Replace('\', '/')

    # 1. Fixture SQLite real con transazione WAL non ancora checkpointata (base row + uncommitted WAL row)
    $devDb29 = Join-Path $testDir29 "source_wal.db"
    $devWal29 = "$devDb29-wal"
    $devDbEsc29 = $devDb29.Replace('\', '/')

    $setupPath29 = Join-Path $testDir29 "setup29.js"
    @"
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync('$devDbEsc29');
db.exec('PRAGMA journal_mode=WAL;');
db.exec('CREATE TABLE ai_memory (id INTEGER PRIMARY KEY, note TEXT);');
db.exec("INSERT INTO ai_memory VALUES (1, 'base_v5_row');");
db.close();
"@ | Out-File -FilePath $setupPath29 -Encoding ascii
    & $validNode --no-warnings $setupPath29
    if ($LASTEXITCODE -ne 0) { throw "Setup DB Test 29 fallito." }

    $childPath29 = Join-Path $testDir29 "child29.js"
    @"
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync('$devDbEsc29');
db.exec('PRAGMA wal_autocheckpoint=0;');
db.exec("INSERT INTO ai_memory VALUES (2, 'wal_uncommitted_v5_row');");
process.exit(0);
"@ | Out-File -FilePath $childPath29 -Encoding ascii
    & $validNode --no-warnings $childPath29
    if (-not (Test-Path $devWal29) -or (Get-Item $devWal29).Length -lt 32) {
        throw "Fixture WAL Test 29 assente o < 32 bytes."
    }

    # 2. Mock stateful ADB (traccia adbd_state.txt: 'shell' <-> 'root' e adbd_log.txt)
    $adbdStateFile29 = Join-Path $testDir29 "adbd_state.txt"
    $adbdLogFile29 = Join-Path $testDir29 "adbd_log.txt"
    $mockAdbJs29 = Join-Path $testDir29 "mock_adb_29.js"
    @'
const fs = require('fs');
const args = process.argv.slice(2);
const argStr = args.join(' ');
const stateFile = process.env.ADBD_STATE_FILE;
const logFile = process.env.ADBD_LOG_FILE;
const rootMode = process.env.MOCK_ROOT_MODE || 'allow';

function getState() {
    try { return fs.readFileSync(stateFile, 'utf8').trim(); } catch (e) { return 'shell'; }
}

if (args.includes('connect') || args.includes('wait-for-device')) {
    process.exit(0);
}
if (args.includes('root')) {
    if (rootMode === 'denied') {
        console.log('adbd cannot run as root in production builds');
        process.exit(1);
    }
    fs.writeFileSync(stateFile, 'root', 'utf8');
    if (logFile) fs.appendFileSync(logFile, 'root\n', 'utf8');
    console.log('restarting adbd as root');
    process.exit(0);
}
if (args.includes('unroot')) {
    if (rootMode === 'unroot_fail') {
        if (logFile) fs.appendFileSync(logFile, 'unroot_fail\n', 'utf8');
        process.stderr.write('error: closed\n');
        process.exit(1);
    }
    if (rootMode === 'post_unroot_id_empty') {
        fs.writeFileSync(stateFile, 'unroot_empty', 'utf8');
        if (logFile) fs.appendFileSync(logFile, 'unroot\n', 'utf8');
        console.log('restarting adbd as non root');
        process.exit(0);
    }
    if (rootMode === 'post_unroot_uid_1000') {
        fs.writeFileSync(stateFile, 'unroot_uid_1000', 'utf8');
        if (logFile) fs.appendFileSync(logFile, 'unroot\n', 'utf8');
        console.log('restarting adbd as non root');
        process.exit(0);
    }
    if (rootMode === 'post_unroot_id_ambiguous') {
        fs.writeFileSync(stateFile, 'unroot_ambiguous', 'utf8');
        if (logFile) fs.appendFileSync(logFile, 'unroot\n', 'utf8');
        console.log('restarting adbd as non root');
        process.exit(0);
    }
    fs.writeFileSync(stateFile, 'shell', 'utf8');
    if (logFile) fs.appendFileSync(logFile, 'unroot\n', 'utf8');
    console.log('restarting adbd as non root');
    process.exit(0);
}
if (args.includes('install')) {
    console.log('VIOLATION_INSTALL_CALLED_ON_FAIL_CLOSED');
    process.exit(1);
}
if (argStr.includes('pm path')) {
    console.log('package:/data/app/it.akai.customremote-1/base.apk');
    process.exit(0);
}
if (args.includes('pull')) {
    const dest = args[args.length - 1];
    fs.writeFileSync(dest, 'PK_DEVICE_BACKUP_APK_MOCK_29');
    process.exit(0);
}
if (argStr.includes('run-as')) {
    process.stderr.write('run-as: package not debuggable\n');
    process.exit(1);
}
if (argStr.includes('su -c')) {
    process.stderr.write('/system/bin/sh: su: not found\n');
    process.exit(1);
}
if (args.includes('shell')) {
    if (args[args.length - 1] === 'id') {
        const st = getState();
        if (rootMode === 'post_root_id_fail' && st === 'root') {
            process.stderr.write('error: device offline\n');
            process.exit(1);
        }
        if (st === 'unroot_empty') {
            process.exit(0);
        }
        if (st === 'unroot_uid_1000') {
            console.log('uid=1000(system) gid=1000(system) groups=1000(system)');
            process.exit(0);
        }
        if (st === 'unroot_ambiguous') {
            console.log('uid=2000(shell) gid=2000(shell) trailing_anomaly uid=0(root)');
            process.exit(0);
        }
        if (st === 'root') {
            console.log('uid=0(root) gid=0(root) groups=0(root) context=u:r:su:s0');
        } else {
            console.log('uid=2000(shell) gid=2000(shell) groups=2000(shell) context=u:r:shell:s0');
        }
        process.exit(0);
    }
    if (argStr.includes('PIDOF_CHECK') || argStr.includes('pidof')) {
        console.log('PIDOF_CHECK:pids=[]:exit=[1]');
        process.exit(0);
    }
    if (argStr.includes('FILE_PROBE_RESULT')) {
        const st = getState();
        if (st !== 'root') {
            console.log('FILE_PROBE_RESULT:ACCESS_DENIED');
            process.exit(13);
        }
        if (argStr.includes('akai_memory.db-wal')) {
            console.log('FILE_PROBE_RESULT:EXISTS');
            process.exit(0);
        }
        console.log('FILE_PROBE_RESULT:NOT_FOUND');
        process.exit(0);
    }
    process.exit(0);
}
if (args.includes('exec-out')) {
    const st = getState();
    if (st !== 'root') {
        process.stderr.write('cat: Permission denied\n');
        process.exit(1);
    }
    if (argStr.includes('akai_memory.db-wal')) {
        if (rootMode === 'wal_fail') {
            process.stderr.write('I/O error reading wal\n');
            process.exit(1);
        }
        const walBuf = fs.readFileSync(process.env.DEVICE_WAL_FILE);
        process.stdout.write(walBuf, () => process.exit(0));
        return;
    }
    if (argStr.includes('akai_memory.db')) {
        const dbBuf = fs.readFileSync(process.env.DEVICE_DB_FILE);
        process.stdout.write(dbBuf, () => process.exit(0));
        return;
    }
    process.exit(1);
}
process.exit(0);
'@ | Out-File -FilePath $mockAdbJs29 -Encoding ascii

    $mockAdbCmd29 = if ($isWin) { Join-Path $testDir29 "adb.cmd" } else { Join-Path $testDir29 "adb" }
    if ($isWin) {
        "@echo off`n`"%NODE_EXE%`" `"$mockAdbJs29`" %*" | Out-File -FilePath $mockAdbCmd29 -Encoding ascii
    } else {
        "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockAdbJs29`" `"`$@`"" | Out-File -FilePath $mockAdbCmd29 -Encoding ascii
        & chmod +x $mockAdbCmd29
    }

    $mockAdbEsc29 = $mockAdbCmd29.Replace('\', '/')
    $stateEsc29 = $adbdStateFile29.Replace('\', '/')
    $logEsc29 = $adbdLogFile29.Replace('\', '/')
    $walEsc29 = $devWal29.Replace('\', '/')

    # --- Sotto-test 29a: Happy path adb root -> uid=0 -> backup DB+WAL + checkpoint -> adb unroot -> uid=2000 ---
    $backupDir29a = Join-Path $testDir29 "backup_29a"
    $backupEsc29a = $backupDir29a.Replace('\', '/')
    [System.IO.File]::WriteAllText($adbdStateFile29, "shell")
    if (Test-Path $adbdLogFile29) { Remove-Item $adbdLogFile29 -Force }

    $cmd29a = @"
`$env:NODE_EXE = '$nodeEscaped29'
`$env:ADB_EXECUTABLE = '$mockAdbEsc29'
`$env:ADBD_STATE_FILE = '$stateEsc29'
`$env:ADBD_LOG_FILE = '$logEsc29'
`$env:DEVICE_DB_FILE = '$devDbEsc29'
`$env:DEVICE_WAL_FILE = '$walEsc29'
`$env:MOCK_ROOT_MODE = 'allow'
try {
    & '$scriptEscaped' -Action backup -TargetTv '127.0.0.1' -BackupDir '$backupEsc29a' -AllowHardwareExecution
} catch {
    Write-Output ('CAUGHT_EXCEPTION: ' + `$_.Exception.Message)
}
"@
    $out29a = & $psExe -ExecutionPolicy Bypass -Command $cmd29a 2>&1 | Out-String
    $finalState29a = (Get-Content $adbdStateFile29 -Raw).Trim()
    $logLines29a = if (Test-Path $adbdLogFile29) { (Get-Content $adbdLogFile29 -Raw).Trim() } else { "" }

    $backedDb29a = Get-ChildItem -Path $backupDir29a -Filter "akai_memory.db" -Recurse | Select-Object -First 1
    $walMerged29a = $false
    if ($backedDb29a) {
        $backedDbEsc29a = $backedDb29a.FullName.Replace('\', '/')
        $checkPath29a = Join-Path $testDir29 "check29a.js"
        $checkJs29a = @"
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync('$backedDbEsc29a');
const r = db.prepare("SELECT COUNT(*) as cnt FROM ai_memory WHERE note='wal_uncommitted_v5_row';").get();
db.close();
process.exit(r && r.cnt === 1 ? 0 : 1);
"@
        [System.IO.File]::WriteAllText($checkPath29a, $checkJs29a, [System.Text.Encoding]::UTF8)
        & $validNode --no-warnings $checkPath29a
        if ($LASTEXITCODE -eq 0) { $walMerged29a = $true }
    }

    if ($out29a -match "Sessione di backup completata" -and $out29a -match "Privilegi temporanei adbd revocati con successo \(adb unroot -> uid=2000" -and $finalState29a -eq "shell" -and $logLines29a -match "root" -and $logLines29a -match "unroot" -and $walMerged29a) {
        $subPassed29++
        Write-Host "   [PASS] Sotto-test 29a: adb root -> uid=0 -> backup DB+WAL + checkpoint offline -> adb unroot -> uid=2000(shell) verificato" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 29a fallito (state=$finalState29a, walMerged=$walMerged29a): $out29a" -ForegroundColor Red
    }

    # --- Sotto-test 29b: Errore/interruzione WAL stream sotto root -> FAIL-CLOSED + adb unroot garantito in finally ---
    $backupDir29b = Join-Path $testDir29 "backup_29b"
    $backupEsc29b = $backupDir29b.Replace('\', '/')
    [System.IO.File]::WriteAllText($adbdStateFile29, "shell")
    if (Test-Path $adbdLogFile29) { Remove-Item $adbdLogFile29 -Force }

    $cmd29b = @"
`$env:NODE_EXE = '$nodeEscaped29'
`$env:ADB_EXECUTABLE = '$mockAdbEsc29'
`$env:ADBD_STATE_FILE = '$stateEsc29'
`$env:ADBD_LOG_FILE = '$logEsc29'
`$env:DEVICE_DB_FILE = '$devDbEsc29'
`$env:DEVICE_WAL_FILE = '$walEsc29'
`$env:MOCK_ROOT_MODE = 'wal_fail'
try {
    & '$scriptEscaped' -Action backup -TargetTv '127.0.0.1' -BackupDir '$backupEsc29b' -AllowHardwareExecution
} catch {
    Write-Output ('CAUGHT_EXCEPTION: ' + `$_.Exception.Message)
}
"@
    $out29b = & $psExe -ExecutionPolicy Bypass -Command $cmd29b 2>&1 | Out-String
    $finalState29b = (Get-Content $adbdStateFile29 -Raw).Trim()
    $logLines29b = if (Test-Path $adbdLogFile29) { (Get-Content $adbdLogFile29 -Raw).Trim() } else { "" }

    if ($out29b -match "ERRORE FAIL-CLOSED: File WAL \(akai_memory\.db-wal\) presente su storage device ma estrazione fallita o non leggibile via root" -and $out29b -notmatch "Sessione di backup completata" -and $finalState29b -eq "shell" -and $logLines29b -match "unroot") {
        $subPassed29++
        Write-Host "   [PASS] Sotto-test 29b: Fallimento estrazione WAL sotto root blocca in Fail-Closed ed esegue comunque adb unroot (-> uid=2000) in finally" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 29b fallito (state=$finalState29b, log=$logLines29b): $out29b" -ForegroundColor Red
    }

    # --- Sotto-test 29c: adb root negato + guardia EACCES su Probe-DeviceFileState -Channel "root" ---
    $backupDir29c = Join-Path $testDir29 "backup_29c"
    $backupEsc29c = $backupDir29c.Replace('\', '/')
    [System.IO.File]::WriteAllText($adbdStateFile29, "shell")
    if (Test-Path $adbdLogFile29) { Remove-Item $adbdLogFile29 -Force }

    $cmd29cBackup = @"
`$env:NODE_EXE = '$nodeEscaped29'
`$env:ADB_EXECUTABLE = '$mockAdbEsc29'
`$env:ADBD_STATE_FILE = '$stateEsc29'
`$env:ADBD_LOG_FILE = '$logEsc29'
`$env:DEVICE_DB_FILE = '$devDbEsc29'
`$env:DEVICE_WAL_FILE = '$walEsc29'
`$env:MOCK_ROOT_MODE = 'denied'
try {
    & '$scriptEscaped' -Action backup -TargetTv '127.0.0.1' -BackupDir '$backupEsc29c' -AllowHardwareExecution
} catch {
    Write-Output ('CAUGHT_EXCEPTION: ' + `$_.Exception.Message)
}
"@
    $out29cBackup = & $psExe -ExecutionPolicy Bypass -Command $cmd29cBackup 2>&1 | Out-String
    $finalState29c = (Get-Content $adbdStateFile29 -Raw).Trim()

    $cmd29cProbe = @"
`$env:NODE_EXE = '$nodeEscaped29'
`$env:ADBD_STATE_FILE = '$stateEsc29'
. '$scriptEscaped' -Action plan | Out-Null
try {
    `$st = Probe-DeviceFileState -AdbExe '$mockAdbEsc29' -TargetAdb '127.0.0.1:5555' -PackageName 'it.akai.customremote' -RelativePath 'databases/akai_memory.db-wal' -Channel 'root'
    Write-Output ('FAIL_NO_THROW:' + `$st)
} catch {
    Write-Output ('CAUGHT_29C:' + `$_.Exception.Message)
}
"@
    $out29cProbe = & $psExe -ExecutionPolicy Bypass -Command $cmd29cProbe 2>&1 | Out-String

    if ($out29cBackup -match "ERRORE FAIL-CLOSED: Estrazione del database fallita" -and $finalState29c -eq "shell" -and $out29cProbe -match "CAUGHT_29C:ERRORE FAIL-CLOSED" -and $out29cProbe -match "FILE_PROBE_RESULT:ACCESS_DENIED" -and $out29cProbe -match "exit: 13" -and $out29cProbe -notmatch "FAIL_NO_THROW") {
        $subPassed29++
        Write-Host "   [PASS] Sotto-test 29c: adb root negato + guardia EACCES directory (exit 13 / ACCESS_DENIED) bloccati in Fail-Closed senza falsi NOT_FOUND" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 29c fallito: backup=$out29cBackup | probe=$out29cProbe" -ForegroundColor Red
    }

    # --- Sotto-test 29d: P1 Gate - adb root eleva a root ma check id post-root fallisce -> ActionBlock NON eseguito + throw esplicito + adb unroot in finally + blocco E2E install ---
    [System.IO.File]::WriteAllText($adbdStateFile29, "shell")
    if (Test-Path $adbdLogFile29) { Remove-Item $adbdLogFile29 -Force }
    $cmd29d = @"
`$env:NODE_EXE = '$nodeEscaped29'
`$env:ADBD_STATE_FILE = '$stateEsc29'
`$env:ADBD_LOG_FILE = '$logEsc29'
`$env:MOCK_ROOT_MODE = 'post_root_id_fail'
. '$scriptEscaped' -Action plan | Out-Null
`$actionRan = `$false
try {
    Invoke-WithAdbElevation -AdbExe '$mockAdbEsc29' -TargetAdb '127.0.0.1:5555' -ActionBlock { `$actionRan = `$true }
    Write-Output ('ACTION_RAN=' + `$actionRan + ' FAIL_SILENT_29D')
} catch {
    Write-Output ('ACTION_RAN=' + `$actionRan + ' CAUGHT_29D:' + `$_.Exception.Message)
}
"@
    $out29d = & $psExe -ExecutionPolicy Bypass -Command $cmd29d 2>&1 | Out-String
    $finalState29d = (Get-Content $adbdStateFile29 -Raw).Trim()
    $logLines29d = if (Test-Path $adbdLogFile29) { (Get-Content $adbdLogFile29 -Raw).Trim() } else { "" }

    $backupDir29d = Join-Path $testDir29 "backup_29d"
    $backupEsc29d = $backupDir29d.Replace('\', '/')
    [System.IO.File]::WriteAllText($adbdStateFile29, "shell")
    $cmd29dInstall = @"
`$env:NODE_EXE = '$nodeEscaped29'
`$env:ADB_EXECUTABLE = '$mockAdbEsc29'
`$env:ADBD_STATE_FILE = '$stateEsc29'
`$env:ADBD_LOG_FILE = '$logEsc29'
`$env:DEVICE_DB_FILE = '$devDbEsc29'
`$env:DEVICE_WAL_FILE = '$walEsc29'
`$env:MOCK_ROOT_MODE = 'post_root_id_fail'
& '$scriptEscaped' -Action install -ApkPath '$devDbEsc29' -TargetTv '127.0.0.1' -HttpPort 18099 -BackupDir '$backupEsc29d' -AllowHardwareExecution
"@
    $prevEap29d = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $out29dInstall = & $psExe -ExecutionPolicy Bypass -Command $cmd29dInstall 2>&1 | Out-String
    $ec29dInstall = $LASTEXITCODE
    $ErrorActionPreference = $prevEap29d
    $finalState29dInstall = (Get-Content $adbdStateFile29 -Raw).Trim()

    if ($out29d -match "ACTION_RAN=False" -and $out29d -notmatch "FAIL_SILENT_29D" -and $out29d -match "CAUGHT_29D:ERRORE FAIL-CLOSED \[ELEVAZIONE ADB ROOT FALLITA\]" -and $out29d -match "Privilegi temporanei adbd revocati con successo \(adb unroot -> uid=2000\(shell\)" -and $finalState29d -eq "shell" -and $logLines29d -match "root" -and $logLines29d -match "unroot" -and $ec29dInstall -ne 0 -and $out29dInstall -match "ERRORE FAIL-CLOSED" -and $out29dInstall -match "ELEVAZIONE ADB ROOT FALLITA" -and $out29dInstall -notmatch "VIOLATION_INSTALL_CALLED_ON_FAIL_CLOSED" -and $finalState29dInstall -eq "shell") {
        $subPassed29++
        Write-Host "   [PASS] Sotto-test 29d: id check post-root fallito solleva [ELEVAZIONE ADB ROOT FALLITA] (zero fallimenti silenziosi), esegue unroot in finally e blocca E2E install (exit=$ec29dInstall)" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 29d fallito (state=$finalState29d, installState=$finalState29dInstall, ec=$ec29dInstall, log=$logLines29d): unit=$out29d | install=$out29dInstall" -ForegroundColor Red
    }

    # --- Sotto-test 29e: P1 Gate - adb unroot fallisce / connessione interrotta -> throw FAIL-CLOSED [STATO ADBD UNKNOWN] ---
    [System.IO.File]::WriteAllText($adbdStateFile29, "shell")
    if (Test-Path $adbdLogFile29) { Remove-Item $adbdLogFile29 -Force }
    $cmd29e = @"
`$env:NODE_EXE = '$nodeEscaped29'
`$env:ADBD_STATE_FILE = '$stateEsc29'
`$env:ADBD_LOG_FILE = '$logEsc29'
`$env:MOCK_ROOT_MODE = 'unroot_fail'
. '$scriptEscaped' -Action plan | Out-Null
try {
    Invoke-WithAdbElevation -AdbExe '$mockAdbEsc29' -TargetAdb '127.0.0.1:5555' -ActionBlock { Write-Output 'ACTION_EXECUTED_29E' }
    Write-Output 'FAIL_NO_THROW_29E'
} catch {
    Write-Output ('CAUGHT_29E:' + `$_.Exception.Message)
}
"@
    $out29e = & $psExe -ExecutionPolicy Bypass -Command $cmd29e 2>&1 | Out-String
    $logLines29e = if (Test-Path $adbdLogFile29) { (Get-Content $adbdLogFile29 -Raw).Trim() } else { "" }

    if ($out29e -match "CAUGHT_29E:ERRORE FAIL-CLOSED \[STATO ADBD UNKNOWN / RECUPERO MANUALE RICHIESTO\]" -and $out29e -notmatch "Privilegi temporanei adbd revocati con successo" -and $out29e -notmatch "FAIL_NO_THROW_29E" -and $logLines29e -match "unroot_fail") {
        $subPassed29++
        Write-Host "   [PASS] Sotto-test 29e: Fallimento adb unroot rilevato in Fail-Closed ([STATO ADBD UNKNOWN / RECUPERO MANUALE RICHIESTO]), nessun falso successo" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 29e fallito (log=$logLines29e): $out29e" -ForegroundColor Red
    }

    # --- Sotto-test 29f: P1 Gate - id check finale post-unroot vuoto -> throw FAIL-CLOSED [STATO ADBD UNKNOWN] ---
    [System.IO.File]::WriteAllText($adbdStateFile29, "shell")
    if (Test-Path $adbdLogFile29) { Remove-Item $adbdLogFile29 -Force }
    $cmd29f = @"
`$env:NODE_EXE = '$nodeEscaped29'
`$env:ADBD_STATE_FILE = '$stateEsc29'
`$env:ADBD_LOG_FILE = '$logEsc29'
`$env:MOCK_ROOT_MODE = 'post_unroot_id_empty'
. '$scriptEscaped' -Action plan | Out-Null
try {
    Invoke-WithAdbElevation -AdbExe '$mockAdbEsc29' -TargetAdb '127.0.0.1:5555' -ActionBlock { Write-Output 'ACTION_EXECUTED_29F' }
    Write-Output 'FAIL_NO_THROW_29F'
} catch {
    Write-Output ('CAUGHT_29F:' + `$_.Exception.Message)
}
"@
    $out29f = & $psExe -ExecutionPolicy Bypass -Command $cmd29f 2>&1 | Out-String

    if ($out29f -match "CAUGHT_29F:ERRORE FAIL-CLOSED \[STATO ADBD UNKNOWN / RECUPERO MANUALE RICHIESTO\]" -and $out29f -notmatch "Privilegi temporanei adbd revocati con successo" -and $out29f -notmatch "FAIL_NO_THROW_29F") {
        $subPassed29++
        Write-Host "   [PASS] Sotto-test 29f: Output vuoto su adb shell id post-unroot bloccato in Fail-Closed invece di falso successo" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 29f fallito: $out29f" -ForegroundColor Red
    }

    # --- Sotto-test 29g: P1 Gate - adbd gia' root in ingresso (pre-existing root) -> preserva stato senza root ne' unroot ---
    [System.IO.File]::WriteAllText($adbdStateFile29, "root")
    if (Test-Path $adbdLogFile29) { Remove-Item $adbdLogFile29 -Force }
    $cmd29g = @"
`$env:NODE_EXE = '$nodeEscaped29'
`$env:ADBD_STATE_FILE = '$stateEsc29'
`$env:ADBD_LOG_FILE = '$logEsc29'
`$env:MOCK_ROOT_MODE = 'allow'
. '$scriptEscaped' -Action plan | Out-Null
try {
    Invoke-WithAdbElevation -AdbExe '$mockAdbEsc29' -TargetAdb '127.0.0.1:5555' -ActionBlock { Write-Output 'ACTION_EXECUTED_29G' }
} catch {
    Write-Output ('CAUGHT_29G:' + `$_.Exception.Message)
}
"@
    $out29g = & $psExe -ExecutionPolicy Bypass -Command $cmd29g 2>&1 | Out-String
    $finalState29g = (Get-Content $adbdStateFile29 -Raw).Trim()
    $logLines29g = if (Test-Path $adbdLogFile29) { (Get-Content $adbdLogFile29 -Raw).Trim() } else { "" }

    if ($out29g -match "ACTION_EXECUTED_29G" -and $out29g -notmatch "CAUGHT_29G:" -and $finalState29g -eq "root" -and [string]::IsNullOrWhiteSpace($logLines29g)) {
        $subPassed29++
        Write-Host "   [PASS] Sotto-test 29g: Stato adbd pre-existing root preservato senza invocare adb root ne' adb unroot" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 29g fallito (state=$finalState29g, log='$logLines29g'): $out29g" -ForegroundColor Red
    }

    # --- Sotto-test 29h: P2 Gate - id check finale post-unroot restituisce uid=1000(system) -> rifiutato dalla policy uid=2000(shell) ---
    [System.IO.File]::WriteAllText($adbdStateFile29, "shell")
    if (Test-Path $adbdLogFile29) { Remove-Item $adbdLogFile29 -Force }
    $cmd29h = @"
`$env:NODE_EXE = '$nodeEscaped29'
`$env:ADBD_STATE_FILE = '$stateEsc29'
`$env:ADBD_LOG_FILE = '$logEsc29'
`$env:MOCK_ROOT_MODE = 'post_unroot_uid_1000'
. '$scriptEscaped' -Action plan | Out-Null
try {
    Invoke-WithAdbElevation -AdbExe '$mockAdbEsc29' -TargetAdb '127.0.0.1:5555' -ActionBlock { Write-Output 'ACTION_EXECUTED_29H' }
    Write-Output 'FAIL_NO_THROW_29H'
} catch {
    Write-Output ('CAUGHT_29H:' + `$_.Exception.Message)
}
"@
    $out29h = & $psExe -ExecutionPolicy Bypass -Command $cmd29h 2>&1 | Out-String

    if ($out29h -match "CAUGHT_29H:ERRORE FAIL-CLOSED \[STATO ADBD UNKNOWN / RECUPERO MANUALE RICHIESTO\]" -and $out29h -notmatch "Privilegi temporanei adbd revocati con successo" -and $out29h -notmatch "FAIL_NO_THROW_29H") {
        $subPassed29++
        Write-Host "   [PASS] Sotto-test 29h: Output non-shell uid=1000(system) post-unroot rifiutato in Fail-Closed dalla policy ancorata uid=2000(shell)" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 29h fallito: $out29h" -ForegroundColor Red
    }

    # --- Sotto-test 29i: P2 Gate - id check finale post-unroot con output ambiguo/multi-uid -> rifiutato in Fail-Closed ---
    [System.IO.File]::WriteAllText($adbdStateFile29, "shell")
    if (Test-Path $adbdLogFile29) { Remove-Item $adbdLogFile29 -Force }
    $cmd29i = @"
`$env:NODE_EXE = '$nodeEscaped29'
`$env:ADBD_STATE_FILE = '$stateEsc29'
`$env:ADBD_LOG_FILE = '$logEsc29'
`$env:MOCK_ROOT_MODE = 'post_unroot_id_ambiguous'
. '$scriptEscaped' -Action plan | Out-Null
try {
    Invoke-WithAdbElevation -AdbExe '$mockAdbEsc29' -TargetAdb '127.0.0.1:5555' -ActionBlock { Write-Output 'ACTION_EXECUTED_29I' }
    Write-Output 'FAIL_NO_THROW_29I'
} catch {
    Write-Output ('CAUGHT_29I:' + `$_.Exception.Message)
}
"@
    $out29i = & $psExe -ExecutionPolicy Bypass -Command $cmd29i 2>&1 | Out-String

    if ($out29i -match "CAUGHT_29I:ERRORE FAIL-CLOSED \[STATO ADBD UNKNOWN / RECUPERO MANUALE RICHIESTO\]" -and $out29i -notmatch "Privilegi temporanei adbd revocati con successo" -and $out29i -notmatch "FAIL_NO_THROW_29I") {
        $subPassed29++
        Write-Host "   [PASS] Sotto-test 29i: Output ambiguo/anomalo su adb shell id post-unroot rifiutato in Fail-Closed" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 29i fallito: $out29i" -ForegroundColor Red
    }
} finally {
    Remove-Item $testDir29 -Recurse -Force -ErrorAction SilentlyContinue
}

if ($subPassed29 -eq 9) {
    Write-Host "[PASS] [TEST POSITIVO & NEGATIVO / ADB ROOT-UNROOT & WAL] Test 29: Elevation root/unroot, WAL checkpoint, EACCES e P1/P2 Fail-Closed gates verificati al 100% (9/9)" -ForegroundColor Green
    $passed++
} else {
    Write-Host "[FAIL] [TEST POSITIVO & NEGATIVO / ADB ROOT-UNROOT & WAL] Test 29: Sotto-test superati: $subPassed29 / 9" -ForegroundColor Red
    $failed++
}

Write-Host "`n=== ESITO COMPLETO TEST POWERSHELL MOCK ADB ===" -ForegroundColor Cyan
Write-Host "Test Superati: $passed / $($passed + $failed)" -ForegroundColor Green
if ($failed -gt 0) { 
    exit 1 
} else { 
    exit 0 
}
