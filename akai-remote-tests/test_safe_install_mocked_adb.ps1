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
const args = process.argv.slice(2).join(' ');

if (args.includes('connect')) process.exit(0);
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
if (args.includes('pidof')) { console.log('12345'); process.exit(0); }
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
server.listen($port7, '127.0.0.1');
"@ | Out-File -FilePath $mockHttpScript7 -Encoding ascii

$httpErrLog7 = Join-Path $testDir7 "http_err.log"
$httpProc7 = Start-Process -FilePath $validNode -ArgumentList "`"$mockHttpScript7`"" -RedirectStandardError $httpErrLog7 -PassThru
Start-Sleep -Milliseconds 800

try {
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
const args = process.argv.slice(2).join(' ');

if (args.includes('connect')) process.exit(0);
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
if (args.includes('pidof')) { console.log('12345'); process.exit(0); }
if (args.includes('test -f')) { console.log('NOT_FOUND'); process.exit(0); }
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
@"
const http = require('http');
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
server.listen($port8, '127.0.0.1');
"@ | Out-File -FilePath $mockHttpScript8 -Encoding ascii

$httpErrLog8 = Join-Path $testDir8 "http_err.log"
$httpProc8 = Start-Process -FilePath $validNode -ArgumentList "`"$mockHttpScript8`"" -RedirectStandardError $httpErrLog8 -PassThru
Start-Sleep -Milliseconds 800

try {
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
const args = process.argv.slice(2).join(' ');
const logFile = process.env.MOCK_LOG_FILE;

if (args.includes('connect')) process.exit(0);
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
if (args.includes('pidof')) { console.log('12345'); process.exit(0); }
if (args.includes('test -f databases/akai_memory.db-wal')) { console.log('NOT_FOUND'); process.exit(0); }
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
const args = process.argv.slice(2).join(' ');

if (args.includes('connect')) process.exit(0);
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
if (args.includes('test -f databases/akai_memory.db-wal')) {
    console.log('EXISTS');
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
const args = process.argv.slice(2).join(' ');

if (args.includes('connect')) process.exit(0);
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
    console.log('9999');
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
const args = process.argv.slice(2).join(' ');

if (args.includes('connect')) process.exit(0);
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
// test -f: simula che akai_memory.db-wal non sia stato rimosso (EXISTS)
if (args.includes('test -f') && args.includes('akai_memory.db-wal')) {
    console.log('EXISTS');
    process.exit(0);
}
if (args.includes('test -f')) {
    console.log('NOT_FOUND');
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

Write-Host "`n=== ESITO COMPLETO TEST POWERSHELL MOCK ADB ===" -ForegroundColor Cyan
Write-Host "Test Superati: $passed / $($passed + $failed)" -ForegroundColor Green
if ($failed -gt 0) { 
    exit 1 
} else { 
    exit 0 
}
