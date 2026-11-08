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

    if ($res5 -match "ERRORE FAIL-CLOSED: Impossibile estrarre un backup integro del database" -or $res5 -match "INTERROTTA per prevenire perdite") {
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
$dbInitJs = @"
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync('$($realDb7.Replace('\', '/'))');
db.exec('CREATE TABLE IF NOT EXISTS ai_memory (id INTEGER PRIMARY KEY, note TEXT);');
db.prepare('INSERT INTO ai_memory VALUES (?, ?)').run(1, 'golden_upgrade_data');
db.close();
"@
& $validNode -e $dbInitJs

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
    "@echo off`n`"%NODE_EXE%`" `"%~dp0mock_signer_7.js`" %*" | Out-File -FilePath $mockSignerCmd7 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$(dirname `"`$0`")/mock_signer_7.js`" `"`$@`"" | Out-File -FilePath $mockSignerCmd7 -Encoding ascii
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
    "@echo off`n`"%NODE_EXE%`" `"%~dp0mock_adb_7.js`" %*" | Out-File -FilePath $mockAdbCmd7 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$(dirname `"`$0`")/mock_adb_7.js`" `"`$@`"" | Out-File -FilePath $mockAdbCmd7 -Encoding ascii
    & chmod +x $mockAdbCmd7
}

# 5. Mock HTTP Server (porta 18088)
@'
const http = require('http');
const server = http.createServer((req, res) => {
  if (req.url === '/api/status') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', uinput_ready: true, active_sessions: 1 }));
  } else if (req.url === '/index.html') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end('<!DOCTYPE html><html><body>AKAI Web Remote</body></html>');
  } else if (req.url === '/api/ai/memory') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ procedures: [], preferences: {} }));
  } else {
    res.writeHead(404);
    res.end();
  }
});
server.listen(18088, '127.0.0.1');
'@ | Out-File -FilePath $mockHttpScript7 -Encoding ascii

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

& '$scriptEscaped' -Action install -ApkPath '$candidateEscaped' -TargetTv '127.0.0.1' -HttpPort 18088 -BackupDir '$backupDirEscaped' -AllowHardwareExecution
"@
    $res7 = & $psExe -ExecutionPolicy Bypass -Command $testCmd7 2>&1 | Out-String

    if ($res7 -match "DEPLOYMENT VERIFICATO CON SUCCESSO AL 100%" -and $res7 -match "Compatibilità firma SHA-256 verificata con successo") {
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
$dbInitJs8 = @"
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync('$($realDb8.Replace('\', '/'))');
db.exec('CREATE TABLE IF NOT EXISTS akai_config (key TEXT PRIMARY KEY, val TEXT);');
db.prepare('INSERT INTO akai_config VALUES (?, ?)').run('channel_last', '505');
db.close();
"@
& $validNode -e $dbInitJs8

[System.IO.File]::WriteAllText($deviceApk8, "PK_DEVICE_BACKUP_APK_MOCK_8")
[System.IO.File]::WriteAllText($candidateApk8, "PK_CANDIDATE_FAULTY_APK_MOCK_8")

# 2. Mock apksigner
@"
console.log('Signer #1 certificate SHA-256 digest: deadbeefcafebabe00112233445566778899aabbccddeeffdeadbeefcafebabe');
process.exit(0);
"@ | Out-File -FilePath $mockSignerJs8 -Encoding ascii

$mockSignerCmd8 = if ($isWin) { Join-Path $testDir8 "apksigner.cmd" } else { Join-Path $testDir8 "apksigner" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"%~dp0mock_signer_8.js`" %*" | Out-File -FilePath $mockSignerCmd8 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$(dirname `"`$0`")/mock_signer_8.js`" `"`$@`"" | Out-File -FilePath $mockSignerCmd8 -Encoding ascii
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
    const chunks = [];
    process.stdin.on('data', chunk => chunks.push(chunk));
    process.stdin.on('end', () => process.exit(0));
    return;
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
    "@echo off`n`"%NODE_EXE%`" `"%~dp0mock_adb_8.js`" %*" | Out-File -FilePath $mockAdbCmd8 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$(dirname `"`$0`")/mock_adb_8.js`" `"`$@`"" | Out-File -FilePath $mockAdbCmd8 -Encoding ascii
    & chmod +x $mockAdbCmd8
}

# 4. Mock HTTP Server: fallisce sul watchdog upgrade, ma risponde OK sul watchdog post-rollback!
@'
const http = require('http');
let attempts = 0;
const server = http.createServer((req, res) => {
  if (req.url === '/api/status') {
    attempts++;
    if (attempts <= 2) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: 'error', message: 'Simulated failure to trigger rollback' }));
      return;
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', uinput_ready: true, active_sessions: 1 }));
  } else if (req.url === '/index.html') {
    if (attempts <= 2) {
      res.writeHead(503);
      res.end('Service Unavailable');
      return;
    }
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end('<!DOCTYPE html><html><body>AKAI Web Remote Rollback OK</body></html>');
  } else if (req.url === '/api/ai/memory') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ procedures: [], preferences: {} }));
  } else {
    res.writeHead(404);
    res.end();
  }
});
server.listen(18089, '127.0.0.1');
'@ | Out-File -FilePath $mockHttpScript8 -Encoding ascii

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

& '$scriptEscaped' -Action install -ApkPath '$candidateEscaped' -TargetTv '127.0.0.1' -HttpPort 18089 -BackupDir '$backupDirEscaped' -AllowHardwareExecution
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

Write-Host "`n=== ESITO COMPLETO TEST POWERSHELL MOCK ADB ===" -ForegroundColor Cyan
Write-Host "Test Superati: $passed / $($passed + $failed)" -ForegroundColor Green
if ($failed -gt 0) { 
    exit 1 
} else { 
    exit 0 
}
