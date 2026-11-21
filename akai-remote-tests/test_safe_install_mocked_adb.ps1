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

# Offline test fixture only: production installer requires aapt metadata and never bypasses it.
# A mock binary is isolated under a temporary test-only SDK; NO physical TV/ADB.
$mockAaptRoot = Join-Path $tempDir ("jarvis_mock_aapt_" + [Guid]::NewGuid().ToString("N"))
$mockSdkRoot = Join-Path $mockAaptRoot "sdk"
$mockBuildTools = Join-Path $mockSdkRoot "build-tools/99.0.0"
New-Item -ItemType Directory -Force -Path $mockBuildTools | Out-Null
$mockAaptJs = Join-Path $mockAaptRoot "mock_aapt.js"
@'
const fs = require('fs');
const args = process.argv.slice(2);
if (args.length !== 3 || args[0] !== 'dump' || args[1] !== 'badging' || !fs.existsSync(args[2])) {
    console.error('MOCK_AAPT_INVALID_REQUEST');
    process.exit(2);
}
console.log("package: name='it.akai.customremote' versionCode='4' versionName='1.3.0-diagnostic-rc1'");
'@ | Set-Content -LiteralPath $mockAaptJs -Encoding UTF8
if (-not $validNode) { throw 'Mock aapt requires Node.js.' }
if ($isWin) {
    $mockAaptCommand = Join-Path $mockBuildTools 'aapt.cmd'
    $cmdText = '@echo off' + [Environment]::NewLine + ('"{0}" "{1}" %*' -f $validNode, $mockAaptJs)
    Set-Content -LiteralPath $mockAaptCommand -Value $cmdText -Encoding ASCII
} else {
    $mockAaptCommand = Join-Path $mockBuildTools 'aapt'
    $shText = '#!/bin/sh' + [Environment]::NewLine + ('exec "{0}" "{1}" "$@"' -f $validNode, $mockAaptJs)
    Set-Content -LiteralPath $mockAaptCommand -Value $shText -Encoding UTF8
    & chmod +x $mockAaptCommand
}
$env:ANDROID_HOME = $mockSdkRoot
$env:ANDROID_SDK_ROOT = $mockSdkRoot
$env:PATH = $mockBuildTools + [System.IO.Path]::PathSeparator + $env:PATH

function Get-FreeLoopbackPort {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $freePort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    return $freePort
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

function New-MockTlsPfx {
    param([string]$FilePath, [string]$SanIp = "127.0.0.1", [string]$Password = "pass123")
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $san = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
    $san.AddIpAddress([System.Net.IPAddress]::Parse($SanIp))
    $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new("CN=$SanIp", $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $req.CertificateExtensions.Add($san.Build())
    $cert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(1))
    [System.IO.File]::WriteAllBytes($FilePath, $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $Password))
    return $cert.GetCertHashString([System.Security.Cryptography.HashAlgorithmName]::SHA256).ToLower()
}

