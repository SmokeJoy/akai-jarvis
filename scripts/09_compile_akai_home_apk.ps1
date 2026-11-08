# ==============================================================================
# AKAI Custom TV - Script 09: Compilazione Standalone AKAI Custom Home v8
# Supporta build standard, build parallela (-PackageId), rimozione HOME
# (-ExcludeHomeIntent), versionamento esplicito (-VersionCode >= 9) e
# firma dedicata (-SigningMode release) con passaggio credenziali protetto
# esclusivamente tramite env:, file: esterno al repo o prompt SecureString
# (ZERO password in chiaro negli argomenti CLI di processo).
# ==============================================================================

param(
    [string]$PackageId = "it.akai.customhome",
    [int]$VersionCode = 9,
    [string]$VersionName = "8.1.0",
    [ValidateSet("debug", "release")]
    [string]$SigningMode = "debug",
    [string]$KeystorePath = "",
    [string]$KeyAlias = "",
    [string]$StorePassEnvVar = "AKAI_RELEASE_KS_PASS",
    [string]$KeyPassEnvVar = "AKAI_RELEASE_KEY_PASS",
    [string]$PassFile = "",
    [string]$AppLabel = "",
    [switch]$ExcludeHomeIntent = $false
)

$ErrorActionPreference = "Stop"

if ($PackageId -notmatch '^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$') {
    throw "PackageId non valido per Android: '$PackageId'."
}
if ($VersionCode -le 0) {
    throw "VersionCode deve essere > 0 (fornito: $VersionCode)."
}
if ($VersionCode -le 8) {
    Write-Warning "VersionCode=$VersionCode <= 8: la baseline v7 (ea2f35e) usava gia' versionCode=8; consigliato >= 9 per evitare collisioni."
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = $PSScriptRoot }
if ($scriptDir) {
    $workspace = (Resolve-Path (Join-Path $scriptDir "..")).Path
} else {
    $workspace = (Get-Location).Path
}

function Test-IsPathInsideDirectory([string]$CandidatePath, [string]$DirectoryPath) {
    $fullCand = [System.IO.Path]::GetFullPath($CandidatePath).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $fullDir = [System.IO.Path]::GetFullPath($DirectoryPath).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    return $fullCand.StartsWith($fullDir, [System.StringComparison]::OrdinalIgnoreCase)
}

function Convert-SecureStringToPlainText([System.Security.SecureString]$Sec) {
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Sec)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

$toolsDir = Join-Path $workspace "tools"
$jdkDir = Join-Path $toolsDir "jdk-17"
$sdkDir = Join-Path $toolsDir "android-sdk"
$buildToolsDir = Join-Path $sdkDir "build-tools\28.0.3"
$platformJar = Join-Path $sdkDir "platforms\android-28\android.jar"

$aapt2 = Join-Path $buildToolsDir "aapt2.exe"
$aapt = Join-Path $buildToolsDir "aapt.exe"
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
$stagingManifestDir = Join-Path $buildDir "staging_manifest"
$compiledResZip = Join-Path $buildDir "compiled_res.zip"
$baseApk = Join-Path $buildDir "base.apk"
$alignedApk = Join-Path $buildDir "aligned.apk"
$debugKeystore = Join-Path $toolsDir "debug.keystore"

# Selezione e validazione fail-closed del certificato e del canale protetto credenziali
$resolvedKeystore = ""
$resolvedAlias = ""
$signingChannel = ""
$ksPassSpec = ""
$keyPassSpec = ""
$tempEnvVarsToClear = @()

