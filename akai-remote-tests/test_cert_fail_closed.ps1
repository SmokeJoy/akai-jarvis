# ==============================================================================
# Test Unitario Fail-Closed per Verifica Firme Digitali APK
# ==============================================================================

$ErrorActionPreference = "Stop"

Write-Host "=== TEST FAIL-CLOSED VERIFICA FIRME DIGITALI ===" -ForegroundColor Cyan
$passed = 0
$failed = 0

$sdkDir = "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay\tools\android-sdk"
$apksignerJar = Join-Path $sdkDir "build-tools\28.0.3\lib\apksigner.jar"
$jdkDir = "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay\tools\jdk-17"
$java = Join-Path $jdkDir "bin\java.exe"

function Get-FingerprintTest($apkFile, $overrideJar = $null) {
    $jar = if ($overrideJar) { $overrideJar } else { $apksignerJar }
    if (-not (Test-Path $apkFile)) {
        throw "ERRORE FAIL-CLOSED: File APK non trovato in: $apkFile"
    }
    if (-not (Test-Path $jar)) {
        throw "ERRORE FAIL-CLOSED: Tool apksigner.jar non trovato in: $jar"
    }
    $out = & $java -jar $jar verify --print-certs $apkFile 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "ERRORE FAIL-CLOSED: apksigner ha fallito la verifica dell'APK ($apkFile) con codice $LASTEXITCODE : $out"
    }
    $match = $out | Select-String "Signer #1 certificate SHA-256 digest:\s*([a-fA-F0-9]{64})"
    if (-not $match) {
        throw "ERRORE FAIL-CLOSED: Impossibile estrarre un digest SHA-256 valido da: $apkFile"
    }
    return $match.Matches[0].Groups[1].Value.ToLower().Trim()
}

# Test 1: File APK inesistente -> DEVE LANCIARE ECCEZIONE (Fail-Closed)
try {
    Get-FingerprintTest "C:\non_existent_file.apk"
    Write-Host "[FAIL] Test 1: File inesistente non ha bloccato" -ForegroundColor Red
    $failed++
} catch {
    Write-Host "[PASS] Test 1: File inesistente bloccato con eccezione fail-closed: $($_.Exception.Message)" -ForegroundColor Green
    $passed++
}

# Test 2: Tool apksigner mancante -> DEVE LANCIARE ECCEZIONE (Fail-Closed)
$dummyApk = Join-Path ([System.IO.Path]::GetTempPath()) "dummy_temp.apk"
[System.IO.File]::WriteAllText($dummyApk, "PK")
try {
    Get-FingerprintTest $dummyApk -overrideJar "c:\invalid\apksigner.jar"
    Write-Host "[FAIL] Test 2: Tool mancante non ha bloccato" -ForegroundColor Red
    $failed++
} catch {
    Write-Host "[PASS] Test 2: Tool mancante bloccato con eccezione fail-closed: $($_.Exception.Message)" -ForegroundColor Green
    $passed++
} finally {
    Remove-Item $dummyApk -ErrorAction SilentlyContinue
}

# Test 3: File corrotto / non firmato -> DEVE LANCIARE ECCEZIONE (Fail-Closed)
$dummyCorrupt = Join-Path ([System.IO.Path]::GetTempPath()) "dummy_corrupt.apk"
[System.IO.File]::WriteAllText($dummyCorrupt, "NOT AN APK")
try {
    Get-FingerprintTest $dummyCorrupt
    Write-Host "[FAIL] Test 3: File corrotto non ha bloccato" -ForegroundColor Red
    $failed++
} catch {
    Write-Host "[PASS] Test 3: File non valido/non firmato bloccato con eccezione fail-closed" -ForegroundColor Green
    $passed++
} finally {
    Remove-Item $dummyCorrupt -ErrorAction SilentlyContinue
}

Write-Host "`n=== ESITO TEST FIRMA FAIL-CLOSED ===" -ForegroundColor Cyan
Write-Host "Test Superati: $passed / $($passed + $failed)" -ForegroundColor Green
if ($failed -gt 0) { exit 1 }
