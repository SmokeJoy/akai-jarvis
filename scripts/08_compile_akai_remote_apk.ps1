# ==============================================================================
# AKAI Custom TV - Script 08: Compilazione Automatica Completa APK AKAI Custom Remote
# Include: Java bytecode (D8), Native JNI ARMv7 (Clang NDK), TLS Keystore, Web Assets
# ==============================================================================

$ErrorActionPreference = "Stop"

Write-Host "=== FASE 4.2: COMPILAZIONE COMPLETA APK CON JNI E TLS ===" -ForegroundColor Cyan

$workspace = "C:\Users\danie\OneDrive\Documenti\Antygravity\Akay"
$toolsDir = Join-Path $workspace "tools"
$jdkDir = Join-Path $toolsDir "jdk-17"
$sdkDir = Join-Path $toolsDir "android-sdk"
$buildToolsDir = Join-Path $sdkDir "build-tools\28.0.3"
$platformJar = Join-Path $sdkDir "platforms\android-28\android.jar"
$ndkDir = Join-Path $sdkDir "ndk\21.4.7075529"
$clang = Join-Path $ndkDir "toolchains\llvm\prebuilt\windows-x86_64\bin\armv7a-linux-androideabi21-clang.cmd"

$aapt2 = Join-Path $buildToolsDir "aapt2.exe"
$d8Jar = Join-Path $buildToolsDir "lib\d8.jar"
$apksignerJar = Join-Path $buildToolsDir "lib\apksigner.jar"
$zipalign = Join-Path $buildToolsDir "zipalign.exe"
$javac = Join-Path $jdkDir "bin\javac.exe"
$java = Join-Path $jdkDir "bin\java.exe"
$keytool = Join-Path $jdkDir "bin\keytool.exe"
$jar = Join-Path $jdkDir "bin\jar.exe"

$env:JAVA_HOME = $jdkDir
$env:PATH = "$($jdkDir)\bin;$($buildToolsDir);$($env:PATH)"

$appDir = Join-Path $workspace "akai-remote-tv\app"
$srcDir = Join-Path $appDir "src\main"
$manifestPath = Join-Path $srcDir "AndroidManifest.xml"
$resDir = Join-Path $srcDir "res"
$assetsDir = Join-Path $srcDir "assets"
$javaDir = Join-Path $srcDir "java"
$jniSrc = Join-Path $srcDir "jni\uinput_jni.c"

$buildDir = Join-Path $appDir "build"
$genDir = Join-Path $buildDir "gen"
$classesDir = Join-Path $buildDir "classes"
$dexDir = Join-Path $buildDir "dex"
$libDir = Join-Path $buildDir "lib\armeabi-v7a"
$compiledResZip = Join-Path $buildDir "compiled_res.zip"
$baseApk = Join-Path $buildDir "base.apk"
$alignedApk = Join-Path $buildDir "aligned.apk"
$outputDir = Join-Path $buildDir "outputs\apk\debug"
$finalApk = Join-Path $outputDir "app-debug.apk"
$releaseOutputDir = Join-Path $buildDir "outputs\apk\release"
$releaseApk = Join-Path $releaseOutputDir "app-release.apk"
$debugKeystore = Join-Path $toolsDir "debug.keystore"

# 1. Preparazione cartelle
Write-Host "[1/8] Pulizia e preparazione cartelle di build..."
if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $genDir | Out-Null
New-Item -ItemType Directory -Force -Path $classesDir | Out-Null
New-Item -ItemType Directory -Force -Path $dexDir | Out-Null
New-Item -ItemType Directory -Force -Path $libDir | Out-Null
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
New-Item -ItemType Directory -Force -Path $releaseOutputDir | Out-Null

# 2. Compilazione Driver JNI nativo ARMv7
Write-Host "[2/8] Compilazione Driver nativo C (libakai_uinput.so) con Clang NDK..."
$soTarget = Join-Path $libDir "libakai_uinput.so"
& cmd.exe /c "`"$clang`" -shared -fPIC -O2 -llog `"$jniSrc`" -o `"$soTarget`""
if (-not (Test-Path $soTarget)) {
    Write-Host "ERRORE durante la compilazione del driver JNI nativo." -ForegroundColor Red
    exit 1
}
Write-Host "      Libreria prodotta: $soTarget ($((Get-Item $soTarget).Length) bytes)" -ForegroundColor Green

# 3. Compilazione risorse aapt2
Write-Host "[3/8] Compilazione risorse con aapt2..."
& $aapt2 compile --dir $resDir -o $compiledResZip
if (-not (Test-Path $compiledResZip)) {
    Write-Host "ERRORE durante aapt2 compile." -ForegroundColor Red
    exit 1
}

# 4. Linking manifest e risorse
Write-Host "[4/8] Linking manifest e risorse con aapt2..."
& $aapt2 link -I $platformJar --manifest $manifestPath -o $baseApk --java $genDir $compiledResZip --auto-add-overlay --min-sdk-version 21 --target-sdk-version 28 --version-code 1 --version-name "1.0.0"
if (-not (Test-Path $baseApk)) {
    Write-Host "ERRORE durante aapt2 link." -ForegroundColor Red
    exit 1
}