if ($SigningMode -eq "release") {
    if ([string]::IsNullOrWhiteSpace($KeystorePath)) {
        throw "FIRMA RELEASE BLOCCATA: specificare -KeystorePath verso una keystore dedicata fuori da git."
    }
    if (-not (Test-Path $KeystorePath)) {
        throw "FIRMA RELEASE BLOCCATA: keystore non trovata nel percorso specificato."
    }
    $resolvedKeystore = (Resolve-Path $KeystorePath).Path
    if (Test-IsPathInsideDirectory $resolvedKeystore $workspace) {
        throw "FIRMA RELEASE BLOCCATA: la keystore release deve risiedere FUORI dal repository git ($workspace)."
    }
    $debugNorm = if (Test-Path $debugKeystore) { (Resolve-Path $debugKeystore).Path } else { "" }
    if ($resolvedKeystore -eq $debugNorm -or (Split-Path -Leaf $resolvedKeystore) -ieq "debug.keystore") {
        throw "FIRMA RELEASE BLOCCATA: vietato usare debug.keystore in modalita' -SigningMode release."
    }
    if ([string]::IsNullOrWhiteSpace($KeyAlias)) {
        throw "FIRMA RELEASE BLOCCATA: specificare -KeyAlias per la keystore release."
    }
    $resolvedAlias = $KeyAlias

    if (-not [string]::IsNullOrWhiteSpace($PassFile)) {
        if (-not (Test-Path $PassFile)) {
            throw "FIRMA RELEASE BLOCCATA: -PassFile non trovato."
        }
        $resolvedPassFile = (Resolve-Path $PassFile).Path
        if (Test-IsPathInsideDirectory $resolvedPassFile $workspace) {
            throw "FIRMA RELEASE BLOCCATA: il file password deve risiedere FUORI dal repository git ($workspace)."
        }
        $lineCount = @(Get-Content -Path $resolvedPassFile -ErrorAction Stop | Where-Object { $_ -ne "" }).Count
        if ($lineCount -lt 1) {
            throw "FIRMA RELEASE BLOCCATA: -PassFile vuoto."
        }
        $ksPassSpec = "file:$resolvedPassFile"
        if ($lineCount -ge 2) {
            $keyPassSpec = "file:$resolvedPassFile"
        }
        $signingChannel = "file"
    } else {
        if ([string]::IsNullOrWhiteSpace($StorePassEnvVar) -or $StorePassEnvVar -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw "FIRMA RELEASE BLOCCATA: nome variabile -StorePassEnvVar non valido."
        }
        $envKsVal = [System.Environment]::GetEnvironmentVariable($StorePassEnvVar)
        if (-not [string]::IsNullOrEmpty($envKsVal)) {
            $ksPassSpec = "env:$StorePassEnvVar"
            $signingChannel = "env:$StorePassEnvVar"
            if (-not [string]::IsNullOrWhiteSpace($KeyPassEnvVar) -and $KeyPassEnvVar -match '^[A-Za-z_][A-Za-z0-9_]*$') {
                $envKeyVal = [System.Environment]::GetEnvironmentVariable($KeyPassEnvVar)
                if (-not [string]::IsNullOrEmpty($envKeyVal)) {
                    $keyPassSpec = "env:$KeyPassEnvVar"
                }
            }
        } else {
            # Fallback interattivo sicuro via SecureString -> variabile env efimera con scrub garantito in finally{}
            $secKs = Read-Host -Prompt "Password Keystore Release ($resolvedAlias)" -AsSecureString
            $plainKs = Convert-SecureStringToPlainText $secKs
            if ([string]::IsNullOrEmpty($plainKs)) {
                throw "FIRMA RELEASE BLOCCATA: password keystore vuota."
            }
            $ephemKsVar = "AKAI_APKSIGN_KS_PASS"
            [System.Environment]::SetEnvironmentVariable($ephemKsVar, $plainKs, "Process")
            $plainKs = $null
            $tempEnvVarsToClear += $ephemKsVar
            $ksPassSpec = "env:$ephemKsVar"
            $signingChannel = "prompt-secure-env"
        }
    }
} else {
    if (-not (Test-Path $debugKeystore)) {
        throw "debug.keystore locale non trovata in $debugKeystore."
    }
    $resolvedKeystore = (Resolve-Path $debugKeystore).Path
    $resolvedAlias = "androiddebugkey"
    $ephemDbgVar = "AKAI_APKSIGN_DBG_PASS"
    [System.Environment]::SetEnvironmentVariable($ephemDbgVar, "android", "Process")
    $tempEnvVarsToClear += $ephemDbgVar
    $ksPassSpec = "env:$ephemDbgVar"
    $keyPassSpec = "env:$ephemDbgVar"
    $signingChannel = "env:$ephemDbgVar"
    Write-Warning "Build firmata con debug.keystore locale (SOLO test locale/emulatore, NON release definitiva)."
}

