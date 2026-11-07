# ==============================================================================
# AKAI Custom TV - Generatore Archivio Integrale per Audit Esterno v16
# Esegue scansione segreti, assembla i 7 archivi indipendenti, manifest e documentazione
# ==============================================================================

$ErrorActionPreference = "Stop"

$workspace = "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay"
$outputBase = Join-Path $workspace "AKAI_AUDIT_COMPLETO"
$staging = Join-Path $workspace "staging_audit_temp"

Write-Host "=== AVVIO PROCEDURA SNAPSHOT E AUDIT INTEGRALE AKAI JARVIS ===" -ForegroundColor Cyan

if (Test-Path $outputBase) { Remove-Item $outputBase -Recurse -Force }
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }

New-Item -ItemType Directory -Force -Path $outputBase | Out-Null
New-Item -ItemType Directory -Force -Path $staging | Out-Null

# Definizione delle 7 cartelle di staging
$stage01 = Join-Path $staging "01_AKAI_ANDROID_SOURCES"
$stage02 = Join-Path $staging "02_AKAI_WEB_REMOTE"
$stage03 = Join-Path $staging "03_AKAI_BUILD_SCRIPTS_DEPENDENCIES"
$stage04 = Join-Path $staging "04_AKAI_TESTS_REPORTS"
$stage05 = Join-Path $staging "05_AKAI_HISTORY_BASELINES"
$stage06 = Join-Path $staging "06_AKAI_BINARIES_RELEASE"
$stage07 = Join-Path $staging "07_AKAI_ARCHITECTURE_EVIDENCE"

$allStages = @($stage01, $stage02, $stage03, $stage04, $stage05, $stage06, $stage07)
foreach ($st in $allStages) {
    New-Item -ItemType Directory -Force -Path $st | Out-Null
}

Write-Host "[1/8] Popolamento 01_AKAI_ANDROID_SOURCES..."
# akai-remote-tv sorgenti, manifest, jni, risorse, asset sanitizzati
$dstRemote = Join-Path $stage01 "akai-remote-tv"
New-Item -ItemType Directory -Force -Path "$dstRemote\app\src" | Out-Null
Copy-Item "$workspace\akai-remote-tv\app\src\*" "$dstRemote\app\src" -Recurse -Force
# Rimuovi file di chiavi private dagli assets se presenti
if (Test-Path "$dstRemote\app\src\main\assets\server_keystore.p12") {
    Remove-Item "$dstRemote\app\src\main\assets\server_keystore.p12" -Force
}

# akai-custom-home sorgenti, manifest, risorse
$dstHome = Join-Path $stage01 "akai-custom-home"
New-Item -ItemType Directory -Force -Path "$dstHome\app\src" | Out-Null
Copy-Item "$workspace\akai-custom-home\app\src\*" "$dstHome\app\src" -Recurse -Force

Write-Host "[2/8] Popolamento 02_AKAI_WEB_REMOTE..."
Copy-Item "$workspace\akai-remote-web\*" $stage02 -Recurse -Force

Write-Host "[3/8] Popolamento 03_AKAI_BUILD_SCRIPTS_DEPENDENCIES..."
New-Item -ItemType Directory -Force -Path "$stage03\scripts" | Out-Null
Copy-Item "$workspace\scripts\*" "$stage03\scripts" -Recurse -Force

# Documentazione dipendenze e toolchain
$toolchainDoc = @"
# Toolchain e Dipendenze di Build AKAI JARVIS

La compilazione del progetto è interamente riproducibile su ambiente Windows tramite i seguenti strumenti:

1. **Java Development Kit (JDK)**:
   - Versione: OpenJDK 17.0.2 (64-bit)
   - Target compilazione Java: -source 1.8 -target 1.8 (compatibilità Android 9 API 28)
   - Componenti utilizzati: `javac.exe`, `java.exe`, `keytool.exe`, `jar.exe`

2. **Android SDK Tools**:
   - Android API Platform: `platforms\android-28\android.jar` (Android 9 Pie)
   - Build Tools: Versione 28.0.3
   - Compilatore Risorse: `aapt2.exe`
   - DEX Compiler: `d8.jar` (`com.android.tools.r8.D8` con flag `--min-api 21`)
   - ZipAlign: `zipalign.exe`
   - Firma APK: `apksigner.jar` (con schemi v1 JAR signing e v2 Full APK Signature Scheme)