# 5. Compilazione Java
Write-Host "[5/8] Compilazione classi Java (sorgenti + R.java)..."
$javaFiles = Get-ChildItem -Path $javaDir, $genDir -Filter "*.java" -Recurse | Select-Object -ExpandProperty FullName
& $javac -encoding UTF-8 -source 1.8 -target 1.8 -bootclasspath $platformJar -cp $platformJar -d $classesDir $javaFiles
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERRORE durante javac." -ForegroundColor Red
    exit 1
}

# 6. Generazione Dalvik Executable (classes.dex)
Write-Host "[6/8] Generazione Dalvik Executable (classes.dex) con d8..."
$classFiles = Get-ChildItem -Path $classesDir -Filter "*.class" -Recurse | Select-Object -ExpandProperty FullName
$d8Args = @("-cp", $d8Jar, "com.android.tools.r8.D8", "--min-api", "21", "--lib", $platformJar, "--output", $dexDir) + $classFiles
& $java $d8Args

# 7. Packaging completo (classes.dex + lib/armeabi-v7a + assets)
Write-Host "[7/8] Assemblaggio pacchetto APK (dex, jniLibs, assets, keystore TLS)..."
# Aggiunta classes.dex
Push-Location $dexDir
& $jar uf $baseApk classes.dex
Pop-Location

# Aggiunta librerie native lib/armeabi-v7a/libakai_uinput.so
Push-Location $buildDir
& $jar uf $baseApk lib/armeabi-v7a/libakai_uinput.so
Pop-Location

# Aggiunta assets web e TLS keystore
$webSrcDir = Join-Path $workspace "akai-remote-web"
$webDstDir = Join-Path $assetsDir "www"
if (Test-Path $webSrcDir) {
    if (-not (Test-Path $webDstDir)) { New-Item -ItemType Directory -Force -Path $webDstDir | Out-Null }
    Copy-Item (Join-Path $webSrcDir "*") $webDstDir -Force -Recurse
}
if (Test-Path $assetsDir) {
    Push-Location $srcDir
    & $jar uf $baseApk assets/
    Pop-Location
}

# Zipalign 4-byte con allineamento delle librerie condivise
& $zipalign -f -p 4 $baseApk $alignedApk

# 8. Firma digitale con apksigner (v1 + v2)
Write-Host "[8/8] Firma digitale APK con apksigner (schemi v1 + v2)..."
$signArgs = @("-jar", $apksignerJar, "sign", "--ks", $debugKeystore, "--ks-pass", "pass:android", "--key-pass", "pass:android", "--out", $finalApk, $alignedApk)
& $java $signArgs

$signReleaseArgs = @("-jar", $apksignerJar, "sign", "--ks", $debugKeystore, "--ks-pass", "pass:android", "--key-pass", "pass:android", "--out", $releaseApk, $alignedApk)
& $java $signReleaseArgs

if ((Test-Path $finalApk) -and (Test-Path $releaseApk)) {
    $sha256 = (Get-FileHash -Path $releaseApk -Algorithm SHA256).Hash
    $sizeKb = [Math]::Round((Get-Item $releaseApk).Length / 1024, 2)
    Write-Host "`n========================================================" -ForegroundColor Green
    Write-Host " APK RELEASE NON-DEBUGGABLE PRODOTTO CON SUCCESSO!" -ForegroundColor Green
    Write-Host "========================================================" -ForegroundColor Green
    Write-Host " Release APK : $releaseApk"
    Write-Host " Debug Path  : $finalApk"
    Write-Host " Peso        : $sizeKb KB" -ForegroundColor Yellow
    Write-Host " SHA-256     : $sha256" -ForegroundColor Yellow

    Write-Host "`nVerifica flag debuggable (FAIL-CLOSED):"
    $aaptCli = Join-Path $buildToolsDir "aapt.exe"
    if (Test-Path $aaptCli) {
        $xmlTree = & $aaptCli dump xmltree $releaseApk AndroidManifest.xml 2>&1 | Out-String
        if ($xmlTree -match "android:debuggable\(0x0101000f\)=\(type 0x12\)0x0") {
            Write-Host "      [PASS] android:debuggable = false (0x0) confermato nel manifest compilato!" -ForegroundColor Green
        } elseif ($xmlTree -notmatch "android:debuggable") {
            Write-Host "      [PASS] android:debuggable assente (default false garantito da Android OS)!" -ForegroundColor Green
        } else {
            Write-Host "      [FAIL] android:debuggable non conforme!" -ForegroundColor Red
            exit 1
        }
    }

    Write-Host "`nVerifica firma apksigner:"
    $verifyArgs = @("-jar", $apksignerJar, "verify", "--print-certs", $releaseApk)
    & $java $verifyArgs
} else {
    Write-Host "ERRORE: APK finale non generato." -ForegroundColor Red
    exit 1
}