try {
    $isParallel = ($PackageId -ne "it.akai.customhome")
    $variantSuffix = @("vc$VersionCode", $SigningMode)
    if ($isParallel) { $variantSuffix += "parallel" }
    if ($ExcludeHomeIntent) { $variantSuffix += "nohome" }
    $variantTag = $variantSuffix -join "-"

    $outputSubDir = if ($SigningMode -eq "release") { "outputs\apk\release" } else { "outputs\apk\debug" }
    $outputDir = Join-Path $buildDir $outputSubDir
    $versionedApk = Join-Path $outputDir "akai-custom-home-$variantTag.apk"
    $buildInfoPath = Join-Path $outputDir "akai-custom-home-$variantTag.build-info.txt"

    Write-Host "=== COMPILAZIONE STANDALONE AKAI CUSTOM HOME v8 ($PackageId) ===" -ForegroundColor Cyan
    Write-Host "  Package        : $PackageId"
    Write-Host "  Version        : $VersionName (versionCode=$VersionCode)"
    Write-Host "  SigningMode    : $SigningMode (canale=$signingChannel)"
    Write-Host "  HOME Filter    : $(if ($ExcludeHomeIntent) { 'ESCLUSO (preview isolata via am start)' } else { 'INCLUSO (MainActivity + CATEGORY_HOME)' })"

    # 1. Pulizia artefatti intermedi (preservando build\outputs\apk)
    Write-Host "`n[1/6] Preparazione cartelle di build (intermediates clean)..."
    foreach ($cleanPath in @($genDir, $classesDir, $dexDir, $stagingManifestDir, $compiledResZip, $baseApk, $alignedApk)) {
        if (Test-Path $cleanPath) { Remove-Item $cleanPath -Recurse -Force }
    }
    New-Item -ItemType Directory -Force -Path $genDir | Out-Null
    New-Item -ItemType Directory -Force -Path $classesDir | Out-Null
    New-Item -ItemType Directory -Force -Path $dexDir | Out-Null
    New-Item -ItemType Directory -Force -Path $stagingManifestDir | Out-Null
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

    # Staging controllato di AndroidManifest.xml solo se richiesto override manifest/HOME/label
    $effectiveManifest = $manifestPath
    if ($ExcludeHomeIntent -or -not [string]::IsNullOrWhiteSpace($AppLabel)) {
        [xml]$manifestXml = Get-Content -Path $manifestPath -Raw -Encoding UTF8
        $nsAndroid = "http://schemas.android.com/apk/res/android"
        if ($ExcludeHomeIntent) {
            $filters = @($manifestXml.manifest.application.activity.'intent-filter')
            foreach ($filter in $filters) {
                if ($null -eq $filter) { continue }
                $cats = @($filter.category)
                $hasHome = $false
                foreach ($cat in $cats) {
                    $catName = $cat.GetAttribute("name", $nsAndroid)
                    if ($catName -eq "android.intent.category.HOME") {
                        $hasHome = $true
                        break
                    }
                }
                if ($hasHome) {
                    [void]$filter.ParentNode.RemoveChild($filter)
                }
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($AppLabel)) {
            $null = $manifestXml.manifest.application.SetAttribute("label", $nsAndroid, $AppLabel)
            $null = $manifestXml.manifest.application.activity.SetAttribute("label", $nsAndroid, $AppLabel)
        }
        $stagedManifestPath = Join-Path $stagingManifestDir "AndroidManifest.xml"
        $manifestXml.Save($stagedManifestPath)
        $effectiveManifest = $stagedManifestPath
    }

    # 2. Compilazione risorse aapt2
    Write-Host "[2/6] Compilazione risorse con aapt2..."
    & $aapt2 compile --dir $resDir -o $compiledResZip
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $compiledResZip)) {
        Write-Host "ERRORE durante aapt2 compile." -ForegroundColor Red
        exit 1
    }

    # 3. Linking manifest e risorse
    Write-Host "[3/6] Linking manifest e risorse con aapt2 (API 28, versionCode=$VersionCode)..."
    $linkArgs = @(
        "link",
        "-I", $platformJar,
        "--manifest", $effectiveManifest,
        "-o", $baseApk,
        "--java", $genDir,
        $compiledResZip,
        "--auto-add-overlay",
        "--min-sdk-version", "21",
        "--target-sdk-version", "28",
        "--version-code", "$VersionCode",
        "--version-name", "$VersionName"
    )
    if ($isParallel) {
        $linkArgs += @("--rename-manifest-package", $PackageId, "--custom-package", "it.akai.customhome")
    }
    & $aapt2 @linkArgs
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $baseApk)) {
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

    # 5. Generazione DEX con d8 + ZipAlign
    Write-Host "[5/6] Generazione classes.dex con d8 e zipalign..."
    $classFiles = Get-ChildItem -Path $classesDir -Filter "*.class" -Recurse | Select-Object -ExpandProperty FullName
    $d8Args = @("-cp", $d8Jar, "com.android.tools.r8.D8", "--min-api", "21", "--lib", $platformJar, "--output", $dexDir) + $classFiles
    & $java $d8Args
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $dexDir "classes.dex"))) {
        Write-Host "ERRORE durante d8." -ForegroundColor Red
        exit 1
    }

    Push-Location $dexDir
    & $jar uf $baseApk classes.dex
    Pop-Location

    & $zipalign -f -p 4 $baseApk $alignedApk
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $alignedApk)) {
        Write-Host "ERRORE durante zipalign." -ForegroundColor Red
        exit 1
    }

    # 6. Firma digitale protetta (ZERO password su CLI: solo env: o file:) e verifica
    Write-Host "[6/6] Firma digitale con apksigner (v1 + v2, canale=$signingChannel)..."
    $signArgs = @(
        "-jar", $apksignerJar,
        "sign",
        "--ks", $resolvedKeystore,
        "--ks-key-alias", $resolvedAlias,
        "--ks-pass", $ksPassSpec
    )
    if (-not [string]::IsNullOrWhiteSpace($keyPassSpec)) {
        $signArgs += @("--key-pass", $keyPassSpec)
    }
    $signArgs += @("--out", $versionedApk, $alignedApk)
    & $java $signArgs
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $versionedApk)) {
        Write-Host "ERRORE durante apksigner sign." -ForegroundColor Red
        exit 1
    }
} finally {
    foreach ($varName in $tempEnvVarsToClear) {
        [System.Environment]::SetEnvironmentVariable($varName, $null, "Process")
    }
}