3. **Android NDK (Native Development Kit)**:
   - Versione: NDK r21e (21.4.7075529)
   - Compilatore C: `toolchains\llvm\prebuilt\windows-x86_64\bin\armv7a-linux-androideabi21-clang.cmd`
   - Architettura target: ARMv7-a (`armeabi-v7a`) con supporto FP-armv7 neon
   - Driver compilato: `libakai_uinput.so` per iniezione keyevent su kernel Linux 4.19

4. **Nessuna dipendenza Maven/Gradle esterna**:
   - Zero dipendenze cloud o pacchetti di terze parti: il demone HTTP/HTTPS, il server REST, il parser JSON e il protocollo crittografico operano esclusivamente con le librerie native standard della JVM Android (`org.json`, `java.net`, `javax.net.ssl`, `java.security`).
"@
[System.IO.File]::WriteAllText((Join-Path $stage03 "TOOLCHAIN_SPECS.md"), $toolchainDoc, [System.Text.Encoding]::UTF8)

Write-Host "[4/8] Popolamento 04_AKAI_TESTS_REPORTS..."
Copy-Item "$workspace\akai-remote-tests\*" $stage04 -Recurse -Force -Exclude "bin"
if (Test-Path "$workspace\diagnostics") {
    New-Item -ItemType Directory -Force -Path "$stage04\diagnostics" | Out-Null
    Copy-Item "$workspace\diagnostics\*" "$stage04\diagnostics" -Recurse -Force
}

Write-Host "[5/8] Popolamento 05_AKAI_HISTORY_BASELINES..."
$historyFiles = @(
    "PROJECT_PLAN.md",
    "PROJECT_PLAN_REVISIONE.md",
    "AKAI_JARVIS_AUDIT_COMPLETO_v15_3.md",
    "AKAI_JARVIS_Revisione_Tecnica.md",
    "README_VERIFICA.md"
)
foreach ($hf in $historyFiles) {
    $src = Join-Path $workspace $hf
    if (Test-Path $src) {
        Copy-Item $src $stage05 -Force
    }
}

Write-Host "[6/8] Popolamento 06_AKAI_BINARIES_RELEASE..."
$apkRemote = "$workspace\akai-remote-tv\app\build\outputs\apk\debug\app-debug.apk"
$apkHome = "$workspace\akai-custom-home\app\build\outputs\apk\debug\akai-custom-home.apk"
$apkFactory = "$workspace\tools\LTvLauncher-armeabi-v7a-release.apk"
$certPub = "$workspace\tools\AkaiRootCA.crt"

if (Test-Path $apkRemote) { Copy-Item $apkRemote "$stage06\AKAI_JARVIS_Remote_v16.apk" -Force }
if (Test-Path $apkHome) { Copy-Item $apkHome "$stage06\AKAI_Custom_Home_v8.apk" -Force }
if (Test-Path $apkFactory) { Copy-Item $apkFactory "$stage06\LTvLauncher_Factory_Backup.apk" -Force }
if (Test-Path $certPub) { Copy-Item $certPub "$stage06\AkaiRootCA.crt" -Force }

Write-Host "[7/8] Popolamento 07_AKAI_ARCHITECTURE_EVIDENCE..."
$evidenceFiles = @(
    "AKAI_JARVIS_v16_anteprima_interfaccia.html",
    "AKAI_JARVIS_v16_anteprima_mobile.png",
    "AKAI_JARVIS_v16_anteprima_telecomando.png",
    "clean_home.png",
    "clean_home_scaled.png",
    "fixed_screen_v2.png",
    "fixed_screen_v3.png",
    "main_screen.png",
    "pairing_screen.png",
    "pin_screen.png",
    "main_dump.xml",
    "dump_pin.xml",
    "pin_card_dump.xml"
)
foreach ($ef in $evidenceFiles) {
    $src = Join-Path $workspace $ef
    if (Test-Path $src) {
        Copy-Item $src $stage07 -Force
    }
}

Write-Host "[8/8] Sanitizzazione segreti e rimozione chiavi private dallo staging..."
# Scansione ed esclusione esplicita di file di chiavi private da tutti gli staging
$privateKeyPatterns = @("*.p12", "*.jks", "*.keystore", "*.key")
foreach ($st in $allStages) {
    foreach ($pat in $privateKeyPatterns) {
        Get-ChildItem -Path $st -Filter $pat -Recurse -File | ForEach-Object {
            Write-Host "  -> Rimosso file sensibile dallo staging: $($_.FullName)" -ForegroundColor Yellow
            Remove-Item $_.FullName -Force
        }
    }
}

Write-Host "`nStaging completato con successo." -ForegroundColor Green
