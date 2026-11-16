$ErrorActionPreference = "Stop"

$workspace = (Get-Item $PSScriptRoot).Parent.FullName
$toolsDir = Join-Path $workspace "tools"
$jdkDir = Join-Path $toolsDir "jdk-17"
$sdkDir = Join-Path $toolsDir "android-sdk"
$buildToolsDir = Join-Path $sdkDir "build-tools\28.0.3"
$platformJar = Join-Path $sdkDir "platforms\android-28\android.jar"
$aapt2 = Join-Path $buildToolsDir "aapt2.exe"
$javac = Join-Path $jdkDir "bin\javac.exe"

$appDir = Join-Path $workspace "akai-remote-tv\app"
$srcDir = Join-Path $appDir "src\main"
$manifestPath = Join-Path $srcDir "AndroidManifest.xml"
$resDir = Join-Path $srcDir "res"
$javaDir = Join-Path $srcDir "java"

$buildDir = Join-Path $appDir "build\compile_check"
$genDir = Join-Path $buildDir "gen"
$classesDir = Join-Path $buildDir "classes"
$compiledResZip = Join-Path $buildDir "compiled_res.zip"
$baseApk = Join-Path $buildDir "base.apk"

if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $genDir | Out-Null
New-Item -ItemType Directory -Force -Path $classesDir | Out-Null

Write-Host "Generazione R.java con AAPT2..."
& $aapt2 compile --dir $resDir -o $compiledResZip
& $aapt2 link -I $platformJar --manifest $manifestPath -o $baseApk --java $genDir $compiledResZip --auto-add-overlay --min-sdk-version 21 --target-sdk-version 28

$javaFiles = Get-ChildItem -Path $javaDir, $genDir -Filter "*.java" -Recurse | Select-Object -ExpandProperty FullName
Write-Host "Compilazione di $($javaFiles.Count) classi Java con javac (target 1.8)..."

& $javac -encoding UTF-8 -source 1.8 -target 1.8 -bootclasspath $platformJar -cp $platformJar -d $classesDir $javaFiles

if ($LASTEXITCODE -eq 0) {
    $classCount = (Get-ChildItem -Path $classesDir -Filter "*.class" -Recurse).Count
    Write-Host "COMPILAZIONE ANDROID JAVA RIUSCITA: $classCount classi prodotte con successo!" -ForegroundColor Green
} else {
    Write-Host "ERRORE durante javac!" -ForegroundColor Red
    exit 1
}
