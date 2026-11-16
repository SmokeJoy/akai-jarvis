# ==============================================================================
# Script per Compilazione ed Esecuzione Test Unitari AKAI Custom Home v8
# ==============================================================================
$ErrorActionPreference = "Stop"

$workspace = "C:\Users\danie\OneDrive\Documenti\Antygravity\Akay"
$toolsDir = Join-Path $workspace "tools"
$jdkDir = Join-Path $toolsDir "jdk-17"
$javac = Join-Path $jdkDir "bin\javac.exe"
$java = Join-Path $jdkDir "bin\java.exe"

$testBuildDir = Join-Path $workspace "akai-custom-home\test_bin"
if (Test-Path $testBuildDir) { Remove-Item $testBuildDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $testBuildDir | Out-Null

$mockSources = Get-ChildItem -Recurse -Path (Join-Path $workspace "akai-custom-home\test\host_mock") -Filter "*.java" | Select-Object -ExpandProperty FullName
$appSources = Get-ChildItem -Path (Join-Path $workspace "akai-custom-home\app\src\main\java\it\akai\customhome") -Filter "*.java" | Select-Object -ExpandProperty FullName
$testSources = Join-Path $workspace "akai-custom-home\test\it\akai\customhome\LauncherUnitTests.java"

$allSources = @()
$allSources += $mockSources
$allSources += $appSources
$allSources += $testSources

Write-Host "Compilazione test unitari Launcher v8..." -ForegroundColor Cyan
& $javac -encoding UTF-8 -d $testBuildDir $allSources
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERRORE durante javac!" -ForegroundColor Red
    exit 1
}

Write-Host "Esecuzione test unitari Launcher v8..." -ForegroundColor Cyan
& $java -cp $testBuildDir it.akai.customhome.LauncherUnitTests
if ($LASTEXITCODE -ne 0) {
    Write-Host "TEST FALLITI!" -ForegroundColor Red
    exit 1
}