# Verifica post-firma ed estrazione metadati reali dall'APK
$verifyOut = & $java -jar $apksignerJar verify --verbose --print-certs $versionedApk 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERRORE: verifica apksigner fallita sull'APK generato!" -ForegroundColor Red
    $verifyOut | Write-Host
    exit 1
}

$certSha256 = ""
$signerDn = ""
foreach ($line in $verifyOut) {
    if ($line -match 'Signer #1 certificate DN:\s*(.+)$') { $signerDn = $Matches[1].Trim() }
    if ($line -match 'Signer #1 certificate SHA-256 digest:\s*([0-9a-fA-F]+)$') { $certSha256 = $Matches[1].Trim().ToLowerInvariant() }
}

$xmlTreeOut = & $aapt dump xmltree $versionedApk AndroidManifest.xml 2>&1
$hasHomeInManifest = [bool]($xmlTreeOut | Select-String -Pattern 'android\.intent\.category\.HOME' -Quiet)
$manifestPkgOk = [bool]($xmlTreeOut | Select-String -Pattern ("package=`"" + [regex]::Escape($PackageId) + "`"") -Quiet)
$manifestCompOk = [bool]($xmlTreeOut | Select-String -Pattern 'it\.akai\.customhome\.MainActivity' -Quiet)
$hasProviderInManifest = [bool]($xmlTreeOut | Select-String -Pattern '^\s*E:\s*provider\b' -Quiet)

if (-not $manifestPkgOk -or -not $manifestCompOk -or $hasProviderInManifest) {
    Write-Host "ERRORE: verifica manifest APK fallita (pkg=$manifestPkgOk, comp=$manifestCompOk, provider=$hasProviderInManifest)." -ForegroundColor Red
    exit 1
}

$apkSha256 = (Get-FileHash -Path $versionedApk -Algorithm SHA256).Hash
$sizeKb = [Math]::Round((Get-Item $versionedApk).Length / 1024, 2)
$launchComponent = "$PackageId/it.akai.customhome.MainActivity"

# Compatibilita' con scripts/10_android_tv_emulator_smoke_test.ps1 solo per la build standard debug non-parallela con HOME inclusa
if ($SigningMode -eq "debug" -and -not $isParallel -and -not $ExcludeHomeIntent) {
    $finalApk = Join-Path $outputDir "akai-custom-home.apk"
    $v8Apk = Join-Path $outputDir "akai-custom-home-v8.apk"
    Copy-Item $versionedApk $finalApk -Force
    Copy-Item $versionedApk $v8Apk -Force
}

$buildInfo = @"
PackageId=$PackageId
VersionCode=$VersionCode
VersionName=$VersionName
LaunchComponent=$launchComponent
SigningMode=$SigningMode
SigningChannel=$signingChannel
KeystoreFile=$(Split-Path -Leaf $resolvedKeystore)
KeyAlias=$resolvedAlias
SignerDN=$signerDn
CertSHA256=$certSha256
HomeIntentIncluded=$hasHomeInManifest
ProvidersFound=$hasProviderInManifest
ApkFile=$(Split-Path -Leaf $versionedApk)
ApkSHA256=$apkSha256
SizeKB=$sizeKb
"@
[System.IO.File]::WriteAllText($buildInfoPath, $buildInfo, [System.Text.Encoding]::UTF8)

Write-Host "`n========================================================" -ForegroundColor Green
Write-Host " AKAI CUSTOM HOME v8 LEANBACK COMPILATO E VERIFICATO!" -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green
Write-Host " APK Tracciabile : $versionedApk"
Write-Host " Metadata Build  : $buildInfoPath"
Write-Host " Package / Vers  : $PackageId (vc=$VersionCode, name=$VersionName)"
Write-Host " Component Launch: $launchComponent"
Write-Host " CATEGORY_HOME   : $hasHomeInManifest"
Write-Host " Providers       : $hasProviderInManifest"
Write-Host " SigningMode     : $SigningMode [$signingChannel] ($signerDn)"
Write-Host " Cert SHA-256    : $certSha256" -ForegroundColor Yellow
Write-Host " APK SHA-256     : $apkSha256 ($sizeKb KB)" -ForegroundColor Yellow
