# ==============================================================================
# AKAI Custom TV - Script 15: JARVIS A2 RESCUE APK BUILDER (IN-PLACE NO-UNINSTALL)
# Costruisce da sorgente storico immutabile A2 (6a6dd5d...) un APK A2 rescue con
# versionCode > candidato installato (default v5 > v4) per rollback in-place
# SENZA downgrade (-d) e SENZA disinstallazione pacchetto (preserva AndroidKeyStore / AI keys).
# Zero comandi ADB; nessuna modifica al repository sorgente.
# ==============================================================================

param(
    [ValidateRange(5, 999999)]
    [int]$RescueVersionCode = 5,
    [ValidateRange(4, 999998)]
    [int]$TargetToRecoverVersionCode = 4,
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9._-]{0,60}$')]
    [string]$RescueVersionName = '1.2.0-a2-rescue-v5',
    [ValidatePattern('^[a-fA-F0-9]{40}$')]
    [string]$ExpectedA2SourceSha = '6a6dd5d975518f422ba4aa947cd6063660d87729',
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SigningKeystorePath,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9._-]{1,100}$')]
    [string]$SigningAlias,
    [switch]$EmulatorSandboxTestMode = $false,
    [string]$SandboxOutputDir = $null
)

$ErrorActionPreference = 'Stop'