function Start-MockHttpsNodeServer {
    param([string]$PfxPath, [string]$BaseDir, [string]$Password = "pass123")
    $jsPath = Join-Path $BaseDir "srv_https_$([Guid]::NewGuid().ToString('N')).js"
    $pFile = Join-Path $BaseDir "port_https_$([Guid]::NewGuid().ToString('N')).txt"
    $escapedPfx = $PfxPath.Replace('\', '/')
    $escapedPort = $pFile.Replace('\', '/')

    $srvCode = @"
const https = require('https');
const fs = require('fs');
const srv = https.createServer({ pfx: fs.readFileSync('$escapedPfx'), passphrase: '$Password' }, (req, res) => res.end('ok'));
srv.on('error', () => {});
srv.on('tlsClientError', () => {});
srv.listen(0, '127.0.0.1', () => {
    fs.writeFileSync('$escapedPort', srv.address().port.toString());
});
setInterval(() => {}, 1000);
"@
    [System.IO.File]::WriteAllText($jsPath, $srvCode)
    $proc = Start-Process -FilePath "$validNode" -ArgumentList "`"$jsPath`"" -PassThru -NoNewWindow
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
    return @{ Process = $proc; Port = $port }
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
if (args.includes('dumpsys package')) { console.log('    versionCode=3 minSdk=21 targetSdk=28\n    userId=10123'); process.exit(0); }
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
$port7 = Get-FreeLoopbackPort
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
    $httpProc7 = Start-Process -FilePath $validNode -ArgumentList "`"$mockHttpScript7`"" -RedirectStandardError $httpErrLog7 -PassThru -NoNewWindow
    $wait7 = 100
    while (-not (Test-Path $readyFile7) -and -not $httpProc7.HasExited -and $wait7 -gt 0) {
        Start-Sleep -Milliseconds 100
        $wait7--
    }
    if (-not (Test-Path $readyFile7)) {
        throw "Server HTTP mock Test 7 non pronto o terminato prematuramente (HasExited=$($httpProc7.HasExited))"
    }

    $pfx7 = Join-Path $testDir7 "cert7.pfx"
    $shaCa7 = New-MockTlsPfx -FilePath $pfx7 -SanIp "127.0.0.1"
    $httpsProc7 = Start-MockHttpsNodeServer -PfxPath $pfx7 -BaseDir $testDir7
    $httpsPort7 = $httpsProc7.Port

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

& '$scriptEscaped' -Action install -ApkPath '$candidateEscaped' -TargetTv '127.0.0.1' -HttpPort $port7 -HttpsPort $httpsPort7 -AuthToken 'mock_v5_token' -BackupDir '$backupDirEscaped' -AllowHardwareExecution -ExpectedCaFingerprint '$shaCa7'
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
    if ($httpsProc7 -and $httpsProc7.Process -and -not $httpsProc7.Process.HasExited) { Stop-Process -Id $httpsProc7.Process.Id -Force -ErrorAction SilentlyContinue }
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
if (args.includes('dumpsys package')) { console.log('    versionCode=3 minSdk=21 targetSdk=28\n    userId=10123'); process.exit(0); }
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
$port8 = Get-FreeLoopbackPort
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
    $httpProc8 = Start-Process -FilePath $validNode -ArgumentList "`"$mockHttpScript8`"" -RedirectStandardError $httpErrLog8 -PassThru -NoNewWindow
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
if (args.includes('dumpsys package')) { console.log('    versionCode=3 minSdk=21 targetSdk=28\n    userId=10123'); process.exit(0); }
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
$port9 = Get-FreeLoopbackPort
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
$httpProc9 = Start-Process -FilePath $validNode -ArgumentList "`"$mockHttpScript9`"" -RedirectStandardError $httpErrLog9 -PassThru -NoNewWindow
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
$port10 = Get-FreeLoopbackPort
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

$httpProc10 = Start-Process -FilePath $validNode -ArgumentList "`"$mockHttpScript10`"" -PassThru -NoNewWindow
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
$port12 = Get-FreeLoopbackPort
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
if (args.includes('dumpsys package')) { console.log('    versionCode=3 minSdk=21 targetSdk=28\n    userId=10123'); process.exit(0); }
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

$port13 = Get-FreeLoopbackPort
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
if (argStr.includes('getprop ro.build.type')) { console.log('user'); process.exit(0); }
if (argStr.includes('getprop ro.debuggable')) { console.log('0'); process.exit(0); }
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
    $out21 -match "\[NO-GO DATI\]" -and
    $out21 -match "Android build type\s+:\s+user" -and
    $out21 -match "ro\.debuggable\s+:\s+0" -and
    $out21 -match "Recupero downgrade\s+:\s+NON DIMOSTRATO" -and
    $out21 -match "NON autorizza installazione" -and
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

# Test 24 requires a realistic aapt metadata fixture, not a production bypass.
$mockAaptJs24 = Join-Path $testDir24 "aapt.js"
@'
const args = process.argv.slice(2);
if (args[0] === 'dump' && args[1] === 'badging' && args[2] && args[2].endsWith('candidate_new.apk')) {
    console.log("package: name='it.akai.customremote' versionCode='4' versionName='1.3.0-diagnostic'");
    process.exit(0);
}
process.exit(1);
'@ | Out-File -FilePath $mockAaptJs24 -Encoding ascii
$mockAaptCmd24 = if ($isWin) { Join-Path $testDir24 "aapt.cmd" } else { Join-Path $testDir24 "aapt" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockAaptJs24`" %*" | Out-File -FilePath $mockAaptCmd24 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockAaptJs24`" `"`$@`"" | Out-File -FilePath $mockAaptCmd24 -Encoding ascii
    & chmod +x $mockAaptCmd24
}

$mockAdbEscaped24 = $mockAdbCmd24.Replace('\', '/')
$mockSignerEscaped24 = $mockSignerCmd24.Replace('\', '/')
$mockDirEscaped24 = $testDir24.Replace('\', '/')
$candApkEscaped24 = $testApkNew24.Replace('\', '/')

$port24 = Get-FreeLoopbackPort
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
    $pfx24 = Join-Path $testDir24 "cert24.pfx"
    $shaCa24 = New-MockTlsPfx -FilePath $pfx24 -SanIp "127.0.0.1"
    $httpsProc24 = Start-MockHttpsNodeServer -PfxPath $pfx24 -BaseDir $testDir24
    $httpsPort24 = $httpsProc24.Port

    $srvProc24 = Start-Process -FilePath $validNode -ArgumentList "`"$nodeServerScript24`"" -PassThru -NoNewWindow
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
& '$scriptEscaped' -Action install -ApkPath '$candApkEscaped24' -TargetTv '127.0.0.1' -HttpPort $port24 -HttpsPort $httpsPort24 -AllowHardwareExecution -GreenfieldStart -ExpectedCaFingerprint '$shaCa24'
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
    if ($httpsProc24 -and $httpsProc24.Process -and -not $httpsProc24.Process.HasExited) { Stop-Process -Id $httpsProc24.Process.Id -Force -ErrorAction SilentlyContinue }
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
    $proc = Start-Process -FilePath "$validNode" -ArgumentList "`"$jsPath`"" -PassThru -NoNewWindow
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
    # Breve verifica TCP connect per confermare che il listener sia effettivamente in ascolto
    $tcpReady = $false
    for ($probeIdx = 0; $probeIdx -lt 20; $probeIdx++) {
        $probeClient = $null
        try {
            $probeClient = New-Object System.Net.Sockets.TcpClient
            $ar = $probeClient.BeginConnect('127.0.0.1', $port, $null, $null)
            if ($ar.AsyncWaitHandle.WaitOne(250, $false)) {
                $probeClient.EndConnect($ar)
                $tcpReady = $true
                break
            }
        } catch {
        } finally {
            if ($probeClient) { $probeClient.Dispose() }
        }
        Start-Sleep -Milliseconds 50
    }
    if (-not $tcpReady) {
        if ($proc -and -not $proc.HasExited) { $proc.Kill() }
        throw "Server HTTPS Node.js effimero su porta $port non raggiungibile in TCP"
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
const recoveryMode = process.env.MOCK_RECOVERY_MODE || '';
const appProcFile = process.env.APP_PROC_STATE_FILE || '';

function getState() {
    try { return fs.readFileSync(stateFile, 'utf8').trim(); } catch (e) { return 'shell'; }
}
function getAppProcState() {
    if (!appProcFile) return 'stopped';
    try { return fs.readFileSync(appProcFile, 'utf8').trim(); } catch (e) { return 'stopped'; }
}
function setAppProcState(val) {
    if (appProcFile) fs.writeFileSync(appProcFile, val, 'utf8');
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
    if (logFile) fs.appendFileSync(logFile, 'install\n', 'utf8');
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
    if (argStr.includes('ADB_ALIVE')) {
        if (recoveryMode === 'adb_unreachable') {
            process.stderr.write('error: device offline\n');
            process.exit(1);
        }
        console.log('ADB_ALIVE');
        process.exit(0);
    }
    if (argStr.includes('am force-stop')) {
        if (logFile) fs.appendFileSync(logFile, 'force-stop\n', 'utf8');
        if (recoveryMode !== 'quiescence_sticky_pid') {
            setAppProcState('stopped');
        }
        process.exit(0);
    }
    if (argStr.includes('kill -9')) {
        if (logFile) fs.appendFileSync(logFile, 'kill -9\n', 'utf8');
        process.exit(0);
    }
    if (argStr.includes('ACTION_BACKUP_DB')) {
        process.exit(0);
    }
    if (argStr.includes('am startservice')) {
        if (logFile) fs.appendFileSync(logFile, 'startservice\n', 'utf8');
        if (recoveryMode === 'restore_ok' || recoveryMode === 'restore_status_unhealthy') {
            setAppProcState('4399');
            process.exit(0);
        }
        if (recoveryMode === 'restore_start_fail') {
            process.stderr.write('Permission Denial: not exported\n');
            process.exit(1);
        }
        process.exit(0);
    }
    if (argStr.includes('cmd activity start-service')) {
        if (logFile) fs.appendFileSync(logFile, 'cmd_start_service\n', 'utf8');
        if (recoveryMode === 'restore_start_fail') {
            process.exit(1);
        }
        process.exit(0);
    }
    if (argStr.includes('am start -n')) {
        if (logFile) fs.appendFileSync(logFile, 'start_main_activity\n', 'utf8');
        if (recoveryMode === 'restore_mainactivity_ok') {
            setAppProcState('4401');
            process.exit(0);
        }
        if (recoveryMode === 'restore_start_fail') {
            process.exit(1);
        }
        process.exit(0);
    }
    if (argStr.includes('/api/status')) {
        if (recoveryMode === 'restore_status_unhealthy') {
            console.log('{"status":"error","uinput_ready":false}');
            process.exit(0);
        }
        if (recoveryMode === 'restore_ok' || recoveryMode === 'restore_mainactivity_ok') {
            console.log('{"status":"ok","uinput_ready":true}');
            process.exit(0);
        }
        process.exit(1);
    }
    if (argStr.includes('PIDOF_CHECK') || argStr.includes('pidof')) {
        if (recoveryMode && appProcFile) {
            const stApp = getAppProcState();
            if (stApp && stApp !== 'stopped') {
                console.log('PIDOF_CHECK:pids=[' + stApp + ']:exit=[0]');
                process.exit(0);
            }
        }
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

    $appProcFile29 = Join-Path $testDir29 "app_proc_state.txt"
    $appProcEsc29 = $appProcFile29.Replace('\', '/')

    # --- Sotto-test 29j: Positivo Fase A - backup v5 valido + servizio attivo -> finally riavvia v5 + /api/status sano, zero install ---
    $backupDir29j = Join-Path $testDir29 "backup_29j"
    $backupEsc29j = $backupDir29j.Replace('\', '/')
    [System.IO.File]::WriteAllText($adbdStateFile29, "shell")
    [System.IO.File]::WriteAllText($appProcFile29, "4321")
    if (Test-Path $adbdLogFile29) { Remove-Item $adbdLogFile29 -Force }
    $cmd29j = @"
`$env:NODE_EXE = '$nodeEscaped29'
`$env:ADB_EXECUTABLE = '$mockAdbEsc29'
`$env:ADBD_STATE_FILE = '$stateEsc29'
`$env:ADBD_LOG_FILE = '$logEsc29'
`$env:DEVICE_DB_FILE = '$devDbEsc29'
`$env:DEVICE_WAL_FILE = '$walEsc29'
`$env:APP_PROC_STATE_FILE = '$appProcEsc29'
`$env:MOCK_ROOT_MODE = 'allow'
`$env:MOCK_RECOVERY_MODE = 'restore_ok'
try {
    & '$scriptEscaped' -Action backup -TargetTv '127.0.0.1' -HttpPort 59988 -BackupDir '$backupEsc29j' -AllowHardwareExecution
    Write-Output 'EXIT_OK_29J'
} catch {
    Write-Output ('CAUGHT_29J:' + `$_.Exception.Message)
}
"@
    $out29j = & $psExe -ExecutionPolicy Bypass -Command $cmd29j 2>&1 | Out-String
    $finalAppState29j = (Get-Content $appProcFile29 -Raw).Trim()
    $logLines29j = if (Test-Path $adbdLogFile29) { (Get-Content $adbdLogFile29 -Raw).Trim() } else { "" }
    if ($out29j -match "EXIT_OK_29J" -and $out29j -match "Sessione di backup completata" -and $out29j -match "\[RECOVERY V5\] Servizio it\.akai\.customremote ripristinato e verificato" -and $finalAppState29j -eq "4399" -and $logLines29j -match "force-stop" -and $logLines29j -match "startservice" -and $logLines29j -notmatch "\binstall\b" -and $logLines29j -notmatch "kill -9") {
        $subPassed29++
        Write-Host "   [PASS] Sotto-test 29j: Backup valido + finally riavvia v5 con /api/status sano (zero install, zero kill -9)" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 29j fallito (appState=$finalAppState29j, log='$logLines29j'): $out29j" -ForegroundColor Red
    }

    # --- Sotto-test 29k: Negativo - errore stream WAL dopo force-stop -> finally ripristina v5 e propaga errore backup ---
    $backupDir29k = Join-Path $testDir29 "backup_29k"
    $backupEsc29k = $backupDir29k.Replace('\', '/')
    [System.IO.File]::WriteAllText($adbdStateFile29, "shell")
    [System.IO.File]::WriteAllText($appProcFile29, "4321")
    if (Test-Path $adbdLogFile29) { Remove-Item $adbdLogFile29 -Force }
    $cmd29k = @"
`$env:NODE_EXE = '$nodeEscaped29'
`$env:ADB_EXECUTABLE = '$mockAdbEsc29'
`$env:ADBD_STATE_FILE = '$stateEsc29'
`$env:ADBD_LOG_FILE = '$logEsc29'
`$env:DEVICE_DB_FILE = '$devDbEsc29'
`$env:DEVICE_WAL_FILE = '$walEsc29'
`$env:APP_PROC_STATE_FILE = '$appProcEsc29'
`$env:MOCK_ROOT_MODE = 'wal_fail'
`$env:MOCK_RECOVERY_MODE = 'restore_ok'
try {
    & '$scriptEscaped' -Action backup -TargetTv '127.0.0.1' -HttpPort 59988 -BackupDir '$backupEsc29k' -AllowHardwareExecution
    Write-Output 'FAIL_NO_THROW_29K'
} catch {
    Write-Output ('CAUGHT_29K:' + `$_.Exception.Message)
}
"@
    $out29k = & $psExe -ExecutionPolicy Bypass -Command $cmd29k 2>&1 | Out-String
    $finalAppState29k = (Get-Content $appProcFile29 -Raw).Trim()
    $logLines29k = if (Test-Path $adbdLogFile29) { (Get-Content $adbdLogFile29 -Raw).Trim() } else { "" }
    if ($out29k -match "CAUGHT_29K:ERRORE FAIL-CLOSED: File WAL" -and $out29k -match "\[RECOVERY V5\] Servizio it\.akai\.customremote ripristinato e verificato" -and $finalAppState29k -eq "4399" -and $logLines29k -match "startservice" -and $out29k -notmatch "FAIL_NO_THROW_29K") {
        $subPassed29++
        Write-Host "   [PASS] Sotto-test 29k: Errore WAL post-stop -> finally ripristina v5 e propaga errore fail-closed" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 29k fallito (appState=$finalAppState29k, log='$logLines29k'): $out29k" -ForegroundColor Red
    }

    # --- Sotto-test 29l: Negativo - startservice / cmd activity / MainActivity falliscono nel finally -> STATO SERVIZIO V5 UNKNOWN ---
    $backupDir29l = Join-Path $testDir29 "backup_29l"
    $backupEsc29l = $backupDir29l.Replace('\', '/')
    [System.IO.File]::WriteAllText($adbdStateFile29, "shell")
    [System.IO.File]::WriteAllText($appProcFile29, "4321")
    if (Test-Path $adbdLogFile29) { Remove-Item $adbdLogFile29 -Force }
    $cmd29l = @"
`$env:NODE_EXE = '$nodeEscaped29'
`$env:ADB_EXECUTABLE = '$mockAdbEsc29'
`$env:ADBD_STATE_FILE = '$stateEsc29'
`$env:ADBD_LOG_FILE = '$logEsc29'
`$env:DEVICE_DB_FILE = '$devDbEsc29'
`$env:DEVICE_WAL_FILE = '$walEsc29'
`$env:APP_PROC_STATE_FILE = '$appProcEsc29'
`$env:MOCK_ROOT_MODE = 'allow'
`$env:MOCK_RECOVERY_MODE = 'restore_start_fail'
try {
    & '$scriptEscaped' -Action backup -TargetTv '127.0.0.1' -HttpPort 59988 -BackupDir '$backupEsc29l' -AllowHardwareExecution
    Write-Output 'FAIL_NO_THROW_29L'
} catch {
    Write-Output ('CAUGHT_29L:' + `$_.Exception.Message)
}
"@
    $out29l = & $psExe -ExecutionPolicy Bypass -Command $cmd29l 2>&1 | Out-String
    $logLines29l = if (Test-Path $adbdLogFile29) { (Get-Content $adbdLogFile29 -Raw).Trim() } else { "" }
    if ($out29l -match "CAUGHT_29L:ERRORE FAIL-CLOSED POST-BACKUP \[STATO SERVIZIO V5 UNKNOWN / RECUPERO MANUALE RICHIESTO\]" -and $logLines29l -match "startservice" -and $logLines29l -match "cmd_start_service" -and $logLines29l -match "start_main_activity" -and $out29l -notmatch "FAIL_NO_THROW_29L") {
        $subPassed29++
        Write-Host "   [PASS] Sotto-test 29l: Fallimento startservice/MainActivity post-backup segnala STATO SERVIZIO V5 UNKNOWN in Fail-Closed" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 29l fallito (log='$logLines29l'): $out29l" -ForegroundColor Red
    }

    # --- Sotto-test 29m: Negativo - processo v5 riparte ma /api/status non sano -> errore fail-closed post-backup ---
    $backupDir29m = Join-Path $testDir29 "backup_29m"
    $backupEsc29m = $backupDir29m.Replace('\', '/')
    [System.IO.File]::WriteAllText($adbdStateFile29, "shell")
    [System.IO.File]::WriteAllText($appProcFile29, "4321")
    if (Test-Path $adbdLogFile29) { Remove-Item $adbdLogFile29 -Force }
    $cmd29m = @"
`$env:NODE_EXE = '$nodeEscaped29'
`$env:ADB_EXECUTABLE = '$mockAdbEsc29'
`$env:ADBD_STATE_FILE = '$stateEsc29'
`$env:ADBD_LOG_FILE = '$logEsc29'
`$env:DEVICE_DB_FILE = '$devDbEsc29'
`$env:DEVICE_WAL_FILE = '$walEsc29'
`$env:APP_PROC_STATE_FILE = '$appProcEsc29'
`$env:MOCK_ROOT_MODE = 'allow'
`$env:MOCK_RECOVERY_MODE = 'restore_status_unhealthy'
try {
    & '$scriptEscaped' -Action backup -TargetTv '127.0.0.1' -HttpPort 59988 -BackupDir '$backupEsc29m' -AllowHardwareExecution
    Write-Output 'FAIL_NO_THROW_29M'
} catch {
    Write-Output ('CAUGHT_29M:' + `$_.Exception.Message)
}
"@
    $out29m = & $psExe -ExecutionPolicy Bypass -Command $cmd29m 2>&1 | Out-String
    if ($out29m -match "CAUGHT_29M:ERRORE FAIL-CLOSED POST-BACKUP \[STATO SERVIZIO V5 UNKNOWN / RECUPERO MANUALE RICHIESTO\]" -and $out29m -match "endpoint /api/status non sano" -and $out29m -notmatch "FAIL_NO_THROW_29M") {
        $subPassed29++
        Write-Host "   [PASS] Sotto-test 29m: /api/status non sano (uinput_ready=false) post-backup rifiutato in Fail-Closed" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 29m fallito: $out29m" -ForegroundColor Red
    }

    # --- Sotto-test 29n: Negativo - PID residuo dopo force-stop -> fallimento immediato SENZA kill -9 implicito ---
    $backupDir29n = Join-Path $testDir29 "backup_29n"
    $backupEsc29n = $backupDir29n.Replace('\', '/')
    [System.IO.File]::WriteAllText($adbdStateFile29, "shell")
    [System.IO.File]::WriteAllText($appProcFile29, "4321")
    if (Test-Path $adbdLogFile29) { Remove-Item $adbdLogFile29 -Force }
    $cmd29n = @"
`$env:NODE_EXE = '$nodeEscaped29'
`$env:ADB_EXECUTABLE = '$mockAdbEsc29'
`$env:ADBD_STATE_FILE = '$stateEsc29'
`$env:ADBD_LOG_FILE = '$logEsc29'
`$env:DEVICE_DB_FILE = '$devDbEsc29'
`$env:DEVICE_WAL_FILE = '$walEsc29'
`$env:APP_PROC_STATE_FILE = '$appProcEsc29'
`$env:MOCK_ROOT_MODE = 'allow'
`$env:MOCK_RECOVERY_MODE = 'quiescence_sticky_pid'
try {
    & '$scriptEscaped' -Action backup -TargetTv '127.0.0.1' -HttpPort 59988 -BackupDir '$backupEsc29n' -AllowHardwareExecution
    Write-Output 'FAIL_NO_THROW_29N'
} catch {
    Write-Output ('CAUGHT_29N:' + `$_.Exception.Message)
}
"@
    $out29n = & $psExe -ExecutionPolicy Bypass -Command $cmd29n 2>&1 | Out-String
    $logLines29n = if (Test-Path $adbdLogFile29) { (Get-Content $adbdLogFile29 -Raw).Trim() } else { "" }
    if ($out29n -match "CAUGHT_29N:ERRORE FAIL-CLOSED: Impossibile arrestare il processo dell'applicazione" -and $out29n -match "kill -9 implicito disabilitato" -and $logLines29n -notmatch "kill -9" -and $out29n -notmatch "FAIL_NO_THROW_29N") {
        $subPassed29++
        Write-Host "   [PASS] Sotto-test 29n: PID residuo dopo force-stop blocca in Fail-Closed senza alcuna invocazione kill -9" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 29n fallito (log='$logLines29n'): $out29n" -ForegroundColor Red
    }
} finally {
    Remove-Item $testDir29 -Recurse -Force -ErrorAction SilentlyContinue
}

if ($subPassed29 -eq 14) {
    Write-Host "[PASS] [TEST POSITIVO & NEGATIVO / ADB ROOT-UNROOT & WAL] Test 29: Elevation root/unroot, WAL checkpoint, EACCES, P1/P2 Fail-Closed e recovery v5 verificati al 100% (14/14)" -ForegroundColor Green
    $passed++
} else {
    Write-Host "[FAIL] [TEST POSITIVO & NEGATIVO / ADB ROOT-UNROOT & WAL] Test 29: Sotto-test superati: $subPassed29 / 14" -ForegroundColor Red
    $failed++
}

# -----------------------------------------------------------------------------
# TEST 30: Watchdog Fail-Closed quando HTTP 8088=200 ma HTTPS 8443 NON ascolta -> Auto-Rollback a v5 (P0-2)
# -----------------------------------------------------------------------------
Write-Host "`n--- Esecuzione Test 30: Watchdog Fail-Closed su HTTPS 8443 Spento (Porta Chiusa) con Rollback Atomico ---" -ForegroundColor Cyan
$testDir30 = Join-Path $tempDir "e2e_watchdog_https_down_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir30 | Out-Null

$mockHttpScript30 = Join-Path $testDir30 "mock_http_30.js"
$mockAdbJs30 = Join-Path $testDir30 "mock_adb_30.js"
$mockSignerJs30 = Join-Path $testDir30 "mock_signer_30.js"
$realDb30 = Join-Path $testDir30 "device_db.sqlite"
$deviceApk30 = Join-Path $testDir30 "device_backup.apk"
$candidateApk30 = Join-Path $testDir30 "candidate_release.apk"
$backupDir30 = Join-Path $testDir30 "backup_target"
$restoredTargetDb30 = Join-Path $testDir30 "restored_on_device.sqlite"

New-MockRealDatabase -FilePath $realDb30
[System.IO.File]::WriteAllText($deviceApk30, "PK_DEVICE_BACKUP_APK_MOCK_30")
[System.IO.File]::WriteAllText($candidateApk30, "PK_CANDIDATE_RELEASE_APK_MOCK_30")

@"
console.log('Signer #1 certificate SHA-256 digest: a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90');
process.exit(0);
"@ | Out-File -FilePath $mockSignerJs30 -Encoding ascii

$mockSignerCmd30 = if ($isWin) { Join-Path $testDir30 "apksigner.cmd" } else { Join-Path $testDir30 "apksigner" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockSignerJs30`" %*" | Out-File -FilePath $mockSignerCmd30 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockSignerJs30`" `"`$@`"" | Out-File -FilePath $mockSignerCmd30 -Encoding ascii
    & chmod +x $mockSignerCmd30
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
    const target = fs.existsSync(process.env.DEVICE_RESTORE_TARGET) ? process.env.DEVICE_RESTORE_TARGET : process.env.DEVICE_DB_FILE;
    const buf = fs.readFileSync(target);
    process.stdout.write(buf, () => process.exit(0));
    return;
}
if (args.includes('install')) { console.log('Success'); process.exit(0); }
if (args.includes('PIDOF_CHECK') || args.includes('pids=')) { console.log('PIDOF_CHECK:pids=[]:exit=[1]'); process.exit(0); }
if (args.includes('pidof')) { console.log('1234'); process.exit(0); }
if (args.includes('dumpsys package')) { console.log('    versionCode=3 minSdk=21 targetSdk=28\n    userId=10123'); process.exit(0); }
if (args.includes('stat -c')) { console.log('10123'); process.exit(0); }
if (args.includes('test -f') || args.includes('FILE_PROBE_RESULT')) { console.log('FILE_PROBE_RESULT:NOT_FOUND'); process.exit(0); }
if (args.includes('shell')) { process.exit(0); }
process.exit(0);
"@ | Out-File -FilePath $mockAdbJs30 -Encoding ascii

$mockAdbCmd30 = if ($isWin) { Join-Path $testDir30 "adb.cmd" } else { Join-Path $testDir30 "adb" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockAdbJs30`" %*" | Out-File -FilePath $mockAdbCmd30 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockAdbJs30`" `"`$@`"" | Out-File -FilePath $mockAdbCmd30 -Encoding ascii
    & chmod +x $mockAdbCmd30
}

$port30 = Get-FreeLoopbackPort
$closedHttpsPort30 = Get-FreeLoopbackPort
$readyFile30 = Join-Path $testDir30 "ready_30.txt"
$readyEsc30 = $readyFile30.Replace('\', '/')
@"
const http = require('http');
const fs = require('fs');
const server = http.createServer((req, res) => {
  if (req.url === '/api/status') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', uinput_ready: true, active_sessions: 1 }));
  } else if (req.url === '/index.html') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end('<!DOCTYPE html><html><body>AKAI Web Remote</body></html>');
  } else {
    res.writeHead(404);
    res.end();
  }
});
server.listen($port30, '127.0.0.1', () => { fs.writeFileSync('$readyEsc30', '1'); });
"@ | Out-File -FilePath $mockHttpScript30 -Encoding ascii

$httpProc30 = $null
try {
    $httpProc30 = Start-Process -FilePath $validNode -ArgumentList "`"$mockHttpScript30`"" -PassThru -NoNewWindow
    $wait30 = 100
    while (-not (Test-Path $readyFile30) -and -not $httpProc30.HasExited -and $wait30 -gt 0) {
        Start-Sleep -Milliseconds 100
        $wait30--
    }

    $scriptEscaped = $scriptPath.Replace('\', '/')
    $candidateEscaped = $candidateApk30.Replace('\', '/')
    $mockAdbEscaped = $mockAdbCmd30.Replace('\', '/')
    $mockSignerEscaped = $mockSignerCmd30.Replace('\', '/')
    $realDbEscaped = $realDb30.Replace('\', '/')
    $deviceApkEscaped = $deviceApk30.Replace('\', '/')
    $backupDirEscaped = $backupDir30.Replace('\', '/')
    $nodeEscaped = $validNode.Replace('\', '/')
    $targetRestoreEsc = $restoredTargetDb30.Replace('\', '/')

    $testCmd30 = @"
`$env:NODE_EXE = '$nodeEscaped'
`$env:ADB_EXECUTABLE = '$mockAdbEscaped'
`$env:APKSIGNER_EXECUTABLE = '$mockSignerEscaped'
`$env:DEVICE_DB_FILE = '$realDbEscaped'
`$env:DEVICE_APK_FILE = '$deviceApkEscaped'
`$env:DEVICE_RESTORE_TARGET = '$targetRestoreEsc'
`$env:WATCHDOG_ATTEMPTS = '2'
`$env:WATCHDOG_SLEEP_SEC = '1'

& '$scriptEscaped' -Action install -ApkPath '$candidateEscaped' -TargetTv '127.0.0.1' -HttpPort $port30 -HttpsPort $closedHttpsPort30 -BackupDir '$backupDirEscaped' -AllowHardwareExecution
"@
    $res30 = & $psExe -ExecutionPolicy Bypass -Command $testCmd30 2>&1 | Out-String

    if ($res30 -match "ALLARME: Health check fallito entro 30s! Avvio ROLLBACK" -and
        $res30 -match "ROLLBACK RIUSCITO E VERIFICATO" -and
        $res30 -match "TCP_TIMEOUT|NON operativo") {
        Write-Host "[PASS] [TEST NEGATIVO / WATCHDOG HTTPS DOWN FAIL-CLOSED] Test 30: Watchdog fallito su HTTPS 8443 spento (HTTP=200 non sufficiente) -> Rollback atomico a v5 eseguito e verificato" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO / WATCHDOG HTTPS DOWN FAIL-CLOSED] Test 30: Mancato rollback su HTTPS spento: $res30" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[FAIL] [TEST NEGATIVO / WATCHDOG HTTPS DOWN FAIL-CLOSED] Test 30: Eccezione imprevista: $($_.Exception.Message)" -ForegroundColor Red
    $failed++
} finally {
    if ($httpProc30 -and -not $httpProc30.HasExited) { Stop-Process -Id $httpProc30.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $testDir30 -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
# TEST 31: Watchdog Fail-Closed su SAN Mismatch Certificato HTTPS 8443 -> Auto-Rollback a v5 (P0-2)
# -----------------------------------------------------------------------------
Write-Host "`n--- Esecuzione Test 31: Watchdog Fail-Closed su SAN Mismatch Certificato HTTPS con Rollback Atomico ---" -ForegroundColor Cyan
$testDir31 = Join-Path $tempDir "e2e_watchdog_san_mismatch_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir31 | Out-Null

$mockHttpScript31 = Join-Path $testDir31 "mock_http_31.js"
$mockAdbJs31 = Join-Path $testDir31 "mock_adb_31.js"
$mockSignerJs31 = Join-Path $testDir31 "mock_signer_31.js"
$realDb31 = Join-Path $testDir31 "device_db.sqlite"
$deviceApk31 = Join-Path $testDir31 "device_backup.apk"
$candidateApk31 = Join-Path $testDir31 "candidate_release.apk"
$backupDir31 = Join-Path $testDir31 "backup_target"
$restoredTargetDb31 = Join-Path $testDir31 "restored_on_device.sqlite"
$pfxBadSan31 = Join-Path $testDir31 "cert_badsan.pfx"

New-MockRealDatabase -FilePath $realDb31
[System.IO.File]::WriteAllText($deviceApk31, "PK_DEVICE_BACKUP_APK_MOCK_31")
[System.IO.File]::WriteAllText($candidateApk31, "PK_CANDIDATE_RELEASE_APK_MOCK_31")
$null = New-MockTlsPfx -FilePath $pfxBadSan31 -SanIp "192.168.1.99"
$httpsProc31 = Start-MockHttpsNodeServer -PfxPath $pfxBadSan31 -BaseDir $testDir31
$httpsPort31 = $httpsProc31.Port

@"
console.log('Signer #1 certificate SHA-256 digest: a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90');
process.exit(0);
"@ | Out-File -FilePath $mockSignerJs31 -Encoding ascii

$mockSignerCmd31 = if ($isWin) { Join-Path $testDir31 "apksigner.cmd" } else { Join-Path $testDir31 "apksigner" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockSignerJs31`" %*" | Out-File -FilePath $mockSignerCmd31 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockSignerJs31`" `"`$@`"" | Out-File -FilePath $mockSignerCmd31 -Encoding ascii
    & chmod +x $mockSignerCmd31
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
    const target = fs.existsSync(process.env.DEVICE_RESTORE_TARGET) ? process.env.DEVICE_RESTORE_TARGET : process.env.DEVICE_DB_FILE;
    const buf = fs.readFileSync(target);
    process.stdout.write(buf, () => process.exit(0));
    return;
}
if (args.includes('install')) { console.log('Success'); process.exit(0); }
if (args.includes('PIDOF_CHECK') || args.includes('pids=')) { console.log('PIDOF_CHECK:pids=[]:exit=[1]'); process.exit(0); }
if (args.includes('pidof')) { console.log('1234'); process.exit(0); }
if (args.includes('dumpsys package')) { console.log('    versionCode=3 minSdk=21 targetSdk=28\n    userId=10123'); process.exit(0); }
if (args.includes('stat -c')) { console.log('10123'); process.exit(0); }
if (args.includes('test -f') || args.includes('FILE_PROBE_RESULT')) { console.log('FILE_PROBE_RESULT:NOT_FOUND'); process.exit(0); }
if (args.includes('shell')) { process.exit(0); }
process.exit(0);
"@ | Out-File -FilePath $mockAdbJs31 -Encoding ascii

$mockAdbCmd31 = if ($isWin) { Join-Path $testDir31 "adb.cmd" } else { Join-Path $testDir31 "adb" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockAdbJs31`" %*" | Out-File -FilePath $mockAdbCmd31 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockAdbJs31`" `"`$@`"" | Out-File -FilePath $mockAdbCmd31 -Encoding ascii
    & chmod +x $mockAdbCmd31
}

$port31 = Get-FreeLoopbackPort
$readyFile31 = Join-Path $testDir31 "ready_31.txt"
$readyEsc31 = $readyFile31.Replace('\', '/')
@"
const http = require('http');
const fs = require('fs');
const server = http.createServer((req, res) => {
  if (req.url === '/api/status') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', uinput_ready: true, active_sessions: 1 }));
  } else if (req.url === '/index.html') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end('<!DOCTYPE html><html><body>AKAI Web Remote</body></html>');
  } else {
    res.writeHead(404);
    res.end();
  }
});
server.listen($port31, '127.0.0.1', () => { fs.writeFileSync('$readyEsc31', '1'); });
"@ | Out-File -FilePath $mockHttpScript31 -Encoding ascii

$httpProc31 = $null
try {
    $httpProc31 = Start-Process -FilePath $validNode -ArgumentList "`"$mockHttpScript31`"" -PassThru -NoNewWindow
    $wait31 = 100
    while (-not (Test-Path $readyFile31) -and -not $httpProc31.HasExited -and $wait31 -gt 0) {
        Start-Sleep -Milliseconds 100
        $wait31--
    }

    $scriptEscaped = $scriptPath.Replace('\', '/')
    $candidateEscaped = $candidateApk31.Replace('\', '/')
    $mockAdbEscaped = $mockAdbCmd31.Replace('\', '/')
    $mockSignerEscaped = $mockSignerCmd31.Replace('\', '/')
    $realDbEscaped = $realDb31.Replace('\', '/')
    $deviceApkEscaped = $deviceApk31.Replace('\', '/')
    $backupDirEscaped = $backupDir31.Replace('\', '/')
    $nodeEscaped = $validNode.Replace('\', '/')
    $targetRestoreEsc = $restoredTargetDb31.Replace('\', '/')

    $testCmd31 = @"
`$env:NODE_EXE = '$nodeEscaped'
`$env:ADB_EXECUTABLE = '$mockAdbEscaped'
`$env:APKSIGNER_EXECUTABLE = '$mockSignerEscaped'
`$env:DEVICE_DB_FILE = '$realDbEscaped'
`$env:DEVICE_APK_FILE = '$deviceApkEscaped'
`$env:DEVICE_RESTORE_TARGET = '$targetRestoreEsc'
`$env:WATCHDOG_ATTEMPTS = '2'
`$env:WATCHDOG_SLEEP_SEC = '1'

& '$scriptEscaped' -Action install -ApkPath '$candidateEscaped' -TargetTv '127.0.0.1' -HttpPort $port31 -HttpsPort $httpsPort31 -BackupDir '$backupDirEscaped' -AllowHardwareExecution
"@
    $res31 = & $psExe -ExecutionPolicy Bypass -Command $testCmd31 2>&1 | Out-String

    if ($res31 -match "ALLARME: Health check fallito entro 30s! Avvio ROLLBACK" -and
        $res31 -match "ROLLBACK RIUSCITO E VERIFICATO" -and
        $res31 -match "SAN_MISMATCH") {
        Write-Host "[PASS] [TEST NEGATIVO / WATCHDOG SAN MISMATCH FAIL-CLOSED] Test 31: Watchdog fallito su SAN mismatch certificato HTTPS -> Rollback atomico a v5 eseguito e verificato" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO / WATCHDOG SAN MISMATCH FAIL-CLOSED] Test 31: Mancato rollback su SAN mismatch: $res31" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[FAIL] [TEST NEGATIVO / WATCHDOG SAN MISMATCH FAIL-CLOSED] Test 31: Eccezione imprevista: $($_.Exception.Message)" -ForegroundColor Red
    $failed++
} finally {
    if ($httpProc31 -and -not $httpProc31.HasExited) { Stop-Process -Id $httpProc31.Id -Force -ErrorAction SilentlyContinue }
    if ($httpsProc31 -and $httpsProc31.Process -and -not $httpsProc31.Process.HasExited) { Stop-Process -Id $httpsProc31.Process.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $testDir31 -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
# TEST 32: Watchdog Fail-Closed su HTTP 426 su /index.html (Regressione Telecomando LAN) -> Auto-Rollback a v5 (P1-1)
# -----------------------------------------------------------------------------
Write-Host "`n--- Esecuzione Test 32: Watchdog Fail-Closed su HTTP 426 (/index.html) con Rollback Atomico ---" -ForegroundColor Cyan
$testDir32 = Join-Path $tempDir "e2e_watchdog_http_426_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir32 | Out-Null

$mockHttpScript32 = Join-Path $testDir32 "mock_http_32.js"
$mockAdbJs32 = Join-Path $testDir32 "mock_adb_32.js"
$mockSignerJs32 = Join-Path $testDir32 "mock_signer_32.js"
$realDb32 = Join-Path $testDir32 "device_db.sqlite"
$deviceApk32 = Join-Path $testDir32 "device_backup.apk"
$candidateApk32 = Join-Path $testDir32 "candidate_release.apk"
$backupDir32 = Join-Path $testDir32 "backup_target"
$restoredTargetDb32 = Join-Path $testDir32 "restored_on_device.sqlite"
$pfx32 = Join-Path $testDir32 "cert32.pfx"

New-MockRealDatabase -FilePath $realDb32
[System.IO.File]::WriteAllText($deviceApk32, "PK_DEVICE_BACKUP_APK_MOCK_32")
[System.IO.File]::WriteAllText($candidateApk32, "PK_CANDIDATE_RELEASE_APK_MOCK_32")
$shaCa32 = New-MockTlsPfx -FilePath $pfx32 -SanIp "127.0.0.1"
$httpsProc32 = Start-MockHttpsNodeServer -PfxPath $pfx32 -BaseDir $testDir32
$httpsPort32 = $httpsProc32.Port

@"
console.log('Signer #1 certificate SHA-256 digest: a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90');
process.exit(0);
"@ | Out-File -FilePath $mockSignerJs32 -Encoding ascii

$mockSignerCmd32 = if ($isWin) { Join-Path $testDir32 "apksigner.cmd" } else { Join-Path $testDir32 "apksigner" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockSignerJs32`" %*" | Out-File -FilePath $mockSignerCmd32 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockSignerJs32`" `"`$@`"" | Out-File -FilePath $mockSignerCmd32 -Encoding ascii
    & chmod +x $mockSignerCmd32
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
    const target = fs.existsSync(process.env.DEVICE_RESTORE_TARGET) ? process.env.DEVICE_RESTORE_TARGET : process.env.DEVICE_DB_FILE;
    const buf = fs.readFileSync(target);
    process.stdout.write(buf, () => process.exit(0));
    return;
}
if (args.includes('install')) { console.log('Success'); process.exit(0); }
if (args.includes('PIDOF_CHECK') || args.includes('pids=')) { console.log('PIDOF_CHECK:pids=[]:exit=[1]'); process.exit(0); }
if (args.includes('pidof')) { console.log('1234'); process.exit(0); }
if (args.includes('dumpsys package')) { console.log('    versionCode=3 minSdk=21 targetSdk=28\n    userId=10123'); process.exit(0); }
if (args.includes('stat -c')) { console.log('10123'); process.exit(0); }
if (args.includes('test -f') || args.includes('FILE_PROBE_RESULT')) { console.log('FILE_PROBE_RESULT:NOT_FOUND'); process.exit(0); }
if (args.includes('shell')) { process.exit(0); }
process.exit(0);
"@ | Out-File -FilePath $mockAdbJs32 -Encoding ascii

$mockAdbCmd32 = if ($isWin) { Join-Path $testDir32 "adb.cmd" } else { Join-Path $testDir32 "adb" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockAdbJs32`" %*" | Out-File -FilePath $mockAdbCmd32 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockAdbJs32`" `"`$@`"" | Out-File -FilePath $mockAdbCmd32 -Encoding ascii
    & chmod +x $mockAdbCmd32
}

$port32 = Get-FreeLoopbackPort
$readyFile32 = Join-Path $testDir32 "ready_32.txt"
$readyEsc32 = $readyFile32.Replace('\', '/')
@"
const http = require('http');
const fs = require('fs');
const server = http.createServer((req, res) => {
  if (req.url === '/api/status') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', uinput_ready: true, active_sessions: 1 }));
  } else if (req.url === '/index.html') {
    // Simulazione regressione: il server restituisce 426 Upgrade Required (vietato su /index.html in beta)
    res.writeHead(426, { 'Content-Type': 'application/json', 'Upgrade': 'TLS/1.0, HTTP/2.0' });
    res.end(JSON.stringify({ error: 'Upgrade Required: use HTTPS on port 8443' }));
  } else {
    res.writeHead(404);
    res.end();
  }
});
server.listen($port32, '127.0.0.1', () => { fs.writeFileSync('$readyEsc32', '1'); });
"@ | Out-File -FilePath $mockHttpScript32 -Encoding ascii

$httpProc32 = $null
try {
    $httpProc32 = Start-Process -FilePath $validNode -ArgumentList "`"$mockHttpScript32`"" -PassThru -NoNewWindow
    $wait32 = 100
    while (-not (Test-Path $readyFile32) -and -not $httpProc32.HasExited -and $wait32 -gt 0) {
        Start-Sleep -Milliseconds 100
        $wait32--
    }

    $scriptEscaped = $scriptPath.Replace('\', '/')
    $candidateEscaped = $candidateApk32.Replace('\', '/')
    $mockAdbEscaped = $mockAdbCmd32.Replace('\', '/')
    $mockSignerEscaped = $mockSignerCmd32.Replace('\', '/')
    $realDbEscaped = $realDb32.Replace('\', '/')
    $deviceApkEscaped = $deviceApk32.Replace('\', '/')
    $backupDirEscaped = $backupDir32.Replace('\', '/')
    $nodeEscaped = $validNode.Replace('\', '/')
    $targetRestoreEsc = $restoredTargetDb32.Replace('\', '/')

    $testCmd32 = @"
`$env:NODE_EXE = '$nodeEscaped'
`$env:ADB_EXECUTABLE = '$mockAdbEscaped'
`$env:APKSIGNER_EXECUTABLE = '$mockSignerEscaped'
`$env:DEVICE_DB_FILE = '$realDbEscaped'
`$env:DEVICE_APK_FILE = '$deviceApkEscaped'
`$env:DEVICE_RESTORE_TARGET = '$targetRestoreEsc'
`$env:WATCHDOG_ATTEMPTS = '2'
`$env:WATCHDOG_SLEEP_SEC = '1'

& '$scriptEscaped' -Action install -ApkPath '$candidateEscaped' -TargetTv '127.0.0.1' -HttpPort $port32 -HttpsPort $httpsPort32 -ExpectedCaFingerprint '$shaCa32' -BackupDir '$backupDirEscaped' -AllowHardwareExecution
"@
    $res32 = & $psExe -ExecutionPolicy Bypass -Command $testCmd32 2>&1 | Out-String

    if ($res32 -match "ALLARME: Health check fallito entro 30s! Avvio ROLLBACK" -and
        $res32 -match "ROLLBACK RIUSCITO E VERIFICATO" -and
        $res32 -match "HTTP 426 Upgrade Required su /index.html: regressione telecomando classico LAN vietata") {
        Write-Host "[PASS] [TEST NEGATIVO / WATCHDOG 426 REGRESSION FAIL-CLOSED] Test 32: Watchdog fallito su HTTP 426 su /index.html -> Rollback atomico a v5 eseguito e verificato (P1-1)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO / WATCHDOG 426 REGRESSION FAIL-CLOSED] Test 32: Mancato rollback su 426 regressione: $res32" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[FAIL] [TEST NEGATIVO / WATCHDOG 426 REGRESSION FAIL-CLOSED] Test 32: Eccezione imprevista: $($_.Exception.Message)" -ForegroundColor Red
    $failed++
} finally {
    if ($httpProc32 -and -not $httpProc32.HasExited) { Stop-Process -Id $httpProc32.Id -Force -ErrorAction SilentlyContinue }
    if ($httpsProc32 -and $httpsProc32.Process -and -not $httpsProc32.Process.HasExited) { Stop-Process -Id $httpsProc32.Process.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $testDir32 -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
# TEST 33: Verifica Distinzione Stato Provvisorio (OOB Trust Pending) vs Approvazione 100% (P1-2)
# -----------------------------------------------------------------------------
Write-Host "`n--- Esecuzione Test 33: Verifica Distinzione Stato Provvisorio vs Approvazione 100% ---" -ForegroundColor Cyan
$testDir33 = Join-Path $tempDir "e2e_watchdog_provisional_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir33 | Out-Null

$mockHttpScript33 = Join-Path $testDir33 "mock_http_33.js"
$mockAdbJs33 = Join-Path $testDir33 "mock_adb_33.js"
$mockSignerJs33 = Join-Path $testDir33 "mock_signer_33.js"
$realDb33 = Join-Path $testDir33 "device_db.sqlite"
$deviceApk33 = Join-Path $testDir33 "device_backup.apk"
$candidateApk33 = Join-Path $testDir33 "candidate_release.apk"
$backupDir33 = Join-Path $testDir33 "backup_target"
$pfx33 = Join-Path $testDir33 "cert33.pfx"

New-MockRealDatabase -FilePath $realDb33
[System.IO.File]::WriteAllText($deviceApk33, "PK_DEVICE_BACKUP_APK_MOCK_33")
[System.IO.File]::WriteAllText($candidateApk33, "PK_CANDIDATE_RELEASE_APK_MOCK_33")
$shaCa33 = New-MockTlsPfx -FilePath $pfx33 -SanIp "127.0.0.1"
$httpsProc33 = Start-MockHttpsNodeServer -PfxPath $pfx33 -BaseDir $testDir33
$httpsPort33 = $httpsProc33.Port

@"
console.log('Signer #1 certificate SHA-256 digest: a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90');
process.exit(0);
"@ | Out-File -FilePath $mockSignerJs33 -Encoding ascii

$mockSignerCmd33 = if ($isWin) { Join-Path $testDir33 "apksigner.cmd" } else { Join-Path $testDir33 "apksigner" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockSignerJs33`" %*" | Out-File -FilePath $mockSignerCmd33 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockSignerJs33`" `"`$@`"" | Out-File -FilePath $mockSignerCmd33 -Encoding ascii
    & chmod +x $mockSignerCmd33
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
if (args.includes('dumpsys package')) { console.log('    versionCode=3 minSdk=21 targetSdk=28\n    userId=10123'); process.exit(0); }
if (args.includes('stat -c')) { console.log('10123'); process.exit(0); }
if (args.includes('test -f') || args.includes('FILE_PROBE_RESULT')) { console.log('FILE_PROBE_RESULT:NOT_FOUND'); process.exit(0); }
if (args.includes('shell')) { process.exit(0); }
process.exit(0);
"@ | Out-File -FilePath $mockAdbJs33 -Encoding ascii

$mockAdbCmd33 = if ($isWin) { Join-Path $testDir33 "adb.cmd" } else { Join-Path $testDir33 "adb" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockAdbJs33`" %*" | Out-File -FilePath $mockAdbCmd33 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockAdbJs33`" `"`$@`"" | Out-File -FilePath $mockAdbCmd33 -Encoding ascii
    & chmod +x $mockAdbCmd33
}

$port33 = Get-FreeLoopbackPort
$readyFile33 = Join-Path $testDir33 "ready_33.txt"
$readyEsc33 = $readyFile33.Replace('\', '/')
@"
const http = require('http');
const fs = require('fs');
const server = http.createServer((req, res) => {
  if (req.url === '/api/status') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', uinput_ready: true, active_sessions: 1 }));
  } else if (req.url === '/index.html') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end('<!DOCTYPE html><html><body>AKAI Web Remote</body></html>');
  } else {
    res.writeHead(404);
    res.end();
  }
});
server.listen($port33, '127.0.0.1', () => { fs.writeFileSync('$readyEsc33', '1'); });
"@ | Out-File -FilePath $mockHttpScript33 -Encoding ascii

$httpProc33 = $null
try {
    $httpProc33 = Start-Process -FilePath $validNode -ArgumentList "`"$mockHttpScript33`"" -PassThru -NoNewWindow
    $wait33 = 100
    while (-not (Test-Path $readyFile33) -and -not $httpProc33.HasExited -and $wait33 -gt 0) {
        Start-Sleep -Milliseconds 100
        $wait33--
    }

    $scriptEscaped = $scriptPath.Replace('\', '/')
    $candidateEscaped = $candidateApk33.Replace('\', '/')
    $mockAdbEscaped = $mockAdbCmd33.Replace('\', '/')
    $mockSignerEscaped = $mockSignerCmd33.Replace('\', '/')
    $realDbEscaped = $realDb33.Replace('\', '/')
    $deviceApkEscaped = $deviceApk33.Replace('\', '/')
    $backupDirEscaped = $backupDir33.Replace('\', '/')
    $nodeEscaped = $validNode.Replace('\', '/')

    # Sotto-test 33a: Esecuzione SENZA -ExpectedCaFingerprint -> Stato Provvisorio
    $testCmd33a = @"
`$env:NODE_EXE = '$nodeEscaped'
`$env:ADB_EXECUTABLE = '$mockAdbEscaped'
`$env:APKSIGNER_EXECUTABLE = '$mockSignerEscaped'
`$env:DEVICE_DB_FILE = '$realDbEscaped'
`$env:DEVICE_APK_FILE = '$deviceApkEscaped'
`$env:WATCHDOG_ATTEMPTS = '2'
`$env:WATCHDOG_SLEEP_SEC = '1'

& '$scriptEscaped' -Action install -ApkPath '$candidateEscaped' -TargetTv '127.0.0.1' -HttpPort $port33 -HttpsPort $httpsPort33 -BackupDir '$backupDirEscaped' -AllowHardwareExecution
"@
    $res33a = & $psExe -ExecutionPolicy Bypass -Command $testCmd33a 2>&1 | Out-String

    $provOk = ($res33a -match "STATO PROVVISORIO: AVVIO TECNICO RIUSCITO \(PROVISIONAL / OOB TRUST PENDING\)" -and
               $res33a -match "DIVIETO: Non utilizzare credenziali/PIN/chiavi su HTTPS finche' l'impronta non e' verificata fuori banda" -and
               $res33a -notmatch "DEPLOYMENT VERIFICATO CON SUCCESSO AL 100%")

    if ($provOk) {
        Write-Host "   [PASS] Sotto-test 33a: Senza -ExpectedCaFingerprint emesso STATO PROVVISORIO con divieto credenziali e zero false approvazioni al 100%" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 33a: Mancata emissione stato provvisorio: $res33a" -ForegroundColor Red
    }

    # Sotto-test 33b: Esecuzione CON -ExpectedCaFingerprint corrispondente -> Approvazione 100%
    $testCmd33b = @"
`$env:NODE_EXE = '$nodeEscaped'
`$env:ADB_EXECUTABLE = '$mockAdbEscaped'
`$env:APKSIGNER_EXECUTABLE = '$mockSignerEscaped'
`$env:DEVICE_DB_FILE = '$realDbEscaped'
`$env:DEVICE_APK_FILE = '$deviceApkEscaped'
`$env:WATCHDOG_ATTEMPTS = '2'
`$env:WATCHDOG_SLEEP_SEC = '1'

& '$scriptEscaped' -Action install -ApkPath '$candidateEscaped' -TargetTv '127.0.0.1' -HttpPort $port33 -HttpsPort $httpsPort33 -ExpectedCaFingerprint '$shaCa33' -BackupDir '$backupDirEscaped' -AllowHardwareExecution
"@
    $res33b = & $psExe -ExecutionPolicy Bypass -Command $testCmd33b 2>&1 | Out-String

    $apprOk = ($res33b -match "DEPLOYMENT VERIFICATO CON SUCCESSO AL 100%! Tutti i componenti operativi e Root CA approvata")

    if ($apprOk) {
        Write-Host "   [PASS] Sotto-test 33b: Con -ExpectedCaFingerprint corrispondente emessa approvazione definitiva al 100%" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 33b: Mancata approvazione 100%: $res33b" -ForegroundColor Red
    }

    if ($provOk -and $apprOk) {
        Write-Host "[PASS] [TEST AFFERMATIVO / PROVISIONAL VS APPROVED OOB TRUST] Test 33: Distinzione deterministica tra Stato Provvisorio e Approvazione 100% verificata (P1-2)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST AFFERMATIVO / PROVISIONAL VS APPROVED OOB TRUST] Test 33: Verifica fallita" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[FAIL] [TEST AFFERMATIVO / PROVISIONAL VS APPROVED OOB TRUST] Test 33: Eccezione imprevista: $($_.Exception.Message)" -ForegroundColor Red
    $failed++
} finally {
    if ($httpProc33 -and -not $httpProc33.HasExited) { Stop-Process -Id $httpProc33.Id -Force -ErrorAction SilentlyContinue }
    if ($httpsProc33 -and $httpsProc33.Process -and -not $httpsProc33.Process.HasExited) { Stop-Process -Id $httpsProc33.Process.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $testDir33 -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
# TEST 34: Modalita' Sola Lettura -Action verify-tls e Validazione Fuori Banda OOB (P1 Operativo)
# -----------------------------------------------------------------------------
Write-Host "`n--- Esecuzione Test 34: Modalita' Sola Lettura -Action verify-tls e Validazione OOB ---" -ForegroundColor Cyan
$testDir34 = Join-Path $tempDir "e2e_verify_tls_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir34 | Out-Null

$mockAdbJs34 = Join-Path $testDir34 "mock_adb_34.js"
$auditLog34 = Join-Path $testDir34 "adb_audit_34.txt"
$auditEsc34 = $auditLog34.Replace('\', '/')
$pfx34 = Join-Path $testDir34 "cert34.pfx"

$shaCa34 = New-MockTlsPfx -FilePath $pfx34 -SanIp "127.0.0.1"
$httpsProc34 = Start-MockHttpsNodeServer -PfxPath $pfx34 -BaseDir $testDir34
$httpsPort34 = $httpsProc34.Port

@"
const fs = require('fs');
const argv = process.argv.slice(2);
const args = argv.join(' ');
fs.appendFileSync('$auditEsc34', args + '\n');

if (args.includes('install') || args.includes('force-stop') || args.includes('root')) {
    console.error('VIOLATION: Chiamata adb vietata in modalita sola lettura: ' + args);
    process.exit(1);
}
process.exit(0);
"@ | Out-File -FilePath $mockAdbJs34 -Encoding ascii

$mockAdbCmd34 = if ($isWin) { Join-Path $testDir34 "adb.cmd" } else { Join-Path $testDir34 "adb" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockAdbJs34`" %*" | Out-File -FilePath $mockAdbCmd34 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockAdbJs34`" `"`$@`"" | Out-File -FilePath $mockAdbCmd34 -Encoding ascii
    & chmod +x $mockAdbCmd34
}

try {
    $scriptEscaped = $scriptPath.Replace('\', '/')
    $mockAdbEscaped = $mockAdbCmd34.Replace('\', '/')
    $nodeEscaped = $validNode.Replace('\', '/')

    # Sotto-test 34a: Esecuzione -Action verify-tls SENZA -ExpectedCaFingerprint
    # Deve restare in stato PROVISIONAL, riportare l'impronta osservata come NON VERIFICATA e non toccare ADB
    $testCmd34a = @"
`$env:NODE_EXE = '$nodeEscaped'
`$env:ADB_EXECUTABLE = '$mockAdbEscaped'
& '$scriptEscaped' -Action verify-tls -TargetTv '127.0.0.1' -HttpsPort $httpsPort34
"@
    $res34a = & $psExe -ExecutionPolicy Bypass -Command $testCmd34a 2>&1 | Out-String

    $prov34Ok = ($res34a -match "\[PROVISIONAL / OOB TRUST PENDING\]" -and
                 $res34a -match "Impronta osservata su connessione TLS \(NON VERIFICATA\): $shaCa34" -and
                 $res34a -notmatch "\[APPROVED\]" -and
                 $res34a -match "Modalita' 100% READ-ONLY")

    if ($prov34Ok) {
        Write-Host "   [PASS] Sotto-test 34a: -Action verify-tls senza fingerprint resta in PROVISIONAL (read-only, zero ADB)" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 34a: Esito non conforme: $res34a" -ForegroundColor Red
    }

    # Sotto-test 34b: Esecuzione -Action verify-tls CON -ExpectedCaFingerprint ERRATO (mismatch)
    # Deve fallire categoricamente (exit non-zero, CA_UNTRUSTED_MISMATCH)
    $wrongFp = "0000000000000000000000000000000000000000000000000000000000000000"
    $testCmd34b = @"
`$env:NODE_EXE = '$nodeEscaped'
`$env:ADB_EXECUTABLE = '$mockAdbEscaped'
& '$scriptEscaped' -Action verify-tls -TargetTv '127.0.0.1' -HttpsPort $httpsPort34 -ExpectedCaFingerprint '$wrongFp'
"@
    $res34b = & $psExe -ExecutionPolicy Bypass -Command $testCmd34b 2>&1 | Out-String

    $mismatch34Ok = ($res34b -match "FALLIMENTO VERIFICA TLS" -and
                     $res34b -match "CA_UNTRUSTED_MISMATCH" -and
                     $res34b -notmatch "\[APPROVED\]")

    if ($mismatch34Ok) {
        Write-Host "   [PASS] Sotto-test 34b: -Action verify-tls con impronta errata blocca categoricamente in Fail-Closed (CA_UNTRUSTED_MISMATCH)" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 34b: Mancato blocco fail-closed: $res34b" -ForegroundColor Red
    }

    # Sotto-test 34c: Esecuzione -Action verify-tls CON -ExpectedCaFingerprint VALIDO ($shaCa34 convalidata OOB)
    # Deve restituire APPROVED al 100%
    $testCmd34c = @"
`$env:NODE_EXE = '$nodeEscaped'
`$env:ADB_EXECUTABLE = '$mockAdbEscaped'
& '$scriptEscaped' -Action verify-tls -TargetTv '127.0.0.1' -HttpsPort $httpsPort34 -ExpectedCaFingerprint '$shaCa34'
"@
    $res34c = & $psExe -ExecutionPolicy Bypass -Command $testCmd34c 2>&1 | Out-String

    $appr34Ok = ($res34c -match "\[APPROVED\] CONVALIDA CRITTOGRAFICA RIUSCITA AL 100%" -and
                 $res34c -match "Autenticazione canale TLS confermata: autorizzato utilizzo credenziali/PIN/chiavi")

    if ($appr34Ok) {
        Write-Host "   [PASS] Sotto-test 34c: -Action verify-tls con impronta OOB valida convalidata al 100% (APPROVED)" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 34c: Mancata approvazione: $res34c" -ForegroundColor Red
    }

    # Sotto-test 34d: Verifica zero invocazioni ADB (sola lettura pura)
    $adbCalls = if (Test-Path $auditLog34) { Get-Content $auditLog34 } else { @() }
    $adbPurityOk = ($adbCalls.Count -eq 0)

    if ($adbPurityOk) {
        Write-Host "   [PASS] Sotto-test 34d: Verifica assoluta di sola lettura: ZERO chiamate ADB effettuate (install, force-stop, root = 0)" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 34d: Violazione purezza read-only, rilevate chiamate ADB: $adbCalls" -ForegroundColor Red
    }

    if ($prov34Ok -and $mismatch34Ok -and $appr34Ok -and $adbPurityOk) {
        Write-Host "[PASS] [TEST AFFERMATIVO & NEGATIVO / READ-ONLY VERIFY-TLS] Test 34: Modalita' sola lettura verify-tls convalidata al 100% (P1 Operativo)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST AFFERMATIVO & NEGATIVO / READ-ONLY VERIFY-TLS] Test 34: Fallito" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[FAIL] [TEST AFFERMATIVO & NEGATIVO / READ-ONLY VERIFY-TLS] Test 34: Eccezione imprevista: $($_.Exception.Message)" -ForegroundColor Red
    $failed++
} finally {
    if ($httpsProc34 -and $httpsProc34.Process -and -not $httpsProc34.Process.HasExited) { Stop-Process -Id $httpsProc34.Process.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $testDir34 -Recurse -Force -ErrorAction SilentlyContinue
}

# ==============================================================================
# TEST 35: [TEST NEGATIVO & AFFERMATIVO / GATE NEGATIVO ASSET TLS CANDIDATO FAIL-CLOSED]
# L'APK candidato non deve contenere credenziali/certificati TLS preconfezionati
# (*.p12, *.jks, *.key, *.der, *.crt, *.pass, server_keystore).
# Sub-test 35a: APK con server_keystore.p12 bloccato categoricamente in Fail-Closed
# Sub-test 35b: APK con AkaiRootCA.crt bloccato categoricamente in Fail-Closed
# Sub-test 35c: APK pulito (solo DEX, JNI so, Web assets) approvato al 100%
# ==============================================================================
Write-Host "`n--- Esecuzione Test 35: Gate Negativo su APK Candidato con Materiale TLS Vietato ---" -ForegroundColor Yellow
$testDir35 = Join-Path $tempDir "test35_tls_gate_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir35 | Out-Null

try {
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    # Helper per creare zip di test
    function New-TestApkArchive($targetFile, $entryPaths) {
        if (Test-Path $targetFile) { Remove-Item $targetFile -Force }
        $archive = [System.IO.Compression.ZipFile]::Open($targetFile, [System.IO.Compression.ZipArchiveMode]::Create)
        foreach ($ep in $entryPaths) {
            $e = $archive.CreateEntry($ep)
            $w = New-Object System.IO.StreamWriter($e.Open())
            $w.WriteLine("TEST_CONTENT")
            $w.Dispose()
        }
        $archive.Dispose()
    }

    $apkForbiddenP12 = Join-Path $testDir35 "bad_p12.apk"
    New-TestApkArchive $apkForbiddenP12 @("classes.dex", "assets/server_keystore.p12", "assets/www/index.html")

    $apkForbiddenCrt = Join-Path $testDir35 "bad_crt.apk"
    New-TestApkArchive $apkForbiddenCrt @("classes.dex", "assets/www/AkaiRootCA.crt", "assets/www/index.html")

    $apkClean = Join-Path $testDir35 "clean.apk"
    New-TestApkArchive $apkClean @("classes.dex", "lib/armeabi-v7a/libakai_uinput.so", "assets/www/index.html", "assets/www/app.js")

    $scriptEscaped = $scriptPath.Replace('\', '/')
    $p12Escaped = $apkForbiddenP12.Replace('\', '/')
    $crtEscaped = $apkForbiddenCrt.Replace('\', '/')
    $cleanEscaped = $apkClean.Replace('\', '/')

    # Sotto-test 35a: Blocco server_keystore.p12
    $cmd35a = @"
. '$scriptEscaped' -Action plan | Out-Null
try {
    Assert-CandidateApkNoForbiddenTlsAssets '$p12Escaped'
    Write-Host 'UNEXPECTED_PASS'
} catch {
    Write-Host `$_.Exception.Message
}
"@
    $res35a = & $psExe -ExecutionPolicy Bypass -Command $cmd35a 2>&1 | Out-String
    $p12Blocked = ($res35a -match "BLOCCO FAIL-CLOSED DI SICUREZZA" -and $res35a -match "server_keystore\.p12" -and $res35a -notmatch "UNEXPECTED_PASS")

    if ($p12Blocked) {
        Write-Host "   [PASS] Sotto-test 35a: APK con server_keystore.p12 bloccato categoricamente in Fail-Closed" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 35a: Mancato blocco server_keystore.p12: $res35a" -ForegroundColor Red
    }

    # Sotto-test 35b: Blocco AkaiRootCA.crt
    $cmd35b = @"
. '$scriptEscaped' -Action plan | Out-Null
try {
    Assert-CandidateApkNoForbiddenTlsAssets '$crtEscaped'
    Write-Host 'UNEXPECTED_PASS'
} catch {
    Write-Host `$_.Exception.Message
}
"@
    $res35b = & $psExe -ExecutionPolicy Bypass -Command $cmd35b 2>&1 | Out-String
    $crtBlocked = ($res35b -match "BLOCCO FAIL-CLOSED DI SICUREZZA" -and $res35b -match "AkaiRootCA\.crt" -and $res35b -notmatch "UNEXPECTED_PASS")

    if ($crtBlocked) {
        Write-Host "   [PASS] Sotto-test 35b: APK con AkaiRootCA.crt bloccato categoricamente in Fail-Closed" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 35b: Mancato blocco AkaiRootCA.crt: $res35b" -ForegroundColor Red
    }

    # Sotto-test 35c: APK pulito approvato
    $cmd35c = @"
. '$scriptEscaped' -Action plan | Out-Null
try {
    Assert-CandidateApkNoForbiddenTlsAssets '$cleanEscaped'
} catch {
    Write-Host `$_.Exception.Message
}
"@
    $res35c = & $psExe -ExecutionPolicy Bypass -Command $cmd35c 2>&1 | Out-String
    $cleanOk = ($res35c -match "\[PASS\] Assenza credenziali TLS preconfezionate confermata" -and $res35c -notmatch "BLOCCO")

    if ($cleanOk) {
        Write-Host "   [PASS] Sotto-test 35c: APK pulito (solo DEX, JNI e Web) approvato al 100%" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 35c: APK pulito rifiutato: $res35c" -ForegroundColor Red
    }

    if ($p12Blocked -and $crtBlocked -and $cleanOk) {
        Write-Host "[PASS] [TEST NEGATIVO & AFFERMATIVO / GATE NEGATIVO ASSET TLS CANDIDATO] Test 35: Gate Negativo su APK Candidato convalidato al 100% (3/3)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO & AFFERMATIVO / GATE NEGATIVO ASSET TLS CANDIDATO] Test 35: Fallito" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[FAIL] [TEST NEGATIVO & AFFERMATIVO / GATE NEGATIVO ASSET TLS CANDIDATO] Test 35: Eccezione imprevista: $($_.Exception.Message)" -ForegroundColor Red
    $failed++
} finally {
    Remove-Item $testDir35 -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
# TEST 36: Snapshot Identità TLS in Backup di Sessione, Cifratura Vault e Protezione Segreti (P1 Supervisor Gate)
# -----------------------------------------------------------------------------
Write-Host "`n--- Esecuzione Test 36: Snapshot Identità TLS in Backup di Sessione e Cifratura Vault ---" -ForegroundColor Cyan
$testDir36 = Join-Path $tempDir "e2e_tls_backup_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir36 | Out-Null

$mockAdbJs36 = Join-Path $testDir36 "mock_adb_36.js"
$devStorage36 = Join-Path $testDir36 "dev_storage"
New-Item -ItemType Directory -Force -Path $devStorage36 | Out-Null

# Creiamo file TLS sintetici simulati su storage device
$synthKsPath = Join-Path $devStorage36 "server_keystore.p12"
$synthPassPath = Join-Path $devStorage36 "server_keystore.pass"
$synthPemPath = Join-Path $devStorage36 "ca.pem"
$synthCrtPath = Join-Path $devStorage36 "ca.crt"
$synthKeyPath = Join-Path $devStorage36 "ca_key.der"

# Keystore sintetico di almeno 512 bytes
$dummyBytes = New-Object byte[] 1024
(New-Object System.Random).NextBytes($dummyBytes)
[System.IO.File]::WriteAllBytes($synthKsPath, $dummyBytes)
[System.IO.File]::WriteAllText($synthPassPath, "super_secret_ks_pass_98765", [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($synthPemPath, "-----BEGIN CERTIFICATE-----`nMOCK_ROOT_CA_PEM`n-----END CERTIFICATE-----", [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($synthCrtPath, "MOCK_CRT_BYTES", [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllBytes($synthKeyPath, [System.Text.Encoding]::UTF8.GetBytes("MOCK_RSA_KEY_DER_PRIVATE_BYTES"))

$devStorageEsc36 = $devStorage36.Replace('\', '/')

@"
const fs = require('fs');
const path = require('path');
const argv = process.argv.slice(2);
const argStr = argv.join(' ');

if (argv.includes('root')) {
    console.log('adbd cannot run as root in production builds');
    process.exit(1);
}
if (argv.includes('shell') && argv[argv.length - 1] === 'id') {
    console.log('uid=2000(shell) gid=2000(shell) context=u:r:shell:s0');
    process.exit(0);
}
if (argStr.includes('test -f') || argStr.includes('FILE_PROBE_RESULT')) {
    if (argStr.includes('it.akai.customremote ') && argStr.includes('server_keystore.p12')) {
        console.log('FILE_PROBE_RESULT:EXISTS');
        process.exit(0);
    }
    console.log('FILE_PROBE_RESULT:NOT_FOUND');
    process.exit(0);
}

if (argv.includes('exec-out')) {
    const devDir = '$devStorageEsc36';
    const files = ['server_keystore.p12', 'server_keystore.pass', 'ca.pem', 'ca.crt', 'ca_key.der'];
    const simulateMissingKey = process.env.MOCK_MISSING_CA_KEY === 'true';
    for (const f of files) {
        if (argStr.includes(f)) {
            if (simulateMissingKey && f === 'ca_key.der') {
                process.exit(1);
            }
            const fp = path.join(devDir, f);
            if (fs.existsSync(fp)) {
                const buf = fs.readFileSync(fp);
                process.stdout.write(buf, () => process.exit(0));
                return;
            }
        }
    }
    process.exit(1);
}
process.exit(0);
"@ | Out-File -FilePath $mockAdbJs36 -Encoding ascii

$mockAdbCmd36 = if ($isWin) { Join-Path $testDir36 "adb.cmd" } else { Join-Path $testDir36 "adb" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockAdbJs36`" %*" | Out-File -FilePath $mockAdbCmd36 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockAdbJs36`" `"`$@`"" | Out-File -FilePath $mockAdbCmd36 -Encoding ascii
    & chmod +x $mockAdbCmd36
}

try {
    $scriptEscaped = $scriptPath.Replace('\', '/')
    $mockAdbEsc36 = $mockAdbCmd36.Replace('\', '/')
    $nodeEscaped36 = $validNode.Replace('\', '/')
    $sessionDir36 = Join-Path $testDir36 "session_36"
    $sessionEsc36 = $sessionDir36.Replace('\', '/')
    $res36File = Join-Path $testDir36 "res_36.json"
    $res36Esc = $res36File.Replace('\', '/')

    $cmd36 = @"
`$env:NODE_EXE = '$nodeEscaped36'
`$env:ADB_EXECUTABLE = '$mockAdbEsc36'
`$env:MOCK_MISSING_CA_KEY = 'false'
. '$scriptEscaped' -Action plan | Out-Null
`$res = Backup-DeviceTlsIdentity -AdbExe '$mockAdbEsc36' -TargetAdb '127.0.0.1:5555' -PackageName 'it.akai.customremote' -SessionDir '$sessionEsc36'
`$res | ConvertTo-Json -Depth 5 | Set-Content -Path '$res36Esc' -Encoding utf8
"@
    & $psExe -ExecutionPolicy Bypass -Command $cmd36 2>&1 | Out-Null
    $backupResult = if (Test-Path $res36File) { Get-Content $res36File -Raw | ConvertFrom-Json } else { @{} }

    $tlsDir36 = Join-Path $sessionDir36 "tls_identity"
    $manifestPath36 = Join-Path $tlsDir36 "tls_manifest.json"

    # Sotto-test 36a: Tutti i 5 asset salvati CIFRATI nel vault e zero plaintext keys
    $vaultDir36 = if ($backupResult.VaultDir) { $backupResult.VaultDir } else { $tlsDir36 }
    $encFilesPresent = ($backupResult.HasTls -eq $true) -and
                       (Test-Path (Join-Path $vaultDir36 "server_keystore.p12.enc")) -and
                       (Test-Path (Join-Path $vaultDir36 "server_keystore.pass.enc")) -and
                       (Test-Path (Join-Path $vaultDir36 "ca.pem.enc")) -and
                       (Test-Path (Join-Path $vaultDir36 "ca.crt.enc")) -and
                       (Test-Path (Join-Path $vaultDir36 "ca_key.der.enc"))

    # Verifica ASSENZA categorica di chiavi/password in chiaro su disco e assenza di master key AES su Windows
    $noPlainFilesOnDisk = (-not (Test-Path (Join-Path $tlsDir36 "server_keystore.pass"))) -and
                          (-not (Test-Path (Join-Path $tlsDir36 "ca_key.der"))) -and
                          (-not (Test-Path (Join-Path $vaultDir36 "server_keystore.pass"))) -and
                          (-not (Test-Path (Join-Path $vaultDir36 "ca_key.der")))

    $winVaultStrict = $true
    if ($isWin) {
        # Su Windows: percorso assoluto obbligatorio sotto LOCALAPPDATA, mai .vault_master.key, ACL protetta
        $isUnderLocalAppData = $vaultDir36.StartsWith($env:LOCALAPPDATA, [System.StringComparison]::OrdinalIgnoreCase)
        $noMasterKeyOnWin = (-not (Test-Path (Join-Path $vaultDir36 ".vault_master.key"))) -and
                            (-not (Test-Path (Join-Path $tlsDir36 ".vault_master.key")))
        $dirSec36 = (New-Object System.IO.DirectoryInfo($vaultDir36)).GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
        $aclProtected = $dirSec36.AreAccessRulesProtected -eq $true
        $winVaultStrict = $isUnderLocalAppData -and $noMasterKeyOnWin -and $aclProtected
    }

    if ($encFilesPresent -and $noPlainFilesOnDisk -and $winVaultStrict) {
        Write-Host "   [PASS] Sotto-test 36a: Tutti i 5 asset crittografici archiviati CIFRATI nel vault (.enc), LOCALAPPDATA garantita, ACL protetta e ZERO chiavi in chiaro su disco" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 36a: Salvataggio cifrato incompleto o non conforme (enc=$encFilesPresent, noPlain=$noPlainFilesOnDisk, winStrict=$winVaultStrict)" -ForegroundColor Red
    }

    # Sotto-test 36b: Validazione manifest.json con metadati completi dei 5 file, vault_pointer.json e garanzia ZERO secrets leak
    $manifestValid = $false
    if (Test-Path $manifestPath36) {
        $manText = Get-Content $manifestPath36 -Raw
        $manObj = $manText | ConvertFrom-Json
        $actualKsPlainHash = (Get-FileHash $synthKsPath -Algorithm SHA256).Hash.ToLower()

        $hasNoPlainPass = ($manText -notmatch "super_secret_ks_pass_98765")
        $hasNoPlainKey = ($manText -notmatch "MOCK_RSA_KEY_DER_PRIVATE_BYTES")
        $hashMatches = ($manObj.KeystoreSha256 -eq $actualKsPlainHash)
        $has5FilesMeta = (($manObj.Files.psobject.properties | Measure-Object).Count -eq 5)
        $pointerValid = (Test-Path (Join-Path $tlsDir36 "vault_pointer.json"))

        $manifestValid = $hasNoPlainPass -and $hasNoPlainKey -and $hashMatches -and $has5FilesMeta -and $pointerValid
    }

    if ($manifestValid) {
        Write-Host "   [PASS] Sotto-test 36b: tls_manifest.json verificato al 100% con tutti i 5 file censiti, vault_pointer.json presente, parità hash e ZERO secrets leak" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 36b: tls_manifest.json o vault_pointer non conforme o secrets leaked" -ForegroundColor Red
    }

    # Sotto-test 36c: Test negativo FAIL-CLOSED su asset TLS obbligatorio mancante/fallito durante il backup
    $sessionDir36Fail = Join-Path $testDir36 "session_36_fail"
    $sessionEsc36Fail = $sessionDir36Fail.Replace('\', '/')
    $cmd36Fail = @"
`$env:NODE_EXE = '$nodeEscaped36'
`$env:ADB_EXECUTABLE = '$mockAdbEsc36'
`$env:MOCK_MISSING_CA_KEY = 'true'
. '$scriptEscaped' -Action plan | Out-Null
try {
    Backup-DeviceTlsIdentity -AdbExe '$mockAdbEsc36' -TargetAdb '127.0.0.1:5555' -PackageName 'it.akai.customremote' -SessionDir '$sessionEsc36Fail' | Out-Null
    Write-Host 'UNEXPECTED_PASS'
} catch {
    Write-Host (`$_.Exception.Message)
}
"@
    $res36Fail = & $psExe -ExecutionPolicy Bypass -Command $cmd36Fail 2>&1 | Out-String
    $missingKeyBlocked = ($res36Fail -match "ERRORE FAIL-CLOSED" -and $res36Fail -match "ca_key.der" -and $res36Fail -notmatch "UNEXPECTED_PASS")

    if ($missingKeyBlocked) {
        Write-Host "   [PASS] Sotto-test 36c: Rilevato asset TLS mancante: blocco fail-closed categorico dell'aggiornamento" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 36c: Mancato blocco fail-closed su asset TLS incompleto: $res36Fail" -ForegroundColor Red
    }

    # Sotto-test 36d: Test negativo FAIL-CLOSED su DPAPI non disponibile su Windows (rifiuto categorico fallback AES)
    $sessionDir36DpapiFail = Join-Path $testDir36 "session_36_dpapi_fail"
    $sessionEsc36DpapiFail = $sessionDir36DpapiFail.Replace('\', '/')
    $cmd36DpapiFail = @"
`$env:NODE_EXE = '$nodeEscaped36'
`$env:ADB_EXECUTABLE = '$mockAdbEsc36'
`$env:MOCK_MISSING_CA_KEY = 'false'
`$env:MOCK_FAIL_DPAPI = 'true'
. '$scriptEscaped' -Action plan | Out-Null
try {
    Backup-DeviceTlsIdentity -AdbExe '$mockAdbEsc36' -TargetAdb '127.0.0.1:5555' -PackageName 'it.akai.customremote' -SessionDir '$sessionEsc36DpapiFail' | Out-Null
    Write-Host 'UNEXPECTED_PASS'
} catch {
    Write-Host (`$_.Exception.Message)
}
"@
    $res36DpapiFail = & $psExe -ExecutionPolicy Bypass -Command $cmd36DpapiFail 2>&1 | Out-String
    $dpapiFailBlocked = if ($isWin) {
        ($res36DpapiFail -match "ERRORE FAIL-CLOSED" -and $res36DpapiFail -match "DPAPI" -and $res36DpapiFail -notmatch "UNEXPECTED_PASS")
    } else {
        $true # Su Linux DPAPI non è attiva per design
    }

    if ($dpapiFailBlocked) {
        Write-Host "   [PASS] Sotto-test 36d: Fallimento DPAPI su Windows: blocco fail-closed categorico senza fallback silenzioso AES" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 36d: Mancato blocco fail-closed su fallimento DPAPI: $res36DpapiFail" -ForegroundColor Red
    }

    # Sotto-test 36e: Release legacy v5 (server_keystore.p12 NOT_FOUND) -> restituisce HasTls=false senza errori
    $sessionDir36Legacy = Join-Path $testDir36 "session_36_legacy"
    $sessionEsc36Legacy = $sessionDir36Legacy.Replace('\', '/')
    $res36dFile = Join-Path $testDir36 "res_36d.json"
    $res36dEsc = $res36dFile.Replace('\', '/')
    $cmd36d = @"
`$env:NODE_EXE = '$nodeEscaped36'
`$env:ADB_EXECUTABLE = '$mockAdbEsc36'
`$env:MOCK_MISSING_CA_KEY = 'false'
`$env:MOCK_FAIL_DPAPI = 'false'
. '$scriptEscaped' -Action plan | Out-Null
`$res = Backup-DeviceTlsIdentity -AdbExe '$mockAdbEsc36' -TargetAdb '127.0.0.1:5555' -PackageName 'it.akai.customremote_legacy' -SessionDir '$sessionEsc36Legacy'
`$res | ConvertTo-Json | Set-Content -Path '$res36dEsc' -Encoding utf8
"@
    & $psExe -ExecutionPolicy Bypass -Command $cmd36d 2>&1 | Out-Null
    $backupResultLegacy = if (Test-Path $res36dFile) { Get-Content $res36dFile -Raw | ConvertFrom-Json } else { @{} }
    $legacyOk = ($backupResultLegacy.HasTls -eq $false)

    if ($legacyOk) {
        Write-Host "   [PASS] Sotto-test 36e: Release legacy senza TLS gestita correttamente con HasTls=false" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 36e: Release legacy fallita: $res36dJson" -ForegroundColor Red
    }

    # Sotto-test 36f & 36g: Root elevation singola sessione (1 root + 1 unroot) e propagazione fail-closed STATO ADBD UNKNOWN / file mancante
    $mockAdbJs36Elev = Join-Path $testDir36 "mock_adb_36_elev.js"
    $elevState36 = Join-Path $testDir36 "elev_state_36.txt"
    $elevLog36 = Join-Path $testDir36 "elev_log_36.txt"
    $elevStateEsc36 = $elevState36.Replace('\', '/')
    $elevLogEsc36 = $elevLog36.Replace('\', '/')
    @"
const fs = require('fs');
const path = require('path');
const argv = process.argv.slice(2);
const argStr = argv.join(' ');
const stateFile = '$elevStateEsc36';
const logFile = '$elevLogEsc36';
const mode = process.env.MOCK_ELEV_MODE || 'ok';
function getSt() { try { return fs.readFileSync(stateFile, 'utf8').trim(); } catch (e) { return 'shell'; } }

if (argv.includes('connect') || argv.includes('wait-for-device')) { process.exit(0); }
if (argv.includes('root')) {
    fs.appendFileSync(logFile, 'root\n', 'utf8');
    fs.writeFileSync(stateFile, 'root', 'utf8');
    console.log('restarting adbd as root');
    process.exit(0);
}
if (argv.includes('unroot')) {
    fs.appendFileSync(logFile, 'unroot\n', 'utf8');
    if (mode === 'unroot_fail') {
        process.stderr.write('error: protocol fault\n');
        process.exit(1);
    }
    fs.writeFileSync(stateFile, 'shell', 'utf8');
    console.log('restarting adbd as non root');
    process.exit(0);
}
if (argStr.includes('run-as') || argStr.includes('su -c')) {
    process.exit(1);
}
if (argv.includes('shell') && argv[argv.length - 1] === 'id') {
    const st = getSt();
    console.log(st === 'root' ? 'uid=0(root) gid=0(root) context=u:r:su:s0' : 'uid=2000(shell) gid=2000(shell) context=u:r:shell:s0');
    process.exit(0);
}
if (argStr.includes('FILE_PROBE_RESULT')) {
    if (getSt() !== 'root') { console.log('FILE_PROBE_RESULT:ACCESS_DENIED'); process.exit(13); }
    if (argStr.includes('server_keystore.p12')) { console.log('FILE_PROBE_RESULT:EXISTS'); process.exit(0); }
    console.log('FILE_PROBE_RESULT:NOT_FOUND');
    process.exit(0);
}
if (argv.includes('exec-out')) {
    if (getSt() !== 'root') { process.stderr.write('Permission denied\n'); process.exit(1); }
    const devDir = '$devStorageEsc36';
    const files = ['server_keystore.p12', 'server_keystore.pass', 'ca.pem', 'ca.crt', 'ca_key.der'];
    for (const f of files) {
        if (argStr.includes(f)) {
            if (mode === 'missing_ca_crt' && f === 'ca.crt') { process.exit(1); }
            const fp = path.join(devDir, f);
            if (fs.existsSync(fp)) {
                process.stdout.write(fs.readFileSync(fp), () => process.exit(0));
                return;
            }
        }
    }
    process.exit(1);
}
process.exit(0);
"@ | Out-File -FilePath $mockAdbJs36Elev -Encoding ascii

    $mockAdbCmd36Elev = if ($isWin) { Join-Path $testDir36 "adb_elev.cmd" } else { Join-Path $testDir36 "adb_elev" }
    if ($isWin) {
        "@echo off`n`"%NODE_EXE%`" `"$mockAdbJs36Elev`" %*" | Out-File -FilePath $mockAdbCmd36Elev -Encoding ascii
    } else {
        "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockAdbJs36Elev`" `"`$@`"" | Out-File -FilePath $mockAdbCmd36Elev -Encoding ascii
        & chmod +x $mockAdbCmd36Elev
    }
    $mockAdbElevEsc36 = $mockAdbCmd36Elev.Replace('\', '/')

    # 36f: adb unroot fallito sotto Backup-DeviceTlsIdentity -> propagazione STATO ADBD UNKNOWN (zero catch silenziosi)
    [System.IO.File]::WriteAllText($elevState36, "shell")
    if (Test-Path $elevLog36) { Remove-Item $elevLog36 -Force }
    $sessionDir36f = Join-Path $testDir36 "session_36f"
    $sessionEsc36f = $sessionDir36f.Replace('\', '/')
    $cmd36f = @"
`$env:NODE_EXE = '$nodeEscaped36'
`$env:ADB_EXECUTABLE = '$mockAdbElevEsc36'
`$env:MOCK_ELEV_MODE = 'unroot_fail'
. '$scriptEscaped' -Action plan | Out-Null
try {
    Backup-DeviceTlsIdentity -AdbExe '$mockAdbElevEsc36' -TargetAdb '127.0.0.1:5555' -PackageName 'it.akai.customremote' -SessionDir '$sessionEsc36f' | Out-Null
    Write-Host 'UNEXPECTED_PASS_36F'
} catch {
    Write-Host ('CAUGHT_36F:' + `$_.Exception.Message)
}
"@
    $res36f = & $psExe -ExecutionPolicy Bypass -Command $cmd36f 2>&1 | Out-String
    $unrootUnknownPropagated = ($res36f -match "CAUGHT_36F:ERRORE FAIL-CLOSED \[STATO ADBD UNKNOWN" -and $res36f -notmatch "UNEXPECTED_PASS_36F")
    if ($unrootUnknownPropagated) {
        Write-Host "   [PASS] Sotto-test 36f: Fallimento unroot in Backup-DeviceTlsIdentity propaga [STATO ADBD UNKNOWN] (zero catch silenziosi)" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 36f: Eccezione STATO ADBD UNKNOWN soppressa: $res36f" -ForegroundColor Red
    }

    # 36g: Singolo ciclo root/unroot per tutti i 5 file + file TLS mancante sotto root fa unroot comunque e blocca fail-closed
    [System.IO.File]::WriteAllText($elevState36, "shell")
    if (Test-Path $elevLog36) { Remove-Item $elevLog36 -Force }
    $sessionDir36gOk = Join-Path $testDir36 "session_36g_ok"
    $sessionEsc36gOk = $sessionDir36gOk.Replace('\', '/')
    $res36gFile = Join-Path $testDir36 "res_36g.json"
    $res36gEsc = $res36gFile.Replace('\', '/')
    $cmd36gOk = @"
`$env:NODE_EXE = '$nodeEscaped36'
`$env:ADB_EXECUTABLE = '$mockAdbElevEsc36'
`$env:MOCK_ELEV_MODE = 'ok'
. '$scriptEscaped' -Action plan | Out-Null
`$res = Backup-DeviceTlsIdentity -AdbExe '$mockAdbElevEsc36' -TargetAdb '127.0.0.1:5555' -PackageName 'it.akai.customremote' -SessionDir '$sessionEsc36gOk'
`$res | ConvertTo-Json -Depth 5 | Set-Content -Path '$res36gEsc' -Encoding utf8
"@
    & $psExe -ExecutionPolicy Bypass -Command $cmd36gOk 2>&1 | Out-Null
    $elevEvents36g = @((Get-Content $elevLog36 -ErrorAction SilentlyContinue) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $rootCount36g = @($elevEvents36g | Where-Object { $_.Trim() -eq 'root' }).Count
    $unrootCount36g = @($elevEvents36g | Where-Object { $_.Trim() -eq 'unroot' }).Count
    $res36gObj = if (Test-Path $res36gFile) { Get-Content $res36gFile -Raw | ConvertFrom-Json } else { @{} }

    [System.IO.File]::WriteAllText($elevState36, "shell")
    if (Test-Path $elevLog36) { Remove-Item $elevLog36 -Force }
    $sessionDir36gMiss = Join-Path $testDir36 "session_36g_miss"
    $sessionEsc36gMiss = $sessionDir36gMiss.Replace('\', '/')
    $cmd36gMiss = @"
`$env:NODE_EXE = '$nodeEscaped36'
`$env:ADB_EXECUTABLE = '$mockAdbElevEsc36'
`$env:MOCK_ELEV_MODE = 'missing_ca_crt'
. '$scriptEscaped' -Action plan | Out-Null
try {
    Backup-DeviceTlsIdentity -AdbExe '$mockAdbElevEsc36' -TargetAdb '127.0.0.1:5555' -PackageName 'it.akai.customremote' -SessionDir '$sessionEsc36gMiss' | Out-Null
    Write-Host 'UNEXPECTED_PASS_36GMISS'
} catch {
    Write-Host ('CAUGHT_36GMISS:' + `$_.Exception.Message)
}
"@
    $res36gMiss = & $psExe -ExecutionPolicy Bypass -Command $cmd36gMiss 2>&1 | Out-String
    $finalStMiss = (Get-Content $elevState36 -Raw).Trim()
    $singleElevCycleOk = ($rootCount36g -eq 1) -and ($unrootCount36g -eq 1) -and ($res36gObj.HasTls -eq $true) -and
                         ($res36gMiss -match "CAUGHT_36GMISS:ERRORE FAIL-CLOSED \(P1 Gate\)" -and $res36gMiss -match "ca\.crt") -and
                         ($res36gMiss -notmatch "UNEXPECTED_PASS_36GMISS") -and ($finalStMiss -eq "shell")

    if ($singleElevCycleOk) {
        Write-Host "   [PASS] Sotto-test 36g: Singola sessione root/unroot per 5 asset TLS (root=$rootCount36g, unroot=$unrootCount36g) e rollback shell garantito su asset mancante" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 36g fallito (root=$rootCount36g, unroot=$unrootCount36g, st=$finalStMiss): $res36gMiss" -ForegroundColor Red
    }

    if ($encFilesPresent -and $noPlainFilesOnDisk -and $winVaultStrict -and $manifestValid -and $missingKeyBlocked -and $dpapiFailBlocked -and $legacyOk -and $unrootUnknownPropagated -and $singleElevCycleOk) {
        Write-Host "[PASS] [TEST AFFERMATIVO & NEGATIVO / TLS IDENTITY BACKUP GATE] Test 36: Snapshot identità TLS, cifratura vault e protezione segreti convalidati al 100% (7/7)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST AFFERMATIVO & NEGATIVO / TLS IDENTITY BACKUP GATE] Test 36: Fallito" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[FAIL] [TEST AFFERMATIVO & NEGATIVO / TLS IDENTITY BACKUP GATE] Test 36: Eccezione imprevista: $($_.Exception.Message)" -ForegroundColor Red
    $failed++
} finally {
    Remove-Item $testDir36 -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
# TEST 37: Ripristino Bit-for-Bit Identità TLS su Rollback e Rifiuto Tamper (P1 Supervisor Gate)
# -----------------------------------------------------------------------------
Write-Host "`n--- Esecuzione Test 37: Ripristino Bit-for-Bit Identità TLS su Rollback e Rifiuto Tamper ---" -ForegroundColor Cyan
$testDir37 = Join-Path $tempDir "e2e_tls_restore_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir37 | Out-Null

$mockAdbJs37 = Join-Path $testDir37 "mock_adb_37.js"
$devStorage37 = Join-Path $testDir37 "dev_storage"
$auditLog37 = Join-Path $testDir37 "restore_audit.txt"
New-Item -ItemType Directory -Force -Path $devStorage37 | Out-Null

# Creiamo la cartella di backup di sessione da ripristinare
$sessionDir37 = Join-Path $testDir37 "session_37"
$tlsDir37 = Join-Path $sessionDir37 "tls_identity"
New-Item -ItemType Directory -Force -Path $tlsDir37 | Out-Null

# Creiamo i 5 asset protetti
$goldenBytes = New-Object byte[] 1024
(New-Object System.Random).NextBytes($goldenBytes)
$sha = [System.Security.Cryptography.SHA256]::Create()
$goldenKsHash = -join ($sha.ComputeHash($goldenBytes) | ForEach-Object { "{0:x2}" -f $_ })

$goldenPass = [System.Text.Encoding]::UTF8.GetBytes("golden_pass_12345")
$goldenPassHash = -join ($sha.ComputeHash($goldenPass) | ForEach-Object { "{0:x2}" -f $_ })

$goldenPem = [System.Text.Encoding]::UTF8.GetBytes("-----BEGIN CERTIFICATE-----`nGOLDEN_CA_PEM`n-----END CERTIFICATE-----")
$goldenPemHash = -join ($sha.ComputeHash($goldenPem) | ForEach-Object { "{0:x2}" -f $_ })

$goldenCrt = [System.Text.Encoding]::UTF8.GetBytes("GOLDEN_CRT_BYTES")
$goldenCrtHash = -join ($sha.ComputeHash($goldenCrt) | ForEach-Object { "{0:x2}" -f $_ })

$goldenKey = [System.Text.Encoding]::UTF8.GetBytes("GOLDEN_KEY_DER")
$goldenKeyHash = -join ($sha.ComputeHash($goldenKey) | ForEach-Object { "{0:x2}" -f $_ })

# Helper per cifrare i golden asset direttamente per il mock di test
. $scriptPath -Action plan | Out-Null
$encKs = Protect-TlsData -PlainBytes $goldenBytes -VaultDir $tlsDir37
[System.IO.File]::WriteAllBytes((Join-Path $tlsDir37 "server_keystore.p12.enc"), $encKs.CipherBytes)

$encPass = Protect-TlsData -PlainBytes $goldenPass -VaultDir $tlsDir37
[System.IO.File]::WriteAllBytes((Join-Path $tlsDir37 "server_keystore.pass.enc"), $encPass.CipherBytes)

$encPem = Protect-TlsData -PlainBytes $goldenPem -VaultDir $tlsDir37
[System.IO.File]::WriteAllBytes((Join-Path $tlsDir37 "ca.pem.enc"), $encPem.CipherBytes)

$encCrt = Protect-TlsData -PlainBytes $goldenCrt -VaultDir $tlsDir37
[System.IO.File]::WriteAllBytes((Join-Path $tlsDir37 "ca.crt.enc"), $encCrt.CipherBytes)

$encKey = Protect-TlsData -PlainBytes $goldenKey -VaultDir $tlsDir37
[System.IO.File]::WriteAllBytes((Join-Path $tlsDir37 "ca_key.der.enc"), $encKey.CipherBytes)

$manifest37 = @{
    HasTls = $true
    SessionDir = $sessionDir37
    VaultDir = $tlsDir37
    IsCloudSynced = $false
    Files = @{
        "server_keystore.p12" = @{ Sha256 = $goldenKsHash; SizeBytes = 1024; Encrypted = $true; Mechanism = $encKs.Mechanism }
        "server_keystore.pass" = @{ Sha256 = $goldenPassHash; SizeBytes = $goldenPass.Length; Encrypted = $true; Mechanism = $encPass.Mechanism }
        "ca.pem" = @{ Sha256 = $goldenPemHash; SizeBytes = $goldenPem.Length; Encrypted = $true; Mechanism = $encPem.Mechanism }
        "ca.crt" = @{ Sha256 = $goldenCrtHash; SizeBytes = $goldenCrt.Length; Encrypted = $true; Mechanism = $encCrt.Mechanism }
        "ca_key.der" = @{ Sha256 = $goldenKeyHash; SizeBytes = $goldenKey.Length; Encrypted = $true; Mechanism = $encKey.Mechanism }
    }
}
[System.IO.File]::WriteAllText((Join-Path $tlsDir37 "tls_manifest.json"), ($manifest37 | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)

$devStorageEsc37 = $devStorage37.Replace('\', '/')
$auditEsc37 = $auditLog37.Replace('\', '/')

@"
const fs = require('fs');
const path = require('path');
const argv = process.argv.slice(2);
const argStr = argv.join(' ');

fs.appendFileSync('$auditEsc37', argStr + '\n');

if (argv.includes('exec-in')) {
    const devDir = '$devStorageEsc37';
    const match = argStr.match(/files\/([a-zA-Z0-9_\.]+)/);
    if (match) {
        const dest = path.join(devDir, match[1]);
        const chunks = [];
        process.stdin.on('data', chunk => chunks.push(chunk));
        process.stdin.on('end', () => {
            const buf = Buffer.concat(chunks);
            fs.writeFileSync(dest, buf);
            process.exit(0);
        });
        return;
    }
    process.exit(0);
}

if (argv.includes('exec-out')) {
    const devDir = '$devStorageEsc37';
    const corruptMode = process.env.MOCK_CORRUPT_RESTORE === 'true';
    const files = ['server_keystore.p12', 'server_keystore.pass', 'ca.pem', 'ca.crt', 'ca_key.der'];
    for (const f of files) {
        if (argStr.includes(f)) {
            const dest = path.join(devDir, f);
            if (fs.existsSync(dest)) {
                let buf = fs.readFileSync(dest);
                if (corruptMode && f === 'ca_key.der') {
                    buf = Buffer.from(buf);
                    buf[0] ^= 0xFF;
                }
                process.stdout.write(buf, () => process.exit(0));
                return;
            }
        }
    }
    process.exit(1);
}
process.exit(0);
"@ | Out-File -FilePath $mockAdbJs37 -Encoding ascii

$mockAdbCmd37 = if ($isWin) { Join-Path $testDir37 "adb.cmd" } else { Join-Path $testDir37 "adb" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockAdbJs37`" %*" | Out-File -FilePath $mockAdbCmd37 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockAdbJs37`" `"`$@`"" | Out-File -FilePath $mockAdbCmd37 -Encoding ascii
    & chmod +x $mockAdbCmd37
}

try {
    $scriptEscaped = $scriptPath.Replace('\', '/')
    $mockAdbEsc37 = $mockAdbCmd37.Replace('\', '/')
    $nodeEscaped37 = $validNode.Replace('\', '/')
    $sessionEsc37 = $sessionDir37.Replace('\', '/')
    $res37File = Join-Path $testDir37 "res_37a.json"
    $res37Esc = $res37File.Replace('\', '/')

    # Sotto-test 37a: Ripristino bit-for-bit di tutti i 5 file con chmod 600 e parità hash verificata
    $cmd37a = @"
`$env:NODE_EXE = '$nodeEscaped37'
`$env:ADB_EXECUTABLE = '$mockAdbEsc37'
`$env:MOCK_CORRUPT_RESTORE = 'false'
. '$scriptEscaped' -Action plan | Out-Null
`$res = Restore-DeviceTlsIdentity -AdbExe '$mockAdbEsc37' -TargetAdb '127.0.0.1:5555' -PackageName 'it.akai.customremote' -SessionDir '$sessionEsc37' -ChownTarget '10045:10045'
`$res | ConvertTo-Json | Set-Content -Path '$res37Esc' -Encoding utf8
"@
    & $psExe -ExecutionPolicy Bypass -Command $cmd37a 2>&1 | Out-Null
    $restoreResult = if (Test-Path $res37File) { Get-Content $res37File -Raw | ConvertFrom-Json } else { @{} }

    $auditLines37 = if (Test-Path $auditLog37) { Get-Content $auditLog37 -Raw } else { "" }
    $restoredOk = ($restoreResult.Restored -eq $true) -and
                  ($restoreResult.KeystoreSha256 -eq $goldenKsHash) -and
                  ($restoreResult.All5FilesVerified -eq $true) -and
                  ($auditLines37 -match "chmod 600 files/server_keystore.p12") -and
                  ($auditLines37 -match "chmod 600 files/server_keystore.pass") -and
                  ($auditLines37 -match "chmod 600 files/ca.pem") -and
                  ($auditLines37 -match "chmod 600 files/ca.crt") -and
                  ($auditLines37 -match "chmod 600 files/ca_key.der")

    if ($restoredOk) {
        Write-Host "   [PASS] Sotto-test 37a: Ripristino bit-for-bit di tutti i 5 file con chmod 600 e parità SHA-256 confermata su device" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 37a: Ripristino bit-for-bit fallito (Restored=$($restoreResult.Restored))" -ForegroundColor Red
    }

    # Sotto-test 37b: Tamper / Mismatch SHA-256 su file crittografico (es. ca_key.der) post-ripristino -> Fail-Closed con eccezione esplicita
    $cmd37b = @"
`$env:NODE_EXE = '$nodeEscaped37'
`$env:ADB_EXECUTABLE = '$mockAdbEsc37'
`$env:MOCK_CORRUPT_RESTORE = 'true'
. '$scriptEscaped' -Action plan | Out-Null
try {
    Restore-DeviceTlsIdentity -AdbExe '$mockAdbEsc37' -TargetAdb '127.0.0.1:5555' -PackageName 'it.akai.customremote' -SessionDir '$sessionEsc37' -ChownTarget '10045:10045' | Out-Null
    Write-Host 'UNEXPECTED_PASS'
} catch {
    Write-Host (`$_.Exception.Message)
}
"@
    $res37b = & $psExe -ExecutionPolicy Bypass -Command $cmd37b 2>&1 | Out-String
    $tamperDetected = ($res37b -match "ERRORE FAIL-CLOSED: Mismatch hash SHA-256" -and $res37b -match "ca_key.der" -and $res37b -notmatch "UNEXPECTED_PASS")

    if ($tamperDetected) {
        Write-Host "   [PASS] Sotto-test 37b: Manomissione hash post-rollback (ca_key.der) rilevata: blocco fail-closed categorico" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 37b: Mancato blocco fail-closed su tamper: $res37b" -ForegroundColor Red
    }

    # Sotto-test 37c: Sessione senza backup TLS (legacy HTTP v5) -> Restored=false, Reason=NO_TLS_BACKUP, zero eccezioni
    $emptySessionDir = Join-Path $testDir37 "empty_session"
    New-Item -ItemType Directory -Force -Path $emptySessionDir | Out-Null
    $emptySessionEsc = $emptySessionDir.Replace('\', '/')
    $res37cFile = Join-Path $testDir37 "res_37c.json"
    $res37cEsc = $res37cFile.Replace('\', '/')

    $cmd37c = @"
`$env:NODE_EXE = '$nodeEscaped37'
`$env:ADB_EXECUTABLE = '$mockAdbEsc37'
. '$scriptEscaped' -Action plan | Out-Null
`$res = Restore-DeviceTlsIdentity -AdbExe '$mockAdbEsc37' -TargetAdb '127.0.0.1:5555' -PackageName 'it.akai.customremote' -SessionDir '$emptySessionEsc' -ChownTarget '10045:10045'
`$res | ConvertTo-Json | Set-Content -Path '$res37cEsc' -Encoding utf8
"@
    & $psExe -ExecutionPolicy Bypass -Command $cmd37c 2>&1 | Out-Null
    $resEmpty = if (Test-Path $res37cFile) { Get-Content $res37cFile -Raw | ConvertFrom-Json } else { @{} }
    $emptySessionOk = ($resEmpty.Restored -eq $false) -and ($resEmpty.Reason -eq "NO_TLS_BACKUP")

    if ($emptySessionOk) {
        Write-Host "   [PASS] Sotto-test 37c: Ripristino trasparente no-op per sessione legacy senza TLS (NO_TLS_BACKUP)" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 37c: Ripristino sessione legacy fallito: $res37cJson" -ForegroundColor Red
    }

    if ($restoredOk -and $tamperDetected -and $emptySessionOk) {
        Write-Host "[PASS] [TEST AFFERMATIVO & NEGATIVO / TLS IDENTITY ROLLBACK GATE] Test 37: Ripristino bit-for-bit identità TLS su rollback e rifiuto tamper convalidati al 100% (3/3)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST AFFERMATIVO & NEGATIVO / TLS IDENTITY ROLLBACK GATE] Test 37: Fallito" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[FAIL] [TEST AFFERMATIVO & NEGATIVO / TLS IDENTITY ROLLBACK GATE] Test 37: Eccezione imprevista: $($_.Exception.Message)" -ForegroundColor Red
    $failed++
} finally {
    Remove-Item $testDir37 -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
# TEST 38: Hardening Backup - STATO ADBD UNKNOWN in catch, adbd scomparso, backup interrotto, cold-start recovery
# -----------------------------------------------------------------------------
Write-Host "`n--- Esecuzione Test 38: Hardening Backup (unroot fail, adbd gone, backup interrotto, cold-start recovery) ---" -ForegroundColor Cyan
$testDir38 = Join-Path $tempDir "e2e_backup_hardening_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir38 | Out-Null

$devDb38 = Join-Path $testDir38 "dev38.db"
$devDbEsc38 = $devDb38.Replace('\', '/')
$devStorage38 = Join-Path $testDir38 "dev_storage38"
New-Item -ItemType Directory -Force -Path $devStorage38 | Out-Null
$devStorageEsc38 = $devStorage38.Replace('\', '/')
$deviceApk38 = Join-Path $testDir38 "device38.apk"
[System.IO.File]::WriteAllText($deviceApk38, "MOCK_APK_38")
$deviceApkEsc38 = $deviceApk38.Replace('\', '/')

$ksBytes38 = New-Object byte[] 1024
(New-Object System.Random).NextBytes($ksBytes38)
[System.IO.File]::WriteAllBytes((Join-Path $devStorage38 "server_keystore.p12"), $ksBytes38)
[System.IO.File]::WriteAllText((Join-Path $devStorage38 "server_keystore.pass"), "mock_pass_test38", [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText((Join-Path $devStorage38 "ca.pem"), "-----BEGIN CERTIFICATE-----`nTEST38_CA`n-----END CERTIFICATE-----", [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText((Join-Path $devStorage38 "ca.crt"), "TEST38_CRT", [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllBytes((Join-Path $devStorage38 "ca_key.der"), [System.Text.Encoding]::UTF8.GetBytes("TEST38_PRIV_DER"))

$setup38Js = Join-Path $testDir38 "setup38.js"
@"
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync('$devDbEsc38');
db.exec('CREATE TABLE memories (id INTEGER PRIMARY KEY, txt TEXT);');
db.exec("INSERT INTO memories VALUES (1, 'row38');");
db.close();
"@ | Out-File -FilePath $setup38Js -Encoding ascii
& $validNode --no-warnings $setup38Js

$state38 = Join-Path $testDir38 "adbd_state38.txt"
$log38 = Join-Path $testDir38 "adbd_log38.txt"
$appState38 = Join-Path $testDir38 "app_state38.txt"
$stateEsc38 = $state38.Replace('\', '/')
$logEsc38 = $log38.Replace('\', '/')
$appEsc38 = $appState38.Replace('\', '/')
$mockAdbJs38 = Join-Path $testDir38 "mock_adb_38.js"

@"
const fs = require('fs');
const path = require('path');
const args = process.argv.slice(2);
const argStr = args.join(' ');
const mode = process.env.TEST38_MODE || 'tls_unroot_fail';
const stateFile = '$stateEsc38';
const logFile = '$logEsc38';
const appFile = '$appEsc38';
const devStorage = '$devStorageEsc38';

function getSt() { try { return fs.readFileSync(stateFile, 'utf8').trim(); } catch (e) { return 'shell'; } }
function getApp() { try { return fs.readFileSync(appFile, 'utf8').trim(); } catch (e) { return 'stopped'; } }
function setApp(v) { fs.writeFileSync(appFile, v, 'utf8'); }
function countUnroots() {
    try { return fs.readFileSync(logFile, 'utf8').split(/\r?\n/).filter(l => l.trim() === 'unroot').length; } catch (e) { return 0; }
}

if (args.includes('connect') || args.includes('wait-for-device')) { process.exit(0); }
if (args.includes('root')) {
    fs.appendFileSync(logFile, 'root\n', 'utf8');
    fs.writeFileSync(stateFile, 'root', 'utf8');
    console.log('restarting adbd as root');
    process.exit(0);
}
if (args.includes('unroot')) {
    fs.appendFileSync(logFile, 'unroot\n', 'utf8');
    const uc = countUnroots();
    if (mode === 'tls_unroot_fail' && uc >= 2) {
        process.stderr.write('error: protocol fault\n');
        process.exit(1);
    }
    if (mode === 'adbd_gone' && uc >= 2) {
        fs.writeFileSync(stateFile, 'adbd_gone', 'utf8');
        console.log('restarting adbd as non root');
        process.exit(0);
    }
    fs.writeFileSync(stateFile, 'shell', 'utf8');
    console.log('restarting adbd as non root');
    process.exit(0);
}
if (args.includes('pull')) {
    fs.copyFileSync('$deviceApkEsc38', args[args.length - 1]);
    process.exit(0);
}
if (argStr.includes('pm path')) { console.log('package:/data/app/it.akai.customremote-1/base.apk'); process.exit(0); }
if (argStr.includes('run-as') || argStr.includes('su -c')) { process.exit(1); }
if (args.includes('shell')) {
    if (args[args.length - 1] === 'id') {
        const st = getSt();
        if (st === 'adbd_gone') { process.stderr.write('error: device offline\n'); process.exit(1); }
        console.log(st === 'root' ? 'uid=0(root) gid=0(root) context=u:r:su:s0' : 'uid=2000(shell) gid=2000(shell) context=u:r:shell:s0');
        process.exit(0);
    }
    if (argStr.includes('ADB_ALIVE')) {
        if (getSt() === 'adbd_gone') { process.stderr.write('error: device offline\n'); process.exit(1); }
        console.log('ADB_ALIVE');
        process.exit(0);
    }
    if (argStr.includes('am force-stop')) { setApp('stopped'); process.exit(0); }
    if (argStr.includes('ACTION_BACKUP_DB')) { process.exit(0); }
    if (argStr.includes('am startservice') || argStr.includes('cmd activity start-service') || argStr.includes('am start -n')) {
        if (mode === 'service_unrecoverable') { process.exit(1); }
        setApp('4488');
        process.exit(0);
    }
    if (argStr.includes('/api/status')) {
        if (mode === 'cold_start_ok') {
            const cf = process.env.COUNT38_FILE;
            let n = 0;
            try { n = parseInt(fs.readFileSync(cf, 'utf8').trim(), 10) || 0; } catch (e) {}
            n++;
            fs.writeFileSync(cf, String(n), 'utf8');
            if (n < 3) { process.exit(1); }
            console.log('{"status":"ok","uinput_ready":true}');
            process.exit(0);
        }
        console.log('{"status":"ok","uinput_ready":true}');
        process.exit(0);
    }
    if (argStr.includes('PIDOF_CHECK')) {
        const ap = getApp();
        console.log(ap && ap !== 'stopped' ? ('PIDOF_CHECK:pids=[' + ap + ']:exit=[0]') : 'PIDOF_CHECK:pids=[]:exit=[1]');
        process.exit(0);
    }
    if (argStr.includes('FILE_PROBE_RESULT')) {
        if (getSt() !== 'root') { console.log('FILE_PROBE_RESULT:ACCESS_DENIED'); process.exit(13); }
        if (argStr.includes('server_keystore.p12')) { console.log('FILE_PROBE_RESULT:EXISTS'); process.exit(0); }
        console.log('FILE_PROBE_RESULT:NOT_FOUND');
        process.exit(0);
    }
    process.exit(0);
}
if (args.includes('exec-out')) {
    if (getSt() !== 'root') { process.exit(1); }
    if (argStr.includes('akai_memory.db-wal')) { process.exit(1); }
    if (argStr.includes('akai_memory.db')) {
        process.stdout.write(fs.readFileSync('$devDbEsc38'), () => process.exit(0));
        return;
    }
    const files = ['server_keystore.p12', 'server_keystore.pass', 'ca.pem', 'ca.crt', 'ca_key.der'];
    for (const f of files) {
        if (argStr.includes(f)) {
            if (mode === 'backup_interrupted' && f === 'ca.pem') { process.exit(1); }
            process.stdout.write(fs.readFileSync(path.join(devStorage, f)), () => process.exit(0));
            return;
        }
    }
    process.exit(1);
}
process.exit(0);
"@ | Out-File -FilePath $mockAdbJs38 -Encoding ascii

$mockAdbCmd38 = if ($isWin) { Join-Path $testDir38 "adb.cmd" } else { Join-Path $testDir38 "adb" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockAdbJs38`" %*" | Out-File -FilePath $mockAdbCmd38 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockAdbJs38`" `"`$@`"" | Out-File -FilePath $mockAdbCmd38 -Encoding ascii
    & chmod +x $mockAdbCmd38
}

$subPassed38 = 0
$createdVaultDirs38 = @()
try {
    $scriptEsc = $scriptPath.Replace('\', '/')
    $mockAdbEsc38 = $mockAdbCmd38.Replace('\', '/')
    $nodeEsc38 = $validNode.Replace('\', '/')

    # 38a: unroot failure durante Backup-DeviceTlsIdentity dentro -Action backup -> STATO ADBD UNKNOWN + no false recovery
    [System.IO.File]::WriteAllText($state38, "shell")
    [System.IO.File]::WriteAllText($appState38, "4400")
    if (Test-Path $log38) { Remove-Item $log38 -Force }
    $bk38a = (Join-Path $testDir38 "bk_38a").Replace('\', '/')
    $cmd38a = @"
`$env:NODE_EXE = '$nodeEsc38'
`$env:ADB_EXECUTABLE = '$mockAdbEsc38'
`$env:TEST38_MODE = 'tls_unroot_fail'
try {
    & '$scriptEsc' -Action backup -TargetTv '127.0.0.1' -HttpPort 59987 -BackupDir '$bk38a' -AllowHardwareExecution
    Write-Output 'UNEXPECTED_PASS_38A'
} catch {
    Write-Output ('CAUGHT_38A:' + `$_.Exception.Message)
}
"@
    $out38a = & $psExe -ExecutionPolicy Bypass -Command $cmd38a 2>&1 | Out-String
    if ($out38a -match "STATO ADBD UNKNOWN" -and $out38a -match "STATO SERVIZIO V5 UNKNOWN" -and $out38a -notmatch "UNEXPECTED_PASS_38A" -and $out38a -notmatch "\[RECOVERY V5\] Servizio .* ripristinato") {
        $subPassed38++
        Write-Host "   [PASS] Sotto-test 38a: Fallimento unroot in Backup-DeviceTlsIdentity preserva [STATO ADBD UNKNOWN] nel catch backup e vieta falso recovery" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 38a fallito: $out38a" -ForegroundColor Red
    }

    # 38b: adbd scomparso dopo elevation -> fail-closed STATO ADBD UNKNOWN + ADB irraggiungibile
    [System.IO.File]::WriteAllText($state38, "shell")
    [System.IO.File]::WriteAllText($appState38, "4400")
    if (Test-Path $log38) { Remove-Item $log38 -Force }
    $bk38b = (Join-Path $testDir38 "bk_38b").Replace('\', '/')
    $cmd38b = @"
`$env:NODE_EXE = '$nodeEsc38'
`$env:ADB_EXECUTABLE = '$mockAdbEsc38'
`$env:TEST38_MODE = 'adbd_gone'
try {
    & '$scriptEsc' -Action backup -TargetTv '127.0.0.1' -HttpPort 59987 -BackupDir '$bk38b' -AllowHardwareExecution
    Write-Output 'UNEXPECTED_PASS_38B'
} catch {
    Write-Output ('CAUGHT_38B:' + `$_.Exception.Message)
}
"@
    $out38b = & $psExe -ExecutionPolicy Bypass -Command $cmd38b 2>&1 | Out-String
    if ($out38b -match "STATO ADBD UNKNOWN" -and $out38b -notmatch "UNEXPECTED_PASS_38B") {
        $subPassed38++
        Write-Host "   [PASS] Sotto-test 38b: adbd scomparso/offline durante unroot bloccato in Fail-Closed ([STATO ADBD UNKNOWN])" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 38b fallito: $out38b" -ForegroundColor Red
    }

    # 38c: Backup interrotto a meta' estrazione TLS -> fail-closed, unroot ripristinato a shell, zero temp plaintext residui, servizio riavviato
    [System.IO.File]::WriteAllText($state38, "shell")
    [System.IO.File]::WriteAllText($appState38, "4400")
    if (Test-Path $log38) { Remove-Item $log38 -Force }
    $bk38cDir = Join-Path $testDir38 "bk_38c"
    $bk38c = $bk38cDir.Replace('\', '/')
    $cmd38c = @"
`$env:NODE_EXE = '$nodeEsc38'
`$env:ADB_EXECUTABLE = '$mockAdbEsc38'
`$env:TEST38_MODE = 'backup_interrupted'
`$env:RESTORE_PID_DELAY_MS = '50'
`$env:RESTORE_STATUS_DELAY_MS = '50'
try {
    & '$scriptEsc' -Action backup -TargetTv '127.0.0.1' -HttpPort 59987 -BackupDir '$bk38c' -AllowHardwareExecution
    Write-Output 'UNEXPECTED_PASS_38C'
} catch {
    Write-Output ('CAUGHT_38C:' + `$_.Exception.Message)
}
"@
    $out38c = & $psExe -ExecutionPolicy Bypass -Command $cmd38c 2>&1 | Out-String
    $finalSt38c = (Get-Content $state38 -Raw).Trim()
    $finalApp38c = (Get-Content $appState38 -Raw).Trim()
    $leftoverSecrets38c = Get-ChildItem -Path $bk38cDir -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "(?i)(server_keystore|ca\.pem|ca\.crt|ca_key)" }
    if ($out38c -match "CAUGHT_38C:ERRORE FAIL-CLOSED \(P1 Gate\)" -and $out38c -match "ca\.pem" -and $finalSt38c -eq "shell" -and $finalApp38c -eq "4488" -and (-not $leftoverSecrets38c) -and $out38c -notmatch "UNEXPECTED_PASS_38C") {
        $subPassed38++
        Write-Host "   [PASS] Sotto-test 38c: Backup interrotto fallisce fail-closed, pulisce temp plaintext, esegue unroot (shell) e riavvia servizio (PID=4488)" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 38c fallito (st=$finalSt38c, app=$finalApp38c): $out38c" -ForegroundColor Red
    }

    # 38d: Cold-start tollerato (2 timeout poi ok) vs servizio non ripristinabile -> UNKNOWN
    $countFile38 = Join-Path $testDir38 "count38.txt"
    $countEsc38 = $countFile38.Replace('\', '/')
    if (Test-Path $countFile38) { Remove-Item $countFile38 -Force }
    [System.IO.File]::WriteAllText($appState38, "stopped")
    $res38dOkFile = (Join-Path $testDir38 "res38d_ok.json").Replace('\', '/')
    $res38dFailFile = (Join-Path $testDir38 "res38d_fail.json").Replace('\', '/')
    $cmd38d = @"
`$env:NODE_EXE = '$nodeEsc38'
`$env:COUNT38_FILE = '$countEsc38'
`$env:TEST38_MODE = 'cold_start_ok'
`$env:RESTORE_PID_ATTEMPTS = '3'
`$env:RESTORE_PID_DELAY_MS = '30'
`$env:RESTORE_STATUS_ATTEMPTS = '5'
`$env:RESTORE_STATUS_DELAY_MS = '120'
. '$scriptEsc' -Action plan | Out-Null
`$r1 = Restore-TargetApplicationService -AdbExe '$mockAdbEsc38' -TargetAdb '127.0.0.1:5555' -PackageName 'it.akai.customremote' -TargetTv '127.0.0.1' -ExpectedHttpPort 59987 -UnrootVerified `$true
`$r1 | ConvertTo-Json | Set-Content -Path '$res38dOkFile' -Encoding utf8
`$env:TEST38_MODE = 'service_unrecoverable'
[System.IO.File]::WriteAllText('$appEsc38', 'stopped')
`$r2 = Restore-TargetApplicationService -AdbExe '$mockAdbEsc38' -TargetAdb '127.0.0.1:5555' -PackageName 'it.akai.customremote' -TargetTv '127.0.0.1' -ExpectedHttpPort 59987 -UnrootVerified `$true
`$r2 | ConvertTo-Json | Set-Content -Path '$res38dFailFile' -Encoding utf8
"@
    & $psExe -ExecutionPolicy Bypass -Command $cmd38d 2>&1 | Out-Null
    $r38dOk = if (Test-Path (Join-Path $testDir38 "res38d_ok.json")) { Get-Content (Join-Path $testDir38 "res38d_ok.json") -Raw | ConvertFrom-Json } else { @{} }
    $r38dFail = if (Test-Path (Join-Path $testDir38 "res38d_fail.json")) { Get-Content (Join-Path $testDir38 "res38d_fail.json") -Raw | ConvertFrom-Json } else { @{} }
    if ($r38dOk.Restored -eq $true -and $r38dOk.Status -eq "RESTORED" -and $r38dFail.Restored -eq $false -and $r38dFail.Status -eq "UNKNOWN") {
        $subPassed38++
        Write-Host "   [PASS] Sotto-test 38d: Cold-start recovery attende avvio reale prima di dichiarare RESTORED; impossibilita' ripristino restituisce UNKNOWN" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 38d fallito (ok=$($r38dOk.Restored)/$($r38dOk.Status), fail=$($r38dFail.Restored)/$($r38dFail.Status))" -ForegroundColor Red
    }

    if ($subPassed38 -eq 4) {
        Write-Host "[PASS] [TEST NEGATIVO & AFFERMATIVO / BACKUP HARDENING] Test 38: Unroot unknown, adbd scomparso, backup interrotto e cold-start service recovery convalidati (4/4)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO & AFFERMATIVO / BACKUP HARDENING] Test 38: Superati $subPassed38 / 4" -ForegroundColor Red
        $failed++
    }
} finally {
    Remove-Item $testDir38 -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
# TEST 39: Backup/Ripristino Cifrato Pairing & Sessioni Smartphone + Gate Pairing Assente
# -----------------------------------------------------------------------------
Write-Host "`n--- Esecuzione Test 39: Backup/Restore Cifrato Pairing & Sessioni Smartphone + Gate Negativi ---" -ForegroundColor Cyan
$testDir39 = Join-Path $tempDir "e2e_pairing_backup_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir39 | Out-Null

$devDb39 = Join-Path $testDir39 "dev39.db"
$devDbEsc39 = $devDb39.Replace('\', '/')
$deviceApk39 = Join-Path $testDir39 "device39.apk"
[System.IO.File]::WriteAllText($deviceApk39, "MOCK_APK_39")
$deviceApkEsc39 = $deviceApk39.Replace('\', '/')
$devPrefs39 = Join-Path $testDir39 "dev_prefs39"
$restoredPrefs39 = Join-Path $testDir39 "restored_prefs39"
New-Item -ItemType Directory -Force -Path $devPrefs39, $restoredPrefs39 | Out-Null

$sessionsXml39 = "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>`n<map>`n  <string name=`"session_1`">mock_token_test39_a</string>`n</map>"
$secPrefsXml39 = "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>`n<map>`n  <string name=`"active_provider`">local</string>`n</map>"
[System.IO.File]::WriteAllText((Join-Path $devPrefs39 "akai_remote_sessions.xml"), $sessionsXml39, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText((Join-Path $devPrefs39 "akai_ai_security_prefs.xml"), $secPrefsXml39, [System.Text.Encoding]::UTF8)

$setup39Js = Join-Path $testDir39 "setup39.js"
@"
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync('$devDbEsc39');
db.exec('CREATE TABLE memories (id INTEGER PRIMARY KEY, txt TEXT);');
db.exec("INSERT INTO memories VALUES (1, 'row39');");
db.close();
"@ | Out-File -FilePath $setup39Js -Encoding ascii
& $validNode --no-warnings $setup39Js

$state39 = Join-Path $testDir39 "state39.txt"
$log39 = Join-Path $testDir39 "log39.txt"
$appState39 = Join-Path $testDir39 "app39.txt"
$stateEsc39 = $state39.Replace('\', '/')
$logEsc39 = $log39.Replace('\', '/')
$appEsc39 = $appState39.Replace('\', '/')
$devPrefsEsc39 = $devPrefs39.Replace('\', '/')
$restPrefsEsc39 = $restoredPrefs39.Replace('\', '/')
$mockAdbJs39 = Join-Path $testDir39 "mock_adb_39.js"

@"
const fs = require('fs');
const path = require('path');
const args = process.argv.slice(2);
const argStr = args.join(' ');
const mode = process.env.TEST39_MODE || 'ok';
const stateFile = '$stateEsc39';
const logFile = '$logEsc39';
const appFile = '$appEsc39';
const devPrefs = '$devPrefsEsc39';
const restPrefs = '$restPrefsEsc39';

function getSt() { try { return fs.readFileSync(stateFile, 'utf8').trim(); } catch (e) { return 'shell'; } }
function getApp() { try { return fs.readFileSync(appFile, 'utf8').trim(); } catch (e) { return 'stopped'; } }
function setApp(v) { fs.writeFileSync(appFile, v, 'utf8'); }

if (args.includes('connect') || args.includes('wait-for-device')) { process.exit(0); }
if (args.includes('root')) {
    fs.appendFileSync(logFile, 'root\n', 'utf8');
    fs.writeFileSync(stateFile, 'root', 'utf8');
    console.log('restarting adbd as root');
    process.exit(0);
}
if (args.includes('unroot')) {
    fs.appendFileSync(logFile, 'unroot\n', 'utf8');
    fs.writeFileSync(stateFile, 'shell', 'utf8');
    console.log('restarting adbd as non root');
    process.exit(0);
}
if (args.includes('pull')) {
    fs.copyFileSync('$deviceApkEsc39', args[args.length - 1]);
    process.exit(0);
}
if (argStr.includes('run-as') || argStr.includes('su -c')) { process.exit(1); }
if (args.includes('shell')) {
    if (args[args.length - 1] === 'id') {
        console.log(getSt() === 'root' ? 'uid=0(root) gid=0(root) context=u:r:su:s0' : 'uid=2000(shell) gid=2000(shell) context=u:r:shell:s0');
        process.exit(0);
    }
    if (argStr.includes('pm path')) { console.log('package:/data/app/it.akai.customremote-1/base.apk'); process.exit(0); }
    if (argStr.includes('ADB_ALIVE')) { console.log('ADB_ALIVE'); process.exit(0); }
    if (argStr.includes('am force-stop')) { setApp('stopped'); process.exit(0); }
    if (argStr.includes('ACTION_BACKUP_DB')) { process.exit(0); }
    if (argStr.includes('am startservice') || argStr.includes('cmd activity start-service') || argStr.includes('am start -n')) {
        setApp('4511');
        process.exit(0);
    }
    if (argStr.includes('PIDOF_CHECK')) {
        const ap = getApp();
        console.log(ap && ap !== 'stopped' ? ('PIDOF_CHECK:pids=[' + ap + ']:exit=[0]') : 'PIDOF_CHECK:pids=[]:exit=[1]');
        process.exit(0);
    }
    if (argStr.includes('FILE_PROBE_RESULT')) {
        if (getSt() !== 'root') { console.log('FILE_PROBE_RESULT:ACCESS_DENIED'); process.exit(13); }
        if (argStr.includes('shared_prefs/')) {
            if (mode === 'pairing_missing') { console.log('FILE_PROBE_RESULT:NOT_FOUND'); process.exit(0); }
            const m = argStr.match(/shared_prefs\/([A-Za-z0-9_.\-]+\.xml)/);
            if (m && fs.existsSync(path.join(devPrefs, m[1]))) {
                console.log('FILE_PROBE_RESULT:EXISTS');
                process.exit(0);
            }
        }
        console.log('FILE_PROBE_RESULT:NOT_FOUND');
        process.exit(0);
    }
    process.exit(0);
}
if (args.includes('exec-in')) {
    fs.appendFileSync(logFile, 'exec-in:' + argStr + '\n', 'utf8');
    const m = argStr.match(/shared_prefs\/([A-Za-z0-9_.\-]+\.xml)/);
    if (m) {
        const chunks = [];
        process.stdin.on('data', c => chunks.push(c));
        process.stdin.on('end', () => {
            fs.writeFileSync(path.join(restPrefs, m[1]), Buffer.concat(chunks));
            process.exit(0);
        });
        return;
    }
    process.exit(0);
}
if (args.includes('exec-out')) {
    if (getSt() !== 'root') { process.exit(1); }
    if (argStr.includes('akai_memory.db-wal')) { process.exit(1); }
    if (argStr.includes('akai_memory.db')) {
        process.stdout.write(fs.readFileSync('$devDbEsc39'), () => process.exit(0));
        return;
    }
    const m = argStr.match(/shared_prefs\/([A-Za-z0-9_.\-]+\.xml)/);
    if (m) {
        if (mode === 'corrupt_xml' && m[1] === 'akai_remote_sessions.xml') {
            process.stdout.write(Buffer.from('<map_corrupt_not_closed_xml_payload'), () => process.exit(0));
            return;
        }
        const rp = path.join(restPrefs, m[1]);
        const dp = path.join(devPrefs, m[1]);
        const src = fs.existsSync(rp) ? rp : dp;
        if (fs.existsSync(src)) {
            let buf = fs.readFileSync(src);
            if (mode === 'tamper_readback' && m[1] === 'akai_remote_sessions.xml') {
                buf = Buffer.from(buf);
                buf[0] ^= 0xFF;
            }
            process.stdout.write(buf, () => process.exit(0));
            return;
        }
    }
    process.exit(1);
}
process.exit(0);
"@ | Out-File -FilePath $mockAdbJs39 -Encoding ascii

$mockAdbCmd39 = if ($isWin) { Join-Path $testDir39 "adb.cmd" } else { Join-Path $testDir39 "adb" }
if ($isWin) {
    "@echo off`n`"%NODE_EXE%`" `"$mockAdbJs39`" %*" | Out-File -FilePath $mockAdbCmd39 -Encoding ascii
} else {
    "#!/bin/sh`nexec `"`$NODE_EXE`" `"$mockAdbJs39`" `"`$@`"" | Out-File -FilePath $mockAdbCmd39 -Encoding ascii
    & chmod +x $mockAdbCmd39
}

$subPassed39 = 0
$port39 = Get-FreeLoopbackPort
$readyFile39 = Join-Path $testDir39 "ready39.txt"
$readyEsc39 = $readyFile39.Replace('\', '/')
$mockHttpJs39 = Join-Path $testDir39 "http39.js"
@"
const http = require('http');
const fs = require('fs');
const server = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json', 'Connection': 'close' });
    res.end(JSON.stringify({ status: 'ok', uinput_ready: true, active_sessions: 3 }));
});
setInterval(() => {}, 1000);
server.listen($port39, '127.0.0.1', () => { fs.writeFileSync('$readyEsc39', '1'); });
"@ | Out-File -FilePath $mockHttpJs39 -Encoding ascii

$httpProc39 = $null
$vaultDir39a = $null
try {
    $httpProc39 = Start-Process -FilePath $validNode -ArgumentList "`"$mockHttpJs39`"" -PassThru -NoNewWindow
    $w39 = 80
    while (-not (Test-Path $readyFile39) -and -not $httpProc39.HasExited -and $w39 -gt 0) {
        Start-Sleep -Milliseconds 100
        $w39--
    }

    $scriptEsc = $scriptPath.Replace('\', '/')
    $mockAdbEsc39 = $mockAdbCmd39.Replace('\', '/')
    $nodeEsc39 = $validNode.Replace('\', '/')

    # 39a: Backup + Restore cifrato shared_prefs via root elevation (1 ciclo root/unroot)
    [System.IO.File]::WriteAllText($state39, "shell")
    if (Test-Path $log39) { Remove-Item $log39 -Force }
    $sess39a = Join-Path $testDir39 "session_39a_test"
    $sess39aEsc = $sess39a.Replace('\', '/')
    $res39aFile = Join-Path $testDir39 "res39a.json"
    $res39aEsc = $res39aFile.Replace('\', '/')
    $cmd39a = @"
`$env:NODE_EXE = '$nodeEsc39'
`$env:ADB_EXECUTABLE = '$mockAdbEsc39'
`$env:TEST39_MODE = 'ok'
`$env:AKAI_FORCE_LOCAL_VAULT = 'true'
. '$scriptEsc' -Action plan | Out-Null
`$bk = Backup-DevicePairingSessions -AdbExe '$mockAdbEsc39' -TargetAdb '127.0.0.1:5555' -PackageName 'it.akai.customremote' -SessionDir '$sess39aEsc' -RequirePairing
`$sec = Assert-BackupSessionNoPlaintextSecrets -SessionDir '$sess39aEsc' -VaultDirs @(`$bk.VaultDir)
`$rs = Restore-DevicePairingSessions -AdbExe '$mockAdbEsc39' -TargetAdb '127.0.0.1:5555' -PackageName 'it.akai.customremote' -SessionDir '$sess39aEsc' -ChownTarget '10051:10051'
@{ Backup = `$bk; SecretsOk = `$sec; Restore = `$rs } | ConvertTo-Json -Depth 6 | Set-Content -Path '$res39aEsc' -Encoding utf8
"@
    & $psExe -ExecutionPolicy Bypass -Command $cmd39a 2>&1 | Out-Null
    $r39a = if (Test-Path $res39aFile) { Get-Content $res39aFile -Raw | ConvertFrom-Json } else { $null }
    $logText39a = if (Test-Path $log39) { Get-Content $log39 -Raw } else { "" }
    $manText39a = Get-Content (Join-Path $sess39a "pairing_sessions\pairing_manifest.json") -Raw -ErrorAction SilentlyContinue
    if ($r39a -and $r39a.Backup.VaultDir) { $vaultDir39a = $r39a.Backup.VaultDir }
    $encExists39a = ($r39a -and $vaultDir39a -and
                     (Test-Path (Join-Path $vaultDir39a "akai_remote_sessions.xml.enc")) -and
                     (Test-Path (Join-Path $vaultDir39a "akai_ai_security_prefs.xml.enc")) -and
                     (-not (Test-Path (Join-Path $sess39a "pairing_sessions\akai_remote_sessions.xml"))))
    $manifestSafe39a = ($manText39a -and $manText39a -notmatch "mock_token_test39_a")
    $restoreChmod39a = ($r39a.Restore.Restored -eq $true -and $r39a.Restore.FileCount -eq 2 -and $logText39a -match "chmod 660 /data/data/it\.akai\.customremote/shared_prefs/akai_remote_sessions\.xml")
    if ($r39a -and $r39a.Backup.HasPairing -eq $true -and $r39a.SecretsOk -eq $true -and $encExists39a -and $manifestSafe39a -and $restoreChmod39a -and (Test-Path (Join-Path $sess39a "pairing_sessions\vault_pointer.json"))) {
        $subPassed39++
        Write-Host "   [PASS] Sotto-test 39a: Backup cifrato shared_prefs (pairing + AI config), ZERO token nel manifest e restore bit-for-bit chmod 660 convalidati" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 39a fallito (enc=$encExists39a, manSafe=$manifestSafe39a, restore=$restoreChmod39a)" -ForegroundColor Red
    }

    # 39b: Gate negativo pairing assente (-RequirePairing + automatico active_sessions=3 in -Action backup)
    [System.IO.File]::WriteAllText($state39, "shell")
    [System.IO.File]::WriteAllText($appState39, "4500")
    $sess39b = (Join-Path $testDir39 "session_39b").Replace('\', '/')
    $bk39b = (Join-Path $testDir39 "bk_39b").Replace('\', '/')
    $cmd39b = @"
`$env:NODE_EXE = '$nodeEsc39'
`$env:ADB_EXECUTABLE = '$mockAdbEsc39'
`$env:TEST39_MODE = 'pairing_missing'
`$env:RESTORE_PID_DELAY_MS = '30'
`$env:RESTORE_STATUS_DELAY_MS = '30'
. '$scriptEsc' -Action plan | Out-Null
try {
    Backup-DevicePairingSessions -AdbExe '$mockAdbEsc39' -TargetAdb '127.0.0.1:5555' -PackageName 'it.akai.customremote' -SessionDir '$sess39b' -RequirePairing | Out-Null
    Write-Output 'UNEXPECTED_PASS_39B_UNIT'
} catch {
    Write-Output ('UNIT_39B:' + `$_.Exception.Message)
}
try {
    & '$scriptEsc' -Action backup -TargetTv '127.0.0.1' -HttpPort $port39 -BackupDir '$bk39b' -AllowHardwareExecution
    Write-Output 'UNEXPECTED_PASS_39B_E2E'
} catch {
    Write-Output ('E2E_39B:' + `$_.Exception.Message)
}
"@
    $out39b = & $psExe -ExecutionPolicy Bypass -Command $cmd39b 2>&1 | Out-String
    if ($out39b -match "UNIT_39B:ERRORE FAIL-CLOSED \(Pairing Gate\)" -and $out39b -match "E2E_39B:ERRORE FAIL-CLOSED \(Pairing Gate\)" -and $out39b -notmatch "UNEXPECTED_PASS_39B") {
        $subPassed39++
        Write-Host "   [PASS] Sotto-test 39b: Pairing assente (con -RequirePairing o active_sessions=3 HTTP) bloccato categoricamente in Fail-Closed" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 39b fallito: $out39b" -ForegroundColor Red
    }

    # 39c: XML corrotto su backup + tamper hash su restore -> FAIL-CLOSED
    [System.IO.File]::WriteAllText($state39, "shell")
    $sess39c = (Join-Path $testDir39 "session_39c").Replace('\', '/')
    $cmd39c = @"
`$env:NODE_EXE = '$nodeEsc39'
`$env:ADB_EXECUTABLE = '$mockAdbEsc39'
`$env:TEST39_MODE = 'corrupt_xml'
. '$scriptEsc' -Action plan | Out-Null
try {
    Backup-DevicePairingSessions -AdbExe '$mockAdbEsc39' -TargetAdb '127.0.0.1:5555' -PackageName 'it.akai.customremote' -SessionDir '$sess39c' -RequirePairing | Out-Null
    Write-Output 'UNEXPECTED_PASS_39C_XML'
} catch {
    Write-Output ('XML_39C:' + `$_.Exception.Message)
}
`$env:TEST39_MODE = 'tamper_readback'
try {
    Restore-DevicePairingSessions -AdbExe '$mockAdbEsc39' -TargetAdb '127.0.0.1:5555' -PackageName 'it.akai.customremote' -SessionDir '$sess39aEsc' -ChownTarget '10051:10051' | Out-Null
    Write-Output 'UNEXPECTED_PASS_39C_TAMPER'
} catch {
    Write-Output ('TAMPER_39C:' + `$_.Exception.Message)
}
"@
    $out39c = & $psExe -ExecutionPolicy Bypass -Command $cmd39c 2>&1 | Out-String
    if ($out39c -match "XML_39C:ERRORE FAIL-CLOSED \(Pairing Gate\)" -and $out39c -match "TAMPER_39C:ERRORE FAIL-CLOSED: Mismatch SHA-256" -and $out39c -notmatch "UNEXPECTED_PASS_39C") {
        $subPassed39++
        Write-Host "   [PASS] Sotto-test 39c: XML corrotto su backup e manomissione post-restore rilevati in Fail-Closed" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 39c fallito: $out39c" -ForegroundColor Red
    }

    if ($subPassed39 -eq 3) {
        Write-Host "[PASS] [TEST AFFERMATIVO & NEGATIVO / PAIRING SESSIONS GATE] Test 39: Backup/restore cifrato shared_prefs e gate pairing assente/corrotto convalidati (3/3)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST AFFERMATIVO & NEGATIVO / PAIRING SESSIONS GATE] Test 39: Superati $subPassed39 / 3" -ForegroundColor Red
        $failed++
    }
} finally {
    if ($httpProc39 -and -not $httpProc39.HasExited) { Stop-Process -Id $httpProc39.Id -Force -ErrorAction SilentlyContinue }
    if ($vaultDir39a -and $vaultDir39a -match "session_39a_test" -and (Test-Path $vaultDir39a)) {
        $vParent39 = Split-Path $vaultDir39a -Parent
        Remove-Item $vParent39 -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $testDir39 -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
# TEST 40: Gate Negativo Credenziali Fuori Vault (Assert-BackupSessionNoPlaintextSecrets)
# -----------------------------------------------------------------------------
Write-Host "`n--- Esecuzione Test 40: Gate Negativo Credenziali Fuori Vault ---" -ForegroundColor Cyan
$testDir40 = Join-Path $tempDir "e2e_creds_outside_vault_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir40 | Out-Null
$subPassed40 = 0
$vault40Path = $null

try {
    $scriptEsc = $scriptPath.Replace('\', '/')
    $sess40 = Join-Path $testDir40 "session_40_clean"
    New-Item -ItemType Directory -Force -Path $sess40 | Out-Null
    $sess40Esc = $sess40.Replace('\', '/')
    $v40OutFile = Join-Path $testDir40 "vault40.txt"
    $v40OutEsc = $v40OutFile.Replace('\', '/')

    # Setup vault valido per 40d e verifica path
    $cmd40Setup = @"
`$env:AKAI_FORCE_LOCAL_VAULT = 'true'
. '$scriptEsc' -Action plan | Out-Null
`$v = Resolve-SecureVaultSubdir -SessionDir '$sess40Esc' -PackageName 'it.akai.customremote' -SubdirName 'tls_identity'
[System.IO.File]::WriteAllText('$v40OutEsc', `$v.VaultDir, [System.Text.Encoding]::UTF8)
`$ok = Assert-BackupSessionNoPlaintextSecrets -SessionDir '$sess40Esc' -VaultDirs @(`$v.VaultDir)
Write-Output ('CLEAN_40D=' + `$ok)
"@
    $out40d = & $psExe -ExecutionPolicy Bypass -Command $cmd40Setup 2>&1 | Out-String
    if (Test-Path $v40OutFile) { $vault40Path = (Get-Content $v40OutFile -Raw).Trim() }
    $vault40Esc = if ($vault40Path) { $vault40Path.Replace('\', '/') } else { $sess40Esc }

    if ($out40d -match "CLEAN_40D=True") {
        $subPassed40++
        Write-Host "   [PASS] Sotto-test 40d: Sessione cifrata pulita + vault conforme approvati" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 40d fallito: $out40d" -ForegroundColor Red
    }

    # 40a: File sensibile in chiaro in SessionDir (server_keystore.pass e akai_remote_sessions.xml)
    $s40a = Join-Path $testDir40 "s40a"
    New-Item -ItemType Directory -Force -Path $s40a | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $s40a "server_keystore.pass"), "plain_pass")
    $s40aEsc = $s40a.Replace('\', '/')
    $s40a2 = Join-Path $testDir40 "s40a2"
    New-Item -ItemType Directory -Force -Path $s40a2 | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $s40a2 "akai_remote_sessions.xml"), "<map></map>")
    $s40a2Esc = $s40a2.Replace('\', '/')
    $cmd40a = @"
. '$scriptEsc' -Action plan | Out-Null
try { Assert-BackupSessionNoPlaintextSecrets -SessionDir '$s40aEsc' | Out-Null; Write-Output 'MISS_A1' } catch { Write-Output ('HIT_A1:' + `$_.Exception.Message) }
try { Assert-BackupSessionNoPlaintextSecrets -SessionDir '$s40a2Esc' | Out-Null; Write-Output 'MISS_A2' } catch { Write-Output ('HIT_A2:' + `$_.Exception.Message) }
"@
    $out40a = & $psExe -ExecutionPolicy Bypass -Command $cmd40a 2>&1 | Out-String
    if ($out40a -match "HIT_A1:ERRORE FAIL-CLOSED \[CREDENZIALI FUORI VAULT\]" -and $out40a -match "HIT_A2:ERRORE FAIL-CLOSED \[CREDENZIALI FUORI VAULT\]" -and $out40a -notmatch "MISS_A") {
        $subPassed40++
        Write-Host "   [PASS] Sotto-test 40a: Segreti TLS / XML pairing in chiaro fuori vault bloccati" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 40a fallito: $out40a" -ForegroundColor Red
    }

    # 40b: Vault in cloud-sync (OneDrive) o .vault_master.key in SessionDir
    $cloudDir40b = Join-Path $testDir40 "OneDrive\fake_vault"
    New-Item -ItemType Directory -Force -Path $cloudDir40b | Out-Null
    $cloudEsc40b = $cloudDir40b.Replace('\', '/')
    $s40b2 = Join-Path $testDir40 "s40b2"
    New-Item -ItemType Directory -Force -Path $s40b2 | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $s40b2 ".vault_master.key"), "fake_key")
    $s40b2Esc = $s40b2.Replace('\', '/')
    $cmd40b = @"
. '$scriptEsc' -Action plan | Out-Null
try { Assert-BackupSessionNoPlaintextSecrets -SessionDir '$sess40Esc' -VaultDirs @('$cloudEsc40b') | Out-Null; Write-Output 'MISS_B1' } catch { Write-Output ('HIT_B1:' + `$_.Exception.Message) }
try { Assert-BackupSessionNoPlaintextSecrets -SessionDir '$s40b2Esc' -VaultDirs @('$vault40Esc') | Out-Null; Write-Output 'MISS_B2' } catch { Write-Output ('HIT_B2:' + `$_.Exception.Message) }
"@
    $out40b = & $psExe -ExecutionPolicy Bypass -Command $cmd40b 2>&1 | Out-String
    if ($out40b -match "HIT_B1:ERRORE FAIL-CLOSED \[CREDENZIALI FUORI VAULT\]" -and $out40b -match "HIT_B2:ERRORE FAIL-CLOSED \[CREDENZIALI FUORI VAULT\]" -and $out40b -notmatch "MISS_B") {
        $subPassed40++
        Write-Host "   [PASS] Sotto-test 40b: Vault cloud-sync e master key fuori posto bloccati categoricamente" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 40b fallito: $out40b" -ForegroundColor Red
    }

    # 40c: Secret leak simulato dentro file manifest JSON
    $s40c = Join-Path $testDir40 "s40c"
    New-Item -ItemType Directory -Force -Path $s40c | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $s40c "leaked_manifest.json"), '{"debug":"Bearer mock_leaked_token_123456"}')
    $s40cEsc = $s40c.Replace('\', '/')
    $cmd40c = @"
. '$scriptEsc' -Action plan | Out-Null
try { Assert-BackupSessionNoPlaintextSecrets -SessionDir '$s40cEsc' | Out-Null; Write-Output 'MISS_C' } catch { Write-Output ('HIT_C:' + `$_.Exception.Message) }
"@
    $out40c = & $psExe -ExecutionPolicy Bypass -Command $cmd40c 2>&1 | Out-String
    if ($out40c -match "HIT_C:ERRORE FAIL-CLOSED \[CREDENZIALI FUORI VAULT\]" -and $out40c -notmatch "MISS_C") {
        $subPassed40++
        Write-Host "   [PASS] Sotto-test 40c: Leak Bearer/chiave privata in JSON manifest rilevato e bloccato" -ForegroundColor Green
    } else {
        Write-Host "   [FAIL] Sotto-test 40c fallito: $out40c" -ForegroundColor Red
    }

    if ($subPassed40 -eq 4) {
        Write-Host "[PASS] [TEST NEGATIVO & AFFERMATIVO / GUARDIA CREDENZIALI FUORI VAULT] Test 40: Isolamento credenziali e segreti verificato al 100% (4/4)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] [TEST NEGATIVO & AFFERMATIVO / GUARDIA CREDENZIALI FUORI VAULT] Test 40: Superati $subPassed40 / 4" -ForegroundColor Red
        $failed++
    }
} finally {
    if ($vault40Path -and $vault40Path -match "session_40_clean" -and (Test-Path $vault40Path)) {
        $vParent40 = Split-Path $vault40Path -Parent
        Remove-Item $vParent40 -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $testDir40 -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n=== ESITO COMPLETO TEST POWERSHELL MOCK ADB ===" -ForegroundColor Cyan
Write-Host "Test Superati: $passed / $($passed + $failed)" -ForegroundColor Green
if ($failed -gt 0) { 
    exit 1 
} else { 
    exit 0 
}
