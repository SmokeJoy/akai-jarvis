$ErrorActionPreference = "Stop"

$workspace = "C:\Users\danie\OneDrive\Documenti\Antygravity\Akay"
$toolsDir = Join-Path $workspace "tools"
$jdkDir = Join-Path $toolsDir "jdk-17"
$javac = Join-Path $jdkDir "bin\javac.exe"
$java = Join-Path $jdkDir "bin\java.exe"

$testBuildDir = Join-Path $workspace "akai-remote-tests\bin"
if (Test-Path $testBuildDir) { Remove-Item $testBuildDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $testBuildDir | Out-Null

$mockSources = Get-ChildItem -Recurse -Path (Join-Path $workspace "akai-remote-tests\host_mock") -Filter "*.java" | Select-Object -ExpandProperty FullName
$qrSources = Get-ChildItem -Path (Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\qr") -Filter "*.java" | Where-Object { $_.Name -ne "QrBitmapUtil.java" } | Select-Object -ExpandProperty FullName
$securityMgr = Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\SecurityManager.java"
$uinputSrc = Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\UInputDriver.java"
$commandResultSrc = Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\CommandResult.java"
$routerSrc = Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\RestApiRouter.java"
$localIntentSrc = Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\ai\LocalIntentParser.java"
$unitTestSrc = Join-Path $workspace "akai-remote-tests\UnitTests.java"

$allSources = @() + $mockSources + $qrSources + @($securityMgr, $uinputSrc, $commandResultSrc, $routerSrc, $localIntentSrc, $unitTestSrc)

Write-Host "Compilazione test unitari per SecurityManager e QR Code..."
& $javac -encoding UTF-8 -d $testBuildDir $allSources

Write-Host "Esecuzione test unitari:"
& $java -cp $testBuildDir it.akai.customremote.UnitTests