if ($RescueVersionCode -le $TargetToRecoverVersionCode) {
    throw "FAIL-CLOSED: RescueVersionCode ($RescueVersionCode) deve essere strettamente maggiore di TargetToRecoverVersionCode ($TargetToRecoverVersionCode) per evitare downgrade su Android 9."
}
if ($RescueVersionName -notmatch '(?i)a2-rescue') {
    throw "FAIL-CLOSED: RescueVersionName ('$RescueVersionName') deve contenere il tag riconoscibile 'a2-rescue'."
}
if ($RescueVersionName -match '(?i)(diagnostic|debug)') {
    throw "FAIL-CLOSED: RescueVersionName ('$RescueVersionName') non puo' contenere tag diagnostic/debug; il rescue deve restare non-debuggable."
}
if (-not $env:JARVIS_SIGNING_STOREPASS -or -not $env:JARVIS_SIGNING_KEYPASS) {
    throw 'FAIL-CLOSED: Impostare JARVIS_SIGNING_STOREPASS e JARVIS_SIGNING_KEYPASS nel proprio ambiente privato.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$ExpectedA2SourceSha = $ExpectedA2SourceSha.ToLowerInvariant()
$approvedA2SourceAllowlist = @('6a6dd5d975518f422ba4aa947cd6063660d87729')
$expectedSigner = '21c2c41dc4c34576cca14ad5404e87d1c5a07ace961c0fab96d128c2164a51ed'
$expectedRootTreeSha = '80eac7b51f2542b01b7fee3e83abc8de5a38cb3a'
$expectedTvTreeSha = '481ced00c95accc2c43dc73c2baff7ff6865058a'
$expectedWebTreeSha = '88f148692da79edbc754de741b98640fd83e54be'
$expectedManifestBlob = 'fdbfb4cb9f3ed8688161c3bcda7821019055c488'
$expectedJniBlob = 'ffe04f6b6861cf1e253bbfbf113cbb8364c22f9b'
$expectedNativeJavaBlob = '6f7c5b28e9cd4f087592cdaed1a0a57c3121fccd'

function Resolve-PhysicalPathSafe([string]$CandidatePath) {
    $full = [IO.Path]::GetFullPath($CandidatePath)
    $parts = New-Object System.Collections.Generic.List[string]
    $probe = $full
    while ($probe -and -not (Test-Path -LiteralPath $probe)) {
        $leaf = Split-Path -Leaf $probe
        $parent = Split-Path -Parent $probe
        if (-not $leaf -or $parent -eq $probe) { break }
        [void]$parts.Add($leaf)
        $probe = $parent
    }
    $resolvedBase = $probe
    if ($probe -and (Test-Path -LiteralPath $probe)) {
        $resolvedTarget = $null
        if ([Environment]::OSVersion.Platform -match 'Win') {
            $typeCode = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class AkaiRescuePathHelper {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(IntPtr hFile, StringBuilder lpszFilePath, uint cchFilePath, uint dwFlags);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);
    public static string GetFinalPath(string path) {
        IntPtr h = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (h == new IntPtr(-1)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        try {
            var sb = new StringBuilder(1024);
            uint res = GetFinalPathNameByHandleW(h, sb, (uint)sb.Capacity, 0);
            if (res == 0) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            if (res >= sb.Capacity) {
                sb = new StringBuilder((int)res + 1);
                res = GetFinalPathNameByHandleW(h, sb, (uint)sb.Capacity, 0);
                if (res == 0 || res >= sb.Capacity) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
            string s = sb.ToString();
            if (s.StartsWith("\\\\?\\UNC\\")) return "\\\\" + s.Substring(8);
            if (s.StartsWith("\\\\?\\")) return s.Substring(4);
            return s;
        } finally { CloseHandle(h); }
    }
}
'@
            if (-not ('AkaiRescuePathHelper' -as [type])) {
                Add-Type -TypeDefinition $typeCode -Language CSharp
            }
            $resolvedTarget = [AkaiRescuePathHelper]::GetFinalPath($probe)
        } else {
            $rpCmd = Get-Command realpath -ErrorAction SilentlyContinue
            if ($rpCmd) {
                $rpOut = (& $rpCmd.Source $probe 2>&1 | Out-String).Trim()
                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($rpOut)) { $resolvedTarget = $rpOut }
            }
            if (-not $resolvedTarget) {
                $gi = Get-Item -LiteralPath $probe -Force
                $rt = $gi.ResolveLinkTarget($true)
                $resolvedTarget = if ($rt) { $rt.FullName } else { $probe }
            }
        }
        $resolvedBase = $resolvedTarget
    }
    for ($i = $parts.Count - 1; $i -ge 0; $i--) {
        $resolvedBase = Join-Path $resolvedBase $parts[$i]
    }
    return [IO.Path]::GetFullPath($resolvedBase)
}

function Test-PathInsideRepo([string]$CandidatePath, [string]$RepositoryRoot) {
    $normRepo = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/')
    $physRepo = (Resolve-PhysicalPathSafe $normRepo).TrimEnd('\', '/')
    foreach ($cand in @([IO.Path]::GetFullPath($CandidatePath), (Resolve-PhysicalPathSafe $CandidatePath))) {
        $normCand = $cand.TrimEnd('\', '/')
        foreach ($r in @($normRepo, $physRepo)) {
            if (($normCand -eq $r) -or $normCand.StartsWith($r + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }
    return $false
}

$SigningKeystorePath = [IO.Path]::GetFullPath($SigningKeystorePath)
if (-not (Test-Path -LiteralPath $SigningKeystorePath -PathType Leaf)) {
    throw "FAIL-CLOSED: Keystore di firma non trovato: $SigningKeystorePath"
}
if (Test-PathInsideRepo -CandidatePath $SigningKeystorePath -RepositoryRoot $repoRoot) {
    throw 'FAIL-CLOSED: Il keystore non puo risiedere dentro il repository Git (inclusi symlink/junction).'
}

# Verifica vincolante dell'esatto commit storico A2 approvato (allowlist immutabile + tree provenance)
if ($approvedA2SourceAllowlist -notcontains $ExpectedA2SourceSha) {
    throw "FAIL-CLOSED: ExpectedA2SourceSha ($ExpectedA2SourceSha) non presente nell'allowlist immutabile A2 approvata ($($approvedA2SourceAllowlist -join ', '))."
}
$commitType = (& git -C $repoRoot cat-file -t $ExpectedA2SourceSha 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $commitType -ne 'commit') {
    throw "FAIL-CLOSED: Commit storico A2 ($ExpectedA2SourceSha) non presente nello store Git locale."
}
$rootTreeSpec = '{0}^{{tree}}' -f $ExpectedA2SourceSha
$rootTreeSha = (& git -C $repoRoot rev-parse $rootTreeSpec 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $rootTreeSha -ne $expectedRootTreeSha) {
    throw "FAIL-CLOSED: Root tree Git A2 inatteso ($rootTreeSha vs atteso $expectedRootTreeSha)."
}
$tvTreeSha = (& git -C $repoRoot rev-parse ('{0}:akai-remote-tv' -f $ExpectedA2SourceSha) 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $tvTreeSha -ne $expectedTvTreeSha) {
    throw "FAIL-CLOSED: Tree akai-remote-tv A2 inatteso ($tvTreeSha vs atteso $expectedTvTreeSha)."
}
$webTreeSha = (& git -C $repoRoot rev-parse ('{0}:akai-remote-web' -f $ExpectedA2SourceSha) 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $webTreeSha -ne $expectedWebTreeSha) {
    throw "FAIL-CLOSED: Tree akai-remote-web A2 inatteso ($webTreeSha vs atteso $expectedWebTreeSha)."
}
$manifestBlob = (& git -C $repoRoot rev-parse ('{0}:akai-remote-tv/app/src/main/AndroidManifest.xml' -f $ExpectedA2SourceSha) 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $manifestBlob -ne $expectedManifestBlob) {
    throw "FAIL-CLOSED: Blob AndroidManifest.xml A2 inatteso ($manifestBlob vs atteso $expectedManifestBlob)."
}
$jniSpec = '{0}:{1}' -f $ExpectedA2SourceSha, 'akai-remote-tv/app/src/main/jni/uinput_jni.c'
$javaNativeSpec = '{0}:{1}' -f $ExpectedA2SourceSha, 'akai-remote-tv/app/src/main/java/it/akai/customremote/UInputDriver.java'
$jniBlob = (& git -C $repoRoot rev-parse $jniSpec 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $jniBlob -ne $expectedJniBlob) {
    throw "FAIL-CLOSED: Blob JNI A2 inatteso ($jniBlob)."
}
$javaNativeBlob = (& git -C $repoRoot rev-parse $javaNativeSpec 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $javaNativeBlob -ne $expectedNativeJavaBlob) {
    throw "FAIL-CLOSED: Blob Java UInputDriver A2 inatteso ($javaNativeBlob)."
}

# Individuazione Android SDK, Build Tools >= 34.0.0, Platform API 28, JDK 17 e NDK
$toolsDir = Join-Path $repoRoot 'tools'
$jdkDir = Join-Path $toolsDir 'jdk-17'
$sdkDir = Join-Path $toolsDir 'android-sdk'
$buildToolsRoot = Join-Path $sdkDir 'build-tools'
$minimumBuildToolsVersion = [version]'34.0.0'
if (-not (Test-Path -LiteralPath $buildToolsRoot -PathType Container)) {
    throw 'FAIL-CLOSED: Cartella Android build-tools mancante (richiesta build-tools;34.0.0 o superiore).'
}
$compatibleBuildTools = @(Get-ChildItem -LiteralPath $buildToolsRoot -Directory |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' -and [version]$_.Name -ge $minimumBuildToolsVersion } |
    Sort-Object { [version]$_.Name } -Descending)
$buildToolsDir = $null
foreach ($candidate in $compatibleBuildTools) {
    $required = @('aapt2.exe', 'aapt.exe', 'zipalign.exe', 'lib\d8.jar', 'lib\apksigner.jar')
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $candidate.FullName $_) -PathType Leaf) })
    if ($missing.Count -eq 0) {
        $buildToolsDir = $candidate.FullName
        break
    }
}
if (-not $buildToolsDir) {
    throw 'FAIL-CLOSED: Nessuna versione Android build-tools >= 34.0.0 completa trovata.'
}

$platformJar = Join-Path $sdkDir 'platforms\android-28\android.jar'
$ndkDir = Join-Path $sdkDir 'ndk\21.4.7075529'
if (-not (Test-Path -LiteralPath $platformJar -PathType Leaf)) {
    throw "FAIL-CLOSED: Platform Android 9 API28 mancante ($platformJar)."
}

$targetAbi = if ($EmulatorSandboxTestMode) { 'x86' } else { 'armeabi-v7a' }
$clangName = if ($EmulatorSandboxTestMode) { 'i686-linux-android21-clang.cmd' } else { 'armv7a-linux-androideabi21-clang.cmd' }
$clang = Join-Path $ndkDir "toolchains\llvm\prebuilt\windows-x86_64\bin\$clangName"
if (-not (Test-Path -LiteralPath $clang -PathType Leaf)) {
    throw "FAIL-CLOSED: Compilatore NDK richiesto per ABI $targetAbi mancante ($clang)."
}

$aapt2 = Join-Path $buildToolsDir 'aapt2.exe'
$aaptCli = Join-Path $buildToolsDir 'aapt.exe'
$d8Jar = Join-Path $buildToolsDir 'lib\d8.jar'
$apksignerJar = Join-Path $buildToolsDir 'lib\apksigner.jar'
$zipalign = Join-Path $buildToolsDir 'zipalign.exe'
$javac = Join-Path $jdkDir 'bin\javac.exe'
$java = Join-Path $jdkDir 'bin\java.exe'
$jar = Join-Path $jdkDir 'bin\jar.exe'
foreach ($tool in @($aapt2, $aaptCli, $d8Jar, $apksignerJar, $zipalign, $javac, $java, $jar)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
        throw "FAIL-CLOSED: Tool di build mancante: $tool"
    }
}

# Directory di output rigorosamente out-of-tree
$buildId = 'A2-RESCUE-v{0}-{1}' -f $RescueVersionCode, (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
if ($EmulatorSandboxTestMode) {
    if ([string]::IsNullOrWhiteSpace($SandboxOutputDir)) {
        $SandboxOutputDir = Join-Path ([IO.Path]::GetTempPath()) $buildId
    }
    $outRoot = [IO.Path]::GetFullPath($SandboxOutputDir)
    if (Test-PathInsideRepo -CandidatePath $outRoot -RepositoryRoot $repoRoot) {
        throw 'FAIL-CLOSED: SandboxOutputDir non puo risiedere dentro il repository.'
    }
    $releaseOutputDir = $outRoot
    $apkFileName = "jarvis-a2-rescue-v${RescueVersionCode}-sandbox-${targetAbi}.apk"
} else {
    if (-not $env:LOCALAPPDATA) {
        throw 'FAIL-CLOSED: LOCALAPPDATA non disponibile.'
    }
    $outRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'AkaiJarvisBuilds') $buildId
    $releaseOutputDir = Join-Path $outRoot 'outputs\apk\release'
    $apkFileName = "jarvis-a2-rescue-v${RescueVersionCode}-owner-signed.apk"
}

$workTemp = Join-Path ([IO.Path]::GetTempPath()) "akai_a2_rescue_work_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $workTemp, $releaseOutputDir | Out-Null

$releaseApk = Join-Path $releaseOutputDir $apkFileName
if (Test-Path -LiteralPath $releaseApk) {
    throw "FAIL-CLOSED: Artefatto target gia esistente ($releaseApk). Non sovrascrivo."
}

$handoffPath = Join-Path $releaseOutputDir 'JARVIS_A2_RESCUE_MANIFEST.json'
$releaseApproved = $false
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

try {
    Write-Host "=== BUILD A2 RESCUE IN-PLACE (versionCode=$RescueVersionCode, ABI=$targetAbi, source=$($ExpectedA2SourceSha.Substring(0,8))) ===" -ForegroundColor Cyan

    # 1. Estrazione snapshot storico A2 immutabile in directory isolata
    $srcZip = Join-Path $workTemp 'a2_source.zip'
    $srcDir = Join-Path $workTemp 'src'
    New-Item -ItemType Directory -Force -Path $srcDir | Out-Null
    & git -C $repoRoot archive --format=zip --output=$srcZip $ExpectedA2SourceSha
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $srcZip)) {
        throw 'FAIL-CLOSED: git archive dello snapshot A2 fallito.'
    }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($srcZip, $srcDir)

    $manifestPath = Join-Path $srcDir 'akai-remote-tv\app\src\main\AndroidManifest.xml'
    $resDir = Join-Path $srcDir 'akai-remote-tv\app\src\main\res'
    $javaDir = Join-Path $srcDir 'akai-remote-tv\app\src\main\java'
    $jniSrc = Join-Path $srcDir 'akai-remote-tv\app\src\main\jni\uinput_jni.c'
    $webSrcDir = Join-Path $srcDir 'akai-remote-web'

    $genDir = Join-Path $workTemp 'gen'
    $classesDir = Join-Path $workTemp 'classes'
    $dexDir = Join-Path $workTemp 'dex'
    $libDir = Join-Path $workTemp "lib\$targetAbi"
    $stagingRoot = Join-Path $workTemp 'asset_stage'
    $stagingWeb = Join-Path $stagingRoot 'assets\www'
    New-Item -ItemType Directory -Force -Path $genDir, $classesDir, $dexDir, $libDir, $stagingWeb | Out-Null

    # 2. Compilazione driver JNI da sorgente C storico A2 (armeabi-v7a o x86 in sandbox)
    $soTarget = Join-Path $libDir 'libakai_uinput.so'
    & cmd.exe /c "`"$clang`" -shared -fPIC -O2 `"$jniSrc`" -llog -o `"$soTarget`""
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $soTarget) -or (Get-Item -LiteralPath $soTarget).Length -lt 1024) {
        throw "FAIL-CLOSED: Compilazione driver JNI ($targetAbi) fallita."
    }

    # 3. Compilazione risorse & link AAPT2 con --replace-version (NO --debug-mode)
    $compiledRes = Join-Path $workTemp 'compiled_res.zip'
    $baseApk = Join-Path $workTemp 'base.apk'
    & $aapt2 compile --dir $resDir -o $compiledRes
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $compiledRes)) {
        throw 'FAIL-CLOSED: aapt2 compile fallito.'
    }
    & $aapt2 link -I $platformJar --manifest $manifestPath -o $baseApk --java $genDir $compiledRes `
        --auto-add-overlay --min-sdk-version 21 --target-sdk-version 28 `
        --version-code $RescueVersionCode --version-name $RescueVersionName --replace-version
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $baseApk)) {
        throw 'FAIL-CLOSED: aapt2 link --replace-version fallito.'
    }

    # 4. Compilazione Java (JDK 8 bytecode) e D8
    $javaFiles = @(Get-ChildItem -Path $javaDir, $genDir -Filter '*.java' -Recurse | Select-Object -ExpandProperty FullName)
    $argfile = Join-Path $workTemp 'javac-args.txt'
    $argsList = [System.Collections.Generic.List[string]]::new()
    foreach ($f in @('-encoding', 'UTF-8', '-source', '1.8', '-target', '1.8', '-bootclasspath')) { [void]$argsList.Add($f) }
    [void]$argsList.Add('"' + $platformJar.Replace('\', '/') + '"')
    [void]$argsList.Add('-classpath')
    [void]$argsList.Add('"' + $platformJar.Replace('\', '/') + '"')
    [void]$argsList.Add('-d')
    [void]$argsList.Add('"' + $classesDir.Replace('\', '/') + '"')
    foreach ($jf in $javaFiles) { [void]$argsList.Add('"' + $jf.Replace('\', '/') + '"') }
    [IO.File]::WriteAllLines($argfile, $argsList, [Text.UTF8Encoding]::new($false))
    & $javac "@$argfile"
    if ($LASTEXITCODE -ne 0) { throw 'FAIL-CLOSED: javac fallito sui sorgenti A2.' }

    $classFiles = @(Get-ChildItem -Path $classesDir -Filter '*.class' -Recurse | Select-Object -ExpandProperty FullName)
    & $java -cp $d8Jar com.android.tools.r8.D8 --min-api 21 --lib $platformJar --output $dexDir $classFiles
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $dexDir 'classes.dex'))) {
        throw 'FAIL-CLOSED: d8 fallito.'
    }

    # 5. Assemblaggio APK (classes.dex, lib/<abi>/libakai_uinput.so, assets/www/*)
    Push-Location $dexDir
    try {
        & $jar uf $baseApk classes.dex
        if ($LASTEXITCODE -ne 0) { throw 'FAIL-CLOSED: packaging classes.dex fallito.' }
    } finally { Pop-Location }

    Push-Location $workTemp
    try {
        & $jar uf $baseApk "lib/$targetAbi/libakai_uinput.so"
        if ($LASTEXITCODE -ne 0) { throw 'FAIL-CLOSED: packaging libakai_uinput.so fallito.' }
    } finally { Pop-Location }

    Get-ChildItem -Path $webSrcDir -File | ForEach-Object {
        if ($_.Name -match '(?i)\.(p12|jks|keystore|key|der|crt|pass)$' -or $_.Name -match '(?i)server_keystore|ca_key|AkaiRootCA') {
            throw "FAIL-CLOSED: asset web proibito nel sorgente A2: $($_.Name)"
        }
        if ($_.Extension.ToLowerInvariant() -in @('.html', '.css', '.js', '.json', '.svg')) {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $stagingWeb $_.Name) -Force
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $stagingWeb 'index.html'))) {
        throw 'FAIL-CLOSED: assets/www/index.html mancante.'
    }
    Push-Location $stagingRoot
    try {
        & $jar uf $baseApk assets/
        if ($LASTEXITCODE -ne 0) { throw 'FAIL-CLOSED: packaging assets/www fallito.' }
    } finally { Pop-Location }

    # 6. Zipalign + apksigner sign
    $alignedApk = Join-Path $workTemp 'aligned.apk'
    & $zipalign -f -p 4 $baseApk $alignedApk
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $alignedApk)) { throw 'FAIL-CLOSED: zipalign fallito.' }

    & $java -jar $apksignerJar sign --ks $SigningKeystorePath --ks-key-alias $SigningAlias `
        --ks-pass 'env:JARVIS_SIGNING_STOREPASS' --key-pass 'env:JARVIS_SIGNING_KEYPASS' `
        --out $releaseApk $alignedApk
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $releaseApk)) {
        if (Test-Path -LiteralPath $releaseApk) { Remove-Item -LiteralPath $releaseApk -Force -ErrorAction SilentlyContinue }
        throw 'FAIL-CLOSED: firma APK A2 rescue fallita.'
    }

    # 7. Gate di verifica Fail-Closed sul pacchetto firmato finale
    $xmlTree = (& $aaptCli dump xmltree $releaseApk AndroidManifest.xml 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($xmlTree)) {
        throw 'FAIL-CLOSED: aapt dump xmltree fallito sul binario finale.'
    }
    $compiledDebugFalse = $xmlTree -match 'android:debuggable\(0x0101000f\)=\(type 0x12\)0x0(?:\s|$)'
    $compiledDebugAbsent = $xmlTree -notmatch 'android:debuggable'
    if (-not ($compiledDebugFalse -or $compiledDebugAbsent)) {
        throw 'FAIL-CLOSED: L APK A2 rescue deve risultare NON debuggabile.'
    }

    $alignCheck = (& $zipalign -c -p 4 $releaseApk 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "FAIL-CLOSED: verifica zipalign su APK firmato fallita: $alignCheck" }

    $verifyOut = (& $java -jar $apksignerJar verify --print-certs $releaseApk 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "FAIL-CLOSED: apksigner verify fallito: $verifyOut" }
    $certMatch = [regex]::Match($verifyOut, 'Signer #1 certificate SHA-256 digest:\s*([0-9a-fA-F]{64})')
    if (-not $certMatch.Success) { throw 'FAIL-CLOSED: fingerprint certificato APK rescue illeggibile.' }
    $actualSigner = $certMatch.Groups[1].Value.ToLowerInvariant()
    if ($EmulatorSandboxTestMode) {
        if ($actualSigner -eq $expectedSigner) {
            throw 'FAIL-CLOSED: In EmulatorSandboxTestMode e vietato firmare build x86 di test con il certificato owner reale.'
        }
    } else {
        if ($actualSigner -ne $expectedSigner) {
            throw "FAIL-CLOSED: FIRMA DIVERSA DA TV ($actualSigner vs atteso $expectedSigner)."
        }
    }

    $badgingText = (& $aaptCli dump badging $releaseApk 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $badgingText -match '(?i)ERROR getting') {
        throw "FAIL-CLOSED: badging/icone A2 rescue non risolti: $badgingText"
    }
    $expectedPkgRegex = "package:\s+name='it\.akai\.customremote'\s+versionCode='$RescueVersionCode'\s+versionName='$([regex]::Escape($RescueVersionName))'"
    if ($badgingText -notmatch $expectedPkgRegex -or $badgingText -notmatch "sdkVersion:'21'" -or $badgingText -notmatch "targetSdkVersion:'28'" -or $badgingText -notmatch "(?m)^application:\s+label=") {
        throw "FAIL-CLOSED: badging A2 rescue non conforme: $badgingText"
    }

    # Verifica contenuti ZIP (zero entry duplicate, zero estensioni/asset TLS vietati)
    $zipTest = [System.IO.Compression.ZipFile]::OpenRead($releaseApk)
    $entryNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    try {
        foreach ($entry in $zipTest.Entries) {
            if (-not $entryNames.Add($entry.FullName)) {
                throw "FAIL-CLOSED: entry ZIP duplicata $($entry.FullName)"
            }
            if ($entry.FullName -match '\.(p12|jks|key|der|crt|pass)\z' -or $entry.FullName -match 'server_keystore') {
                throw "FAIL-CLOSED: asset crittografico vietato nell APK A2 rescue: $($entry.FullName)"
            }
        }
        foreach ($req in @('classes.dex', "lib/$targetAbi/libakai_uinput.so", 'assets/www/index.html')) {
            $e = $zipTest.GetEntry($req)
            if ($null -eq $e -or $e.Length -le 0) { throw "FAIL-CLOSED: entry obbligatoria mancante ($req)." }
        }
    } finally {
        $zipTest.Dispose()
    }

    $apkSha256 = (Get-FileHash -LiteralPath $releaseApk -Algorithm SHA256).Hash.ToLowerInvariant()
    $buildToolsVersion = Split-Path -Leaf $buildToolsDir
    $manifestObj = [ordered]@{
        packageName = 'it.akai.customremote'
        versionCode = $RescueVersionCode
        targetToRecoverVersionCode = $TargetToRecoverVersionCode
        versionName = $RescueVersionName
        a2SourceCommit = $ExpectedA2SourceSha
        a2RootTreeSha = $rootTreeSha
        a2TvTreeSha = $tvTreeSha
        a2WebTreeSha = $webTreeSha
        a2ManifestBlobSha = $manifestBlob
        a2JniBlobSha = $jniBlob
        a2UInputJavaBlobSha = $javaNativeBlob
        buildToolsVersion = $buildToolsVersion
        buildUtc = ([DateTime]::UtcNow.ToString('o'))
        apkFilename = $apkFileName
        apkSha256 = $apkSha256
        signerSha256 = $actualSigner
        abi = $targetAbi
        minSdk = 21
        targetSdk = 28
        debuggable = $false
        noUninstallRequired = $true
        preservesAndroidKeyStore = $true
        nextRecommendedReleaseVersionCode = ($RescueVersionCode + 1)
        emulatorSandboxOnly = [bool]$EmulatorSandboxTestMode
        ownerTvInstallForbidden = [bool]$EmulatorSandboxTestMode
        installed = $false
    }
    [IO.File]::WriteAllText($handoffPath, ($manifestObj | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    $releaseApproved = $true

    Write-Host "A2 RESCUE APK READY (NON INSTALLATO): $releaseApk" -ForegroundColor Green
    Write-Host "SHA256=$apkSha256 SIGNER=$actualSigner VERSION=$RescueVersionCode ($RescueVersionName) NEXT_RELEASE_MIN=$($RescueVersionCode + 1)" -ForegroundColor Green
} finally {
    if (-not $releaseApproved) {
        if (Test-Path -LiteralPath $releaseApk) { Remove-Item -LiteralPath $releaseApk -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $handoffPath) { Remove-Item -LiteralPath $handoffPath -Force -ErrorAction SilentlyContinue }
    }
    if (Test-Path -LiteralPath $workTemp) { Remove-Item -LiteralPath $workTemp -Recurse -Force -ErrorAction SilentlyContinue }
}
