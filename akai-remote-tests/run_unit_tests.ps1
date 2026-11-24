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
$serviceStateSrc = Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\ServiceStateListener.java"
$rebindCtrlSrc = Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\HttpsRebindController.java"
$securityMgr = Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\SecurityManager.java"
$uinputSrc = Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\UInputDriver.java"
$commandResultSrc = Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\CommandResult.java"
$tvAppPackagesSrc = Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\TvAppPackages.java"
$tlsCertSrc = Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\TlsCertificateManager.java"
$routerSrc = Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\RestApiRouter.java"
$localIntentSrc = Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\ai\LocalIntentParser.java"
$keystoreSrc = Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\ai\KeystoreSecurityHelper.java"
$providerPolicySrc = Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\ai\CloudProviderPolicy.java"
$cloudVisionPolicySrc = Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\ai\CloudVisionRequestPolicy.java"
$visualObservationBridgeSrc = Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\ai\VisualObservationBridge.java"
$visualCaptureSessionGateSrc = Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\ai\VisualCaptureSessionGate.java"
$frameSequenceGateSrc = Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\ai\FrameSequenceGate.java"
$procedureGoalMatcherSrc = Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\ai\ProcedureGoalMatcher.java"
$visualObservationProviderSrc = Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\ai\VisualObservationProvider.java"
$visualStepPolicySrc = Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\ai\VisualStepPolicy.java"
$aiAdapterSrc = Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\ai\AiProviderAdapter.java"
$perceptionSrc = Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\ai\ScreenPerceptionEngine.java"
$aiControllerSrc = Join-Path $workspace "akai-remote-tv\app\src\main\java\it\akai\customremote\ai\AkaiAiController.java"
$unitTestSrc = Join-Path $workspace "akai-remote-tests\UnitTests.java"

$allSources = @() + $mockSources + $qrSources + @($serviceStateSrc, $rebindCtrlSrc, $securityMgr, $uinputSrc, $commandResultSrc, $tvAppPackagesSrc, $tlsCertSrc, $routerSrc, $localIntentSrc, $keystoreSrc, $providerPolicySrc, $cloudVisionPolicySrc, $visualObservationBridgeSrc, $visualCaptureSessionGateSrc, $frameSequenceGateSrc, $procedureGoalMatcherSrc, $visualObservationProviderSrc, $visualStepPolicySrc, $aiAdapterSrc, $perceptionSrc, $aiControllerSrc, $unitTestSrc)

Write-Host "Compilazione test unitari per SecurityManager e QR Code..."
& $javac -encoding UTF-8 -d $testBuildDir $allSources
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Esecuzione test unitari:"
& $java -cp $testBuildDir it.akai.customremote.UnitTests
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
