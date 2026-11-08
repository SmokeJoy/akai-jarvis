# ==============================================================================
# AKAI Custom TV - Script 09: Compilazione Automatica Standalone AKAI Custom Home
# Pacchetto autonomo: it.akai.customhome
# ==============================================================================

$ErrorActionPreference = "Stop"

Write-Host "=== COMPILAZIONE STANDALONE AKAI CUSTOM HOME (it.akai.customhome) ===" -ForegroundColor Cyan

$workspace = "C:\Users\danie\OneDrive\Documenti\Antygravity\Akay"
$toolsDir = Join-Path $workspace "tools"
$jdkDir = Join-Path $toolsDir "jdk-17"
$sdkDir = Join-Path $toolsDir "android-sdk"
$buildToolsDir = Join-Path $sdkDir "build-tools\28.0.3"
$platformJar = Join-Path $sdkDir "platforms\android-28\android.jar"

$aapt2 = Join-Path $buildToolsDir "aapt2.exe"
$d8Jar = Join-Path $buildToolsDir "lib\d8.jar"
$apksignerJar = Join-Path $buildToolsDir "lib\apksigner.jar"
$zipalign = Join-Path $buildToolsDir "zipalign.exe"
$javac = Join-Path $jdkDir "bin\javac.exe"
$java = Join-Path $jdkDir "bin\java.exe"
$jar = Join-Path $jdkDir "bin\jar.exe"

$env:JAVA_HOME = $jdkDir
$env:PATH = "$($jdkDir)\bin;$($buildToolsDir);$($env:PATH)"

$appDir = Join-Path $workspace "akai-custom-home\app"
$srcDir = Join-Path $appDir "src\main"
$manifestPath = Join-Path $srcDir "AndroidManifest.xml"
$resDir = Join-Path $srcDir "res"
$javaDir = Join-Path $srcDir "java"

$buildDir = Join-Path $appDir "build"
$genDir = Join-Path $buildDir "gen"
$classesDir = Join-Path $buildDir "classes"
$dexDir = Join-Path $buildDir "dex"
$compiledResZip = Join-Path $buildDir "compiled_res.zip"
$baseApk = Join-Path $buildDir "base.apk"
$alignedApk = Join-Path $buildDir "aligned.apk"
$outputDir = Join-Path $buildDir "outputs\apk\debug"
$finalApk = Join-Path $outputDir "akai-custom-home.apk"
$debugKeystore = Join-Path $toolsDir "debug.keystore"

# 1. Pulizia cartelle
Write-Host "[1/6] Pulizia e preparazione cartelle di build..."
if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $genDir | Out-Null
New-Item -ItemType Directory -Force -Path $classesDir | Out-Null
New-Item -ItemType Directory -Force -Path $dexDir | Out-Null
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

# 2. Compilazione risorse aapt2
Write-Host "[2/6] Compilazione risorse con aapt2..."
& $aapt2 compile --dir $resDir -o $compiledResZip
if (-not (Test-Path $compiledResZip)) {
    Write-Host "ERRORE durante aapt2 compile." -ForegroundColor Red
    exit 1
}

# 3. Linking manifest e risorse
Write-Host "[3/6] Linking manifest e risorse con aapt2..."
& $aapt2 link -I $platformJar --manifest $manifestPath -o $baseApk --java $genDir $compiledResZip --auto-add-overlay --min-sdk-version 21 --target-sdk-version 28 --version-code 8 --version-name "8.0.0"
if (-not (Test-Path $baseApk)) {
    Write-Host "ERRORE durante aapt2 link." -ForegroundColor Red
    exit 1
}

# 4. Compilazione Java
Write-Host "[4/6] Compilazione classi Java (sorgenti + R.java)..."
$javaFiles = Get-ChildItem -Path $javaDir, $genDir -Filter "*.java" -Recurse | Select-Object -ExpandProperty FullName
& $javac -encoding UTF-8 -source 1.8 -target 1.8 -bootclasspath $platformJar -cp $platformJar -d $classesDir $javaFiles
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERRORE durante javac." -ForegroundColor Red
    exit 1
}

# 5. Generazione DEX con d8
Write-Host "[5/6] Generazione Dalvik Executable (classes.dex) con d8..."
$classFiles = Get-ChildItem -Path $classesDir -Filter "*.class" -Recurse | Select-Object -ExpandProperty FullName
$d8Args = @("-cp", $d8Jar, "com.android.tools.r8.D8", "--min-api", "21", "--lib", $platformJar, "--output", $dexDir) + $classFiles
& $java $d8Args

# Packaging e Zipalign
Push-Location $dexDir
& $jar uf $baseApk classes.dex
Pop-Location

& $zipalign -f -p 4 $baseApk $alignedApk

# 6. Firma digitale
Write-Host "[6/6] Firma digitale con apksigner (v1 + v2)..."
$signArgs = @("-jar", $apksignerJar, "sign", "--ks", $debugKeystore, "--ks-pass", "pass:android", "--key-pass", "pass:android", "--out", $finalApk, $alignedApk)
& $java $signArgs

if (Test-Path $finalApk) {
    $v8Apk = Join-Path $outputDir "akai-custom-home-v8.apk"
    Copy-Item $finalApk $v8Apk -Force
    $sha256 = (Get-FileHash -Path $finalApk -Algorithm SHA256).Hash
    $sizeKb = [Math]::Round((Get-Item $finalApk).Length / 1024, 2)
    Write-Host "`n========================================================" -ForegroundColor Green
    Write-Host " AKAI CUSTOM HOME v8 LEANBACK COMPILATO CON SUCCESSO!" -ForegroundColor Green
    Write-Host "========================================================" -ForegroundColor Green
    Write-Host " APK File : $finalApk"
    Write-Host " Copia v8 : $v8Apk" -ForegroundColor Cyan
    Write-Host " Peso     : $sizeKb KB" -ForegroundColor Yellow
    Write-Host " SHA-256  : $sha256" -ForegroundColor Yellow
} else {
    Write-Host "ERRORE: APK finale non trovato." -ForegroundColor Red
    exit 1
}
