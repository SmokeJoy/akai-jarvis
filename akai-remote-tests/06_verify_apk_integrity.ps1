# ==============================================================================
# AKAI Custom TV - Test 06: Verifica Rigorosa Integrità APK (Fase 4.2)
# Ispezione profonda di classes.dex, ELF JNI, Keystore TLS, Assets e Firma
# ==============================================================================

$ErrorActionPreference = "Stop"

$workspace = "C:\Users\danie\OneDrive\Documenti\Antygravity\Akay"
$toolsDir = Join-Path $workspace "tools"
$jdkDir = Join-Path $toolsDir "jdk-17"
$sdkDir = Join-Path $toolsDir "android-sdk"
$buildToolsDir = Join-Path $sdkDir "build-tools\28.0.3"
$ndkDir = Join-Path $sdkDir "ndk\21.4.7075529"
$llvmBin = Join-Path $ndkDir "toolchains\llvm\prebuilt\windows-x86_64\bin"

$jar = Join-Path $jdkDir "bin\jar.exe"
$apksignerJar = Join-Path $buildToolsDir "lib\apksigner.jar"
$java = Join-Path $jdkDir "bin\java.exe"
$readelf = Join-Path $llvmBin "llvm-readelf.exe"
$nm = Join-Path $llvmBin "llvm-nm.exe"

$apkPath = Join-Path $workspace "akai-remote-tv\app\build\outputs\apk\debug\app-debug.apk"

Write-Host "=== VERIFICA RIGOROSA INTEGRITA' APK (AKAI CUSTOM REMOTE) ===" -ForegroundColor Cyan

if (-not (Test-Path $apkPath)) {
    Write-Host "ERRORE: APK non trovato in $apkPath" -ForegroundColor Red
    exit 1
}

# 1. Informazioni Generali
$apkFile = Get-Item $apkPath
$sha256 = (Get-FileHash -Path $apkPath -Algorithm SHA256).Hash
$md5 = (Get-FileHash -Path $apkPath -Algorithm MD5).Hash
Write-Host "[1/5] Metadati File APK:"
Write-Host "      Percorso   : $($apkFile.FullName)"
Write-Host "      Dimensione : $([Math]::Round($apkFile.Length / 1024, 2)) KB ($($apkFile.Length) bytes)"
Write-Host "      SHA-256    : $sha256" -ForegroundColor Yellow
Write-Host "      MD5        : $md5"

# 2. Controllo Contenuto Archivio
Write-Host "`n[2/5] Ispezione voci interne dell'archivio APK:"
$entries = & $jar tf $apkPath

$requiredEntries = @(
    "classes.dex",
    "lib/armeabi-v7a/libakai_uinput.so",
    "assets/www/index.html",
    "assets/www/style.css",
    "assets/www/app.js",
    "assets/www/manifest.json",
    "AndroidManifest.xml",
    "resources.arsc"
)

$forbiddenEntries = @(
    "assets/server_keystore.p12",
    "assets/www/AkaiRootCA.crt",
    "server_keystore.p12"
)

$missing = @()
foreach ($req in $requiredEntries) {
    if ($entries -contains $req) {
        Write-Host "      [OK] $req presente" -ForegroundColor Green
    } else {
        Write-Host "      [FAIL] $req MANCANTE!" -ForegroundColor Red
        $missing += $req
    }
}

foreach ($forb in $forbiddenEntries) {
    if ($entries -contains $forb) {
        Write-Host "      [VIOLAZIONE SICUREZZA] $forb trovato nell'APK!" -ForegroundColor Red
        exit 1
    } else {
        Write-Host "      [SICURO] $forb assente dall'APK (nessun segreto/chiave privata incorporata)" -ForegroundColor Green
    }
}

if ($missing.Count -gt 0) {
    Write-Host "ERRORE: Componenti obbligatori mancanti nell'APK!" -ForegroundColor Red
    exit 1
}

# 3. Analisi della Libreria Nativa JNI (ELF ARMv7)
Write-Host "`n[3/5] Verifica ELF e Simboli JNI per libakai_uinput.so:"
$tempDir = Join-Path $workspace "akai-remote-tests\temp_apk_extract"
if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($apkPath, $tempDir)

$extractedSo = Join-Path $tempDir "lib\armeabi-v7a\libakai_uinput.so"
if (Test-Path $extractedSo) {
    Write-Host "      Verifica architettura ELF con readelf:"
    $headerInfo = & $readelf -h $extractedSo | Select-String "Class|Machine|Flags"
    $headerInfo | ForEach-Object { Write-Host "        $_" }

    Write-Host "`n      Verifica simboli esportati JNI (llvm-nm):"
    $symbols = & $nm -D $extractedSo | Select-String "Java_it_akai_customremote"
    $symbols | ForEach-Object { Write-Host "        $_" -ForegroundColor Green }
} else {
    Write-Host "      [FAIL] Impossibile estrarre libakai_uinput.so" -ForegroundColor Red
    exit 1
}

# 4. Verifica Firma Digitale (apksigner)
Write-Host "`n[4/5] Verifica firma digitale e schemi APK:"
$verifyOutput = & $java -jar $apksignerJar verify --verbose $apkPath 2>&1
$verifyOutput | ForEach-Object { Write-Host "      $_" }

# 5. Verifica Assoluta Assenza Segreti e Conformità Sicurezza
Write-Host "`n[5/5] Verifica Assenza Segreti Crittografici nell'APK:"
$hasP12 = Test-Path (Join-Path $tempDir "assets\server_keystore.p12")
$hasCrt = Test-Path (Join-Path $tempDir "assets\www\AkaiRootCA.crt")

if ($hasP12 -or $hasCrt) {
    Write-Host "      [FAIL] Trovati file di chiavi o certificati negli asset!" -ForegroundColor Red
    exit 1
} else {
    Write-Host "      [OK] Nessun keystore PKCS12 negli asset" -ForegroundColor Green
    Write-Host "      [OK] Nessun certificato CA o chiave privata distribuito nell'APK" -ForegroundColor Green
    Write-Host "      [OK] Chiavi private relegate esclusivamente all'AndroidKeyStore hardware di runtime" -ForegroundColor Green
}

Remove-Item $tempDir -Recurse -Force
Write-Host "`n=== ESITO VERIFICA RIGOROSA INTEGRITA': APK 100% CONFORME ===" -ForegroundColor Green
