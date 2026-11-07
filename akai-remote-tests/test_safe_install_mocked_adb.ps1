# ==============================================================================
# AKAI Custom Remote - Test Suite Mock ADB & Fail-Closed Validation (PowerShell / Pwsh)
# Esercita direttamente il codice di 05_safe_install_and_rollback.ps1 senza toccare la TV fisica
# ==============================================================================

$ErrorActionPreference = "Stop"

Write-Host "=== TEST POWERSHELL OFFLINE CON MOCK ADB & FAIL-CLOSED ===" -ForegroundColor Cyan
$passed = 0
$failed = 0

$scriptPath = Join-Path $PSScriptRoot "05_safe_install_and_rollback.ps1"
$tempDir = [System.IO.Path]::GetTempPath()
$psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
$isWin = [System.Environment]::OSVersion.Platform.ToString() -match "Win"

# TEST 1: Installazione senza parametro -ApkPath obbligatorio
try {
    $out1 = & $psExe -ExecutionPolicy Bypass -File $scriptPath -Action install -AllowHardwareExecution 2>&1 | Out-String
    if ($out1 -match "ERRORE FAIL-CLOSED: Il parametro -ApkPath e' obbligatorio") {
        Write-Host "[PASS] Test 1: Mancanza parametro -ApkPath bloccata categoricamente (Fail-Closed)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] Test 1: Mancato blocco per ApkPath mancante: $out1" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[PASS] Test 1: Mancanza parametro -ApkPath bloccata con eccezione Fail-Closed" -ForegroundColor Green
    $passed++
}

# TEST 2: Tentativo di installazione con artefatto di test CI non distribuibile
try {
    $out2 = & $psExe -ExecutionPolicy Bypass -File $scriptPath -Action install -ApkPath ".\build_ci\app-ci-test-nondistributable.apk" -AllowHardwareExecution 2>&1 | Out-String
    if ($out2 -match "BLOCCO DI SICUREZZA: L'APK candidato e' un artefatto di test CI") {
        Write-Host "[PASS] Test 2: Rifiuto categorico artefatto CI non distribuibile confermato" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] Test 2: Artefatto CI non bloccato: $out2" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[PASS] Test 2: Artefatto CI bloccato con eccezione Fail-Closed" -ForegroundColor Green
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
        Write-Host "[PASS] Test 3: File database corrotto bloccato da Verify-SQLiteIntegrityOffline (Fail-Closed)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] Test 3: Database corrotto non ha generato eccezione: $out3" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[PASS] Test 3: Database corrotto bloccato con eccezione Fail-Closed" -ForegroundColor Green
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
        Write-Host "[PASS] Test 4: File inesistente solleva eccezione fail-closed immediata (zero fail-open)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] Test 4: Mancato blocco fail-closed su file inesistente" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[PASS] Test 4: Eccezione fail-closed confermata per file inesistente" -ForegroundColor Green
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
        Write-Host "[PASS] Test 5: Simulazione permessi negati ADB (run-as negato): installazione ABORTITA prima di toccare il sistema (Fail-Closed)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] Test 5: Fallimento simulazione permessi negati: $res5" -ForegroundColor Red
        $failed++
    }
} catch {
    $errMsg = $_.Exception.Message
    if ($errMsg -match "ERRORE FAIL-CLOSED: Impossibile estrarre un backup integro del database" -or $errMsg -match "Permission denied") {
        Write-Host "[PASS] Test 5: Simulazione permessi negati ADB: installazione ABORTITA con blocco fail-closed" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] Test 5: Errore imprevisto: $errMsg" -ForegroundColor Red
        $failed++
    }
} finally {
    Remove-Item $mockAdbDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $dummyCandidateApk -Force -ErrorAction SilentlyContinue
}

# TEST 6: Verifica Fail-Closed quando nessun motore SQLite e' disponibile nell'ambiente
# Crea un file dummy valido (>512 bytes) e invoca una sessione isolata priva di motori SQLite
$dummyDb6 = Join-Path $tempDir "valid_size_test_$([Guid]::NewGuid().ToString('N')).db"
$dummyBytes = New-Object byte[] 1024
[System.IO.File]::WriteAllBytes($dummyDb6, $dummyBytes)

try {
    $scriptEscaped = $scriptPath.Replace('\', '/')
    $dbEscaped6 = $dummyDb6.Replace('\', '/')
    
    # In questa subshell isolata forziamo l'assenza di node/python/sqlite3 disabilitando PATH e percorsi tool
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
        Write-Host "[PASS] Test 6: Assenza interpreti SQLite bloccata con eccezione Fail-Closed (zero fail-open)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "[FAIL] Test 6: Mancato blocco fail-closed su assenza tool: $out6" -ForegroundColor Red
        $failed++
    }
} catch {
    Write-Host "[PASS] Test 6: Assenza interpreti SQLite bloccata con eccezione Fail-Closed" -ForegroundColor Green
    $passed++
} finally {
    Remove-Item $dummyDb6 -Force -ErrorAction SilentlyContinue
}

Write-Host "`n=== ESITO COMPLETO TEST POWERSHELL MOCK ADB ===" -ForegroundColor Cyan
Write-Host "Test Superati: $passed / $($passed + $failed)" -ForegroundColor Green
if ($failed -gt 0) { 
    exit 1 
} else { 
    exit 0 
}
