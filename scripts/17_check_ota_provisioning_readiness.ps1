# ==============================================================================
# AKAI Custom TV - Script 17: CHECK READ-ONLY OTA RELEASE PROVISIONING READINESS
# Verifica rigorosamente in sola lettura se la trust root OTA offline, il
# build/handoff manifest e l'APK candidato risultano provisionati con chiave
# pubblica pinned + manifest URL HTTPS + prova binaria autoritativa (apksigner +
# aapt dump badging + aapt dump xmltree).
# - Non si fida mai del solo JSON auto-dichiarato per certificare otaReady=true.
# - Fixture sintetiche host/CI (non firmate col certificato originale owner)
#   vengono classificate come OTA_SYNTHETIC_FIXTURE_NOT_OWNER_SIGNED_APK
#   con otaReady=false ed exit 1.
# - La modalita' esplicita -InventoryOnly riporta lo stato dell'inventario
#   leggero (OTA_TRUST_INVENTORY_ONLY / OTA_TRUST_INVENTORY_INCOMPLETE) con
#   otaReady=false, non utilizzabile come gate di deploy.
# Non genera ne' scrive mai chiavi reali; zero comandi ADB.
# ==============================================================================

param(
    [string]$ApkPath = $null,
    [string]$BuildManifestPath = $null,
    [string]$OtaReleasePublicKeyPath = $null,
    [string]$OtaReleaseManifestUrl = $null,
    [ValidateSet('Release', 'Staging')]
    [string]$ChannelProfile = 'Release',
    [ValidateRange(0, 2147483646)]
    [int]$RescueVersionCode = 0,
    [switch]$InventoryOnly = $false,
    # Solo per test unitari/E2E: consente di iniettare report apksigner/aapt
    # simulati o di forzare il test dei parser autoritativi senza keystore owner.
    [string]$MockApksignerReportPath = $null,
    [string]$MockAaptBadgingPath = $null,
    [string]$MockAaptXmltreePath = $null
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

$expectedPackage = "it.akai.customremote"
$expectedOwnerSigner = "21c2c41dc4c34576cca14ad5404e87d1c5a07ace961c0fab96d128c2164a51ed"
$repoRoot = Split-Path -Parent $PSScriptRoot

function Get-Sha256Lower {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (-join ($sha.ComputeHash($Bytes) | ForEach-Object { "{0:x2}" -f $_ })).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Test-StrictOtaManifestUrl {
    param([string]$CandidateUrl)
    $uri = $null
    if ([string]::IsNullOrWhiteSpace($CandidateUrl)) { return $null }
    $trimmed = $CandidateUrl.Trim()
    if ($trimmed.Length -lt 20 -or $trimmed.Length -gt 480 -or $trimmed -match '[^\x21-\x7e]') { return $null }
    $trimmedLower = $trimmed.ToLowerInvariant()
    if ($trimmed.Contains("\") -or $trimmed.Contains("/../") -or $trimmed.EndsWith("/..") -or
        $trimmedLower.Contains("%2e") -or $trimmedLower.Contains("%2f") -or $trimmedLower.Contains("%5c")) { return $null }
    if (-not [Uri]::TryCreate($trimmed, [UriKind]::Absolute, [ref]$uri)) { return $null }
    if ($uri.Scheme -ne "https" -or -not $uri.IsDefaultPort) { return $null }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo) -or -not [string]::IsNullOrEmpty($uri.Query) -or -not [string]::IsNullOrEmpty($uri.Fragment)) { return $null }
    $rawPath = $uri.AbsolutePath
    if ($rawPath.Contains("//") -or (-not $rawPath.EndsWith(".manifest", [StringComparison]::Ordinal))) { return $null }
    if ([string]::IsNullOrWhiteSpace($uri.DnsSafeHost)) { return $null }
    $h = $uri.DnsSafeHost.ToLowerInvariant()
    $ipObj = $null
    if ($h -eq "localhost" -or $h.EndsWith(".localhost") -or $h.EndsWith(".local") -or $h.EndsWith(".lan") -or $h.EndsWith(".internal") -or $h.EndsWith(".home")) {
        return $null
    }
    if ([System.Net.IPAddress]::TryParse($h.Trim('[', ']'), [ref]$ipObj)) { return $null }
    if ($h.StartsWith(".") -or $h.EndsWith(".") -or $h.Contains("..") -or -not $h.Contains(".")) { return $null }
    return $uri
}

function Find-JavaExecutable {
    $candidates = @()
    if ($env:JAVA_HOME) {
        $candidates += (Join-Path $env:JAVA_HOME "bin\java.exe")
        $candidates += (Join-Path $env:JAVA_HOME "bin/java")
    }
    $candidates += (Join-Path $repoRoot "tools\jdk-17\bin\java.exe")
    $candidates += (Join-Path $repoRoot "tools/jdk-17/bin/java")
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c }
    }
    $cmd = Get-Command java -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Find-AndroidBuildTool {
    param([string[]]$RelativeNames)
    $sdkRoots = @()
    if ($env:ANDROID_SDK_ROOT) { $sdkRoots += $env:ANDROID_SDK_ROOT }
    if ($env:ANDROID_HOME) { $sdkRoots += $env:ANDROID_HOME }
    $sdkRoots += (Join-Path $repoRoot "tools\android-sdk")
    foreach ($root in $sdkRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $btDir = Join-Path $root "build-tools"
        if (-not (Test-Path -LiteralPath $btDir -PathType Container)) { continue }
        $versions = @(Get-ChildItem -LiteralPath $btDir -Directory -ErrorAction SilentlyContinue |
            Sort-Object {
                $v = $null
                if ([version]::TryParse($_.Name, [ref]$v)) { $v } else { [version]"0.0.0" }
            } -Descending)
        foreach ($ver in $versions) {
            foreach ($rel in $RelativeNames) {
                $cand = Join-Path $ver.FullName $rel
                if (Test-Path -LiteralPath $cand -PathType Leaf) { return $cand }
            }
        }
    }
    return $null
}

$reasons = [System.Collections.Generic.List[string]]::new()

$trustSubdir = if ($ChannelProfile -eq 'Staging') { "AkaiJarvisOtaStagingTrust" } else { "AkaiJarvisOtaReleaseTrust" }
$trustKeyFile = if ($ChannelProfile -eq 'Staging') { "ota-staging-public.der" } else { "ota-release-public.der" }
$defaultTrustDir = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA $trustSubdir } else { $null }
$resolvedKeyPath = if (-not [string]::IsNullOrWhiteSpace($OtaReleasePublicKeyPath)) {
    [IO.Path]::GetFullPath($OtaReleasePublicKeyPath)
} elseif ($defaultTrustDir) {
    Join-Path $defaultTrustDir $trustKeyFile
} else {
    $null
}

$trustDirExists = $false
if ($resolvedKeyPath) {
    $trustDirExists = Test-Path -LiteralPath (Split-Path -Parent $resolvedKeyPath) -PathType Container
}

$trustKeyPresent = $false
$trustKeySha256 = $null
if ($resolvedKeyPath -and (Test-Path -LiteralPath $resolvedKeyPath -PathType Leaf)) {
    $derBytes = [IO.File]::ReadAllBytes($resolvedKeyPath)
    if ($derBytes.Length -ge 200 -and $derBytes.Length -le 1024 -and $derBytes[0] -eq 0x30) {
        $trustKeyPresent = $true
        $trustKeySha256 = Get-Sha256Lower -Bytes $derBytes
    } else {
        [void]$reasons.Add("INVALID_TRUST_PUBLIC_KEY_DER")
    }
} else {
    [void]$reasons.Add("MISSING_OTA_TRUST_PUBLIC_KEY")
}

$effectiveUrl = $OtaReleaseManifestUrl
$manifestChecked = $false
$manifestVersionCode = $null
$manifestVersionName = $null
$manifestBuildProfile = $null
$manifestDebuggable = $null
$manifestSignerSha256 = $null
$manifestApkSha256 = $null
$manifestOtaProvisioned = $null
$nextRecommendedReleaseVersionCode = 6

$manFloor = 0
if ([string]::IsNullOrWhiteSpace($BuildManifestPath)) {
    if (-not $InventoryOnly) {
        [void]$reasons.Add("MISSING_BUILD_MANIFEST_PATH")
    }
} elseif (-not (Test-Path -LiteralPath $BuildManifestPath -PathType Leaf)) {
    [void]$reasons.Add("MISSING_BUILD_MANIFEST")
} else {
    $manifestChecked = $true
    $man = $null
    try {
        $man = Get-Content -LiteralPath $BuildManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        [void]$reasons.Add("INVALID_BUILD_MANIFEST_JSON")
    }

    if ($null -ne $man) {
        $manProps = @($man.PSObject.Properties | Select-Object -ExpandProperty Name)

        # 1. versionCode (obbligatorio e intero)
        $vcParsed = 0
        if (($manProps -notcontains "versionCode") -or ($null -eq $man.versionCode) -or
            (-not [int]::TryParse([string]$man.versionCode, [ref]$vcParsed)) -or
            ([string]$man.versionCode -notmatch '^\d+$')) {
            [void]$reasons.Add("BUILD_MANIFEST_MISSING_VERSION_CODE")
        } else {
            $manifestVersionCode = $vcParsed
            $manFloor = $manifestVersionCode + 1
            if ($ChannelProfile -eq 'Staging') {
                if ($manifestVersionCode -lt 5 -or $manifestVersionCode -gt 99) {
                    [void]$reasons.Add("STAGING_VERSION_CODE_OUT_OF_RANGE")
                }
            } elseif ($ChannelProfile -eq 'Release' -and $manifestVersionCode -lt 5) {
                [void]$reasons.Add("RELEASE_VERSION_CODE_TOO_LOW")
            }
        }

        if (($manProps -contains "versionName") -and (-not [string]::IsNullOrWhiteSpace([string]$man.versionName))) {
            $manifestVersionName = ([string]$man.versionName).Trim()
        }

        if (($manProps -contains "packageName") -and (-not [string]::IsNullOrWhiteSpace([string]$man.packageName))) {
            if (([string]$man.packageName).Trim() -ne $expectedPackage) {
                [void]$reasons.Add("BUILD_MANIFEST_PACKAGE_MISMATCH")
            }
        }

        # 2. buildProfile (obbligatorio)
        if (($manProps -notcontains "buildProfile") -or [string]::IsNullOrWhiteSpace([string]$man.buildProfile)) {
            [void]$reasons.Add("BUILD_MANIFEST_MISSING_BUILD_PROFILE")
        } else {
            $manifestBuildProfile = ([string]$man.buildProfile).Trim()
            if ($ChannelProfile -eq 'Staging') {
                if ($manifestBuildProfile -ne 'Diagnostic') {
                    [void]$reasons.Add("STAGING_BUILD_MANIFEST_PROFILE_MISMATCH")
                }
            } elseif ($ChannelProfile -eq 'Release' -and $manifestBuildProfile -ne 'Release') {
                [void]$reasons.Add("RELEASE_BUILD_MANIFEST_PROFILE_MISMATCH")
            }
        }

        # 3. debuggable (obbligatorio e booleano esplicito)
        if (($manProps -notcontains "debuggable") -or ($null -eq $man.debuggable) -or ($man.debuggable -isnot [bool])) {
            [void]$reasons.Add("BUILD_MANIFEST_MISSING_DEBUGGABLE")
        } else {
            $manifestDebuggable = [bool]$man.debuggable
            if ($ChannelProfile -eq 'Staging' -and (-not $manifestDebuggable)) {
                [void]$reasons.Add("STAGING_BUILD_MANIFEST_NOT_DEBUGGABLE")
            } elseif ($ChannelProfile -eq 'Release' -and $manifestDebuggable) {
                [void]$reasons.Add("RELEASE_BUILD_MANIFEST_DEBUGGABLE_FORBIDDEN")
            }
        }

        # 4. signerSha256 (obbligatorio e uguale al certificato owner pinnato)
        if (($manProps -notcontains "signerSha256") -or [string]::IsNullOrWhiteSpace([string]$man.signerSha256)) {
            [void]$reasons.Add("BUILD_MANIFEST_MISSING_SIGNER_SHA256")
        } else {
            $manifestSignerSha256 = ([string]$man.signerSha256).Trim().ToLowerInvariant()
            if ($manifestSignerSha256 -ne $expectedOwnerSigner) {
                [void]$reasons.Add("BUILD_MANIFEST_SIGNER_MISMATCH")
            }
        }

        # 5. otaProvisioned / otaPublicTrustProvisioned (obbligatorio e booleano)
        $hasOtaProvField = ($manProps -contains "otaProvisioned") -or ($manProps -contains "otaPublicTrustProvisioned")
        $rawOtaProv = if ($manProps -contains "otaProvisioned") { $man.otaProvisioned } elseif ($manProps -contains "otaPublicTrustProvisioned") { $man.otaPublicTrustProvisioned } else { $null }
        if ((-not $hasOtaProvField) -or ($null -eq $rawOtaProv) -or ($rawOtaProv -isnot [bool])) {
            [void]$reasons.Add("BUILD_MANIFEST_MISSING_OTA_PROVISIONED")
        } else {
            $manifestOtaProvisioned = [bool]$rawOtaProv
            if (-not $manifestOtaProvisioned) {
                [void]$reasons.Add("BUILD_MANIFEST_OTA_NOT_PROVISIONED")
            }
        }

        # 6. RescueVersionCode floor per Staging e Release
        if ($RescueVersionCode -gt 0 -and $null -ne $manifestVersionCode) {
            if ($ChannelProfile -eq 'Staging' -and $RescueVersionCode -le $manifestVersionCode) {
                [void]$reasons.Add("STAGING_RESCUE_VERSION_NOT_ABOVE_CANDIDATE")
            } elseif ($ChannelProfile -eq 'Release' -and $manifestVersionCode -le $RescueVersionCode) {
                [void]$reasons.Add("RELEASE_VERSION_NOT_ABOVE_RESCUE")
            }
        }

        if (($manProps -contains "apkSha256") -and (-not [string]::IsNullOrWhiteSpace([string]$man.apkSha256))) {
            $manifestApkSha256 = ([string]$man.apkSha256).Trim().ToLowerInvariant()
        }

        if ([string]::IsNullOrWhiteSpace($effectiveUrl) -and ($manProps -contains "otaReleaseManifestUrl") -and $man.otaReleaseManifestUrl) {
            $effectiveUrl = [string]$man.otaReleaseManifestUrl
        }
        if ($trustKeySha256 -and ($manProps -contains "otaReleasePublicKeySha256") -and $man.otaReleasePublicKeySha256 -and
            ([string]$man.otaReleasePublicKeySha256).Trim().ToLowerInvariant() -ne $trustKeySha256) {
            [void]$reasons.Add("BUILD_MANIFEST_PUBLIC_KEY_MISMATCH")
        }
    }
}

$rescueFloor = if ($RescueVersionCode -gt 0) { $RescueVersionCode + 1 } else { 0 }
$nextRecommendedReleaseVersionCode = [Math]::Max(6, [Math]::Max($manFloor, $rescueFloor))

$channelConfigured = $false
if (-not [string]::IsNullOrWhiteSpace($effectiveUrl)) {
    $uri = Test-StrictOtaManifestUrl -CandidateUrl $effectiveUrl
    if ($null -ne $uri) {
        $channelConfigured = $true
        $effectiveUrl = $uri.AbsoluteUri
        if ($manifestChecked -and $null -ne $man -and ($man.PSObject.Properties.Name -contains "otaChannelHost") -and
            (-not [string]::IsNullOrWhiteSpace([string]$man.otaChannelHost))) {
            if (([string]$man.otaChannelHost).Trim().ToLowerInvariant() -ne $uri.DnsSafeHost.ToLowerInvariant()) {
                [void]$reasons.Add("BUILD_MANIFEST_CHANNEL_HOST_MISMATCH")
            }
        }
    } else {
        [void]$reasons.Add("INVALID_OTA_MANIFEST_URL_REQUIRES_PUBLIC_HTTPS")
    }
} else {
    [void]$reasons.Add("MISSING_OTA_MANIFEST_URL")
}

$apkChecked = $false
$apkBundledKeyPresent = $false
$apkBundledKeySha256 = $null
$apkBundledChannelPresent = $false
$apkBundledChannelUrl = $null
$apkBinaryProven = $false
$realToolsVerified = $false
$useMocks = (-not [string]::IsNullOrWhiteSpace($MockApksignerReportPath)) -or
            (-not [string]::IsNullOrWhiteSpace($MockAaptBadgingPath)) -or
            (-not [string]::IsNullOrWhiteSpace($MockAaptXmltreePath))
$apkArtifactClass = "UNCHECKED"
$apkActualPackageName = $null
$apkActualVersionCode = $null
$apkActualVersionName = $null
$apkActualDebuggable = $null
$apkActualSignerSha256 = $null

if ($useMocks -and [string]::IsNullOrWhiteSpace($ApkPath)) {
    [void]$reasons.Add("APK_MOCK_EVIDENCE_NOT_AUTHORITATIVE")
}

if ([string]::IsNullOrWhiteSpace($ApkPath)) {
    if (-not $InventoryOnly) {
        [void]$reasons.Add("MISSING_APK_PATH")
    }
} else {
    $apkChecked = $true
    if (-not (Test-Path -LiteralPath $ApkPath -PathType Leaf)) {
        [void]$reasons.Add("MISSING_APK_FILE")
    } else {
        $fullApkPath = [IO.Path]::GetFullPath($ApkPath)
        $apkBytes = [IO.File]::ReadAllBytes($fullApkPath)
        $actualApkFileSha256 = Get-Sha256Lower -Bytes $apkBytes
        if ($manifestApkSha256 -and ($actualApkFileSha256 -ne $manifestApkSha256)) {
            [void]$reasons.Add("BUILD_MANIFEST_APK_SHA256_MISMATCH")
        }

        $hasManifestEntry = $false
        $hasDexEntry = $false
        $zip = $null
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($fullApkPath)
            $hasManifestEntry = ($null -ne $zip.GetEntry("AndroidManifest.xml"))
            $hasDexEntry = ($null -ne $zip.GetEntry("classes.dex"))

            $keyEntry = $zip.GetEntry("assets/ota-release-public.der")
            if ($null -ne $keyEntry -and $keyEntry.Length -ge 200) {
                $ms = New-Object System.IO.MemoryStream
                $st = $keyEntry.Open()
                try { $st.CopyTo($ms) } finally { $st.Dispose() }
                $apkKeyBytes = $ms.ToArray()
                $ms.Dispose()
                if ($apkKeyBytes.Length -ge 200 -and $apkKeyBytes.Length -le 1024 -and $apkKeyBytes[0] -eq 0x30) {
                    $apkBundledKeyPresent = $true
                    $apkBundledKeySha256 = Get-Sha256Lower -Bytes $apkKeyBytes
                } else {
                    [void]$reasons.Add("APK_INVALID_BUNDLED_OTA_KEY")
                }
            } else {
                [void]$reasons.Add("APK_MISSING_OTA_RELEASE_PUBLIC_DER")
            }

            $chEntry = $zip.GetEntry("assets/ota-release-channel.txt")
            if ($null -ne $chEntry -and $chEntry.Length -gt 0) {
                $chMs = New-Object System.IO.MemoryStream
                $chStream = $chEntry.Open()
                try { $chStream.CopyTo($chMs) } finally { $chStream.Dispose() }
                $chRawBytes = $chMs.ToArray()
                $chMs.Dispose()
                $formatValid = ($chRawBytes.Length -ge 20 -and $chRawBytes.Length -le 512 -and $chRawBytes[$chRawBytes.Length - 1] -eq 0x0A)
                if ($formatValid) {
                    for ($idx = 0; $idx -lt ($chRawBytes.Length - 1); $idx++) {
                        $b = $chRawBytes[$idx]
                        if ($b -lt 33 -or $b -gt 126) {
                            $formatValid = $false
                            break
                        }
                    }
                }
                if (-not $formatValid) {
                    [void]$reasons.Add("APK_INVALID_BUNDLED_OTA_CHANNEL_FORMAT")
                } else {
                    $channelLine = [Text.Encoding]::ASCII.GetString($chRawBytes, 0, $chRawBytes.Length - 1)
                    $chUri = Test-StrictOtaManifestUrl -CandidateUrl $channelLine
                    if ($null -ne $chUri) {
                        $apkBundledChannelPresent = $true
                        $apkBundledChannelUrl = $chUri.AbsoluteUri
                    } else {
                        [void]$reasons.Add("APK_INVALID_BUNDLED_OTA_CHANNEL")
                    }
                }
            } else {
                [void]$reasons.Add("APK_MISSING_OTA_RELEASE_CHANNEL_TXT")
            }
        } catch {
            [void]$reasons.Add("APK_ARCHIVE_CORRUPT_OR_NOT_ZIP")
        } finally {
            if ($null -ne $zip) { $zip.Dispose() }
        }

        if ($trustKeySha256 -and $apkBundledKeySha256 -and $apkBundledKeySha256 -ne $trustKeySha256) {
            [void]$reasons.Add("APK_PUBLIC_KEY_MISMATCH_WITH_TRUST_DIR")
        }
        if ($channelConfigured -and $apkBundledChannelUrl -and $apkBundledChannelUrl -ne $effectiveUrl) {
            [void]$reasons.Add("APK_CHANNEL_URL_MISMATCH")
        }

        # Verifica binaria autoritativa dell'APK (apksigner + aapt badging + aapt xmltree).
        # Un JSON handoff o un report mock non bastano MAI a certificare otaReady=true.
        $signerReport = $null
        $badgingReport = $null
        $xmltreeReport = $null

        if ($useMocks) {
            # Qualsiasi parametro -Mock* impedisce incondizionatamente otaReady=true e apkBinaryProven=true.
            [void]$reasons.Add("APK_MOCK_EVIDENCE_NOT_AUTHORITATIVE")
            if ((-not [string]::IsNullOrWhiteSpace($MockApksignerReportPath)) -and
                (-not [string]::IsNullOrWhiteSpace($MockAaptBadgingPath)) -and
                (-not [string]::IsNullOrWhiteSpace($MockAaptXmltreePath)) -and
                (Test-Path -LiteralPath $MockApksignerReportPath -PathType Leaf) -and
                (Test-Path -LiteralPath $MockAaptBadgingPath -PathType Leaf) -and
                (Test-Path -LiteralPath $MockAaptXmltreePath -PathType Leaf)) {
                $signerReport = Get-Content -LiteralPath $MockApksignerReportPath -Raw -Encoding UTF8
                $badgingReport = Get-Content -LiteralPath $MockAaptBadgingPath -Raw -Encoding UTF8
                $xmltreeReport = Get-Content -LiteralPath $MockAaptXmltreePath -Raw -Encoding UTF8
            } else {
                $apkArtifactClass = "REJECTED_INCOMPLETE_MOCK_EVIDENCE"
                [void]$reasons.Add("APK_AUTHORITATIVE_MOCK_EVIDENCE_MISSING")
            }
        } else {
            $javaExe = Find-JavaExecutable
            $apksignerJar = Find-AndroidBuildTool -RelativeNames @("lib\apksigner.jar", "lib/apksigner.jar")
            $aaptExe = Find-AndroidBuildTool -RelativeNames @("aapt.exe", "aapt")

            if (-not $javaExe -or -not $apksignerJar -or -not $aaptExe) {
                [void]$reasons.Add("ANDROID_SDK_AUTHORITATIVE_TOOLS_UNAVAILABLE")
            } else {
                $prevEap = $ErrorActionPreference
                $ErrorActionPreference = "Continue"
                try {
                    $sOut = (& $javaExe -jar $apksignerJar verify --verbose --print-certs $fullApkPath 2>&1 | Out-String)
                    $sExit = $LASTEXITCODE
                    $bOut = (& $aaptExe dump badging $fullApkPath 2>&1 | Out-String)
                    $bExit = $LASTEXITCODE
                    $xOut = (& $aaptExe dump xmltree $fullApkPath AndroidManifest.xml 2>&1 | Out-String)
                    $xExit = $LASTEXITCODE
                } finally {
                    $ErrorActionPreference = $prevEap
                }

                if ($sExit -eq 0 -and $bExit -eq 0 -and $xExit -eq 0) {
                    $realToolsVerified = $true
                    $signerReport = $sOut
                    $badgingReport = $bOut
                    $xmltreeReport = $xOut
                } else {
                    if ($hasManifestEntry -and $hasDexEntry -and $apkBundledKeyPresent -and $apkBundledChannelPresent) {
                        $apkArtifactClass = "SYNTHETIC_HOST_FIXTURE"
                        [void]$reasons.Add("APK_SYNTHETIC_FIXTURE_NOT_OWNER_SIGNED")
                    } else {
                        $apkArtifactClass = "UNVERIFIED_OR_UNSIGNED_APK"
                        [void]$reasons.Add("APK_AUTHORITATIVE_TOOL_VERIFICATION_FAILED")
                    }
                }
            }
        }

        if ($null -ne $signerReport -and $null -ne $badgingReport -and $null -ne $xmltreeReport) {
            $binaryErrors = [System.Collections.Generic.List[string]]::new()

            $signerMatches = [regex]::Matches($signerReport, '(?im)Signer #([0-9]+) certificate SHA-256 digest:\s*([0-9a-f]{64})\s*$')
            if ($signerMatches.Count -ne 1 -or $signerMatches[0].Groups[1].Value -ne '1') {
                [void]$binaryErrors.Add("APK_BINARY_SIGNER_DIGEST_INVALID")
            } else {
                $apkActualSignerSha256 = $signerMatches[0].Groups[2].Value.ToLowerInvariant()
                if ($apkActualSignerSha256 -ne $expectedOwnerSigner) {
                    [void]$binaryErrors.Add("APK_BINARY_SIGNER_MISMATCH")
                }
                if ($manifestSignerSha256 -and ($apkActualSignerSha256 -ne $manifestSignerSha256)) {
                    [void]$binaryErrors.Add("APK_BINARY_SIGNER_MISMATCH_WITH_MANIFEST")
                }
            }

            $countMatches = [regex]::Matches($signerReport, '(?im)^Number of signers:\s*([0-9]+)\s*$')
            if ($countMatches.Count -ne 1 -or $countMatches[0].Groups[1].Value -ne '1') {
                [void]$binaryErrors.Add("APK_BINARY_SIGNER_COUNT_INVALID")
            }

            $v2Matches = [regex]::Matches($signerReport, '(?im)^Verified using v2 scheme \(APK Signature Scheme v2\):\s*(true|false)\s*$')
            if ($v2Matches.Count -ne 1 -or $v2Matches[0].Groups[1].Value.ToLowerInvariant() -ne 'true') {
                [void]$binaryErrors.Add("APK_BINARY_V2_SIGNATURE_UNVERIFIED")
            }

            $pkgMatches = [regex]::Matches($badgingReport, "(?m)^package:\s+name='([^']+)'\s+versionCode='([0-9]+)'\s+versionName='([^']+)'(?:\s+[^\r\n]*)?$")
            if ($pkgMatches.Count -ne 1) {
                [void]$binaryErrors.Add("APK_BINARY_BADGING_PACKAGE_INVALID")
            } else {
                $apkActualPackageName = $pkgMatches[0].Groups[1].Value
                $apkActualVersionCode = [int]$pkgMatches[0].Groups[2].Value
                $apkActualVersionName = $pkgMatches[0].Groups[3].Value
                if ($apkActualPackageName -ne $expectedPackage) {
                    [void]$binaryErrors.Add("APK_BINARY_PACKAGE_NAME_MISMATCH")
                }
                if ($null -ne $manifestVersionCode -and $apkActualVersionCode -ne $manifestVersionCode) {
                    [void]$binaryErrors.Add("APK_BINARY_VERSION_CODE_MISMATCH_WITH_MANIFEST")
                }
                if ($manifestVersionName -and $apkActualVersionName -ne $manifestVersionName) {
                    [void]$binaryErrors.Add("APK_BINARY_VERSION_NAME_MISMATCH_WITH_MANIFEST")
                }
            }

            $sdkMatches = [regex]::Matches($badgingReport, "(?m)^sdkVersion:\s*'([^']*)'\s*$")
            $targetMatches = [regex]::Matches($badgingReport, "(?m)^targetSdkVersion:\s*'([^']*)'\s*$")
            $nativeMatches = [regex]::Matches($badgingReport, "(?m)^native-code:\s*(.*)$")
            if ($sdkMatches.Count -ne 1 -or $sdkMatches[0].Groups[1].Value -ne '21' -or
                $targetMatches.Count -ne 1 -or $targetMatches[0].Groups[1].Value -ne '28') {
                [void]$binaryErrors.Add("APK_BINARY_SDK_LEVEL_MISMATCH")
            }
            if ($nativeMatches.Count -ne 1 -or $nativeMatches[0].Groups[1].Value.Trim() -ne "'armeabi-v7a'") {
                [void]$binaryErrors.Add("APK_BINARY_ABI_MISMATCH")
            }

            $dbgAttrMatches = [regex]::Matches($xmltreeReport, '(?im)^\s*A:\s+android:debuggable(?:\(0x[0-9a-f]+\))?\s*=')
            $isCompiledDbgTrue = $xmltreeReport -match '(?im)A:\s+android:debuggable(?:\(0x[0-9a-f]+\))?\s*=\s*\(type 0x12\)0xffffffff(?:\s|$)'
            $isCompiledDbgFalse = $xmltreeReport -match '(?im)A:\s+android:debuggable(?:\(0x[0-9a-f]+\))?\s*=\s*\(type 0x12\)0x0(?:\s|$)'

            if ($dbgAttrMatches.Count -ne 1 -or ((-not $isCompiledDbgTrue) -and (-not $isCompiledDbgFalse))) {
                [void]$binaryErrors.Add("APK_BINARY_DEBUGGABLE_FLAG_AMBIGUOUS")
            } else {
                $apkActualDebuggable = [bool]$isCompiledDbgTrue
                if ($ChannelProfile -eq 'Staging' -and (-not $apkActualDebuggable)) {
                    [void]$binaryErrors.Add("APK_BINARY_STAGING_NOT_DEBUGGABLE")
                } elseif ($ChannelProfile -eq 'Release' -and $apkActualDebuggable) {
                    [void]$binaryErrors.Add("APK_BINARY_RELEASE_DEBUGGABLE_FORBIDDEN")
                }
                if ($null -ne $manifestDebuggable -and ($apkActualDebuggable -ne $manifestDebuggable)) {
                    [void]$binaryErrors.Add("APK_BINARY_DEBUGGABLE_MISMATCH_WITH_MANIFEST")
                }
            }

            foreach ($be in $binaryErrors) {
                [void]$reasons.Add($be)
            }

            if ($binaryErrors.Count -eq 0) {
                if ((-not $useMocks) -and $realToolsVerified) {
                    $apkBinaryProven = $true
                    $apkArtifactClass = "OWNER_SIGNED_APK_VERIFIED"
                } else {
                    $apkBinaryProven = $false
                    $apkArtifactClass = "MOCK_EVIDENCE_NON_AUTHORITATIVE"
                }
            } else {
                $apkBinaryProven = $false
                $apkArtifactClass = "REJECTED_APK_BINARY_MISMATCH"
            }
        }
    }
}

$inventoryReady = ($reasons.Count -eq 0) -and (-not $useMocks) -and $trustKeyPresent -and $channelConfigured
$otaReady = (-not $InventoryOnly) -and
            (-not $useMocks) -and
            $realToolsVerified -and
            ($reasons.Count -eq 0) -and
            $trustKeyPresent -and
            $channelConfigured -and
            $manifestChecked -and
            ($manifestOtaProvisioned -eq $true) -and
            $apkChecked -and
            $apkBundledKeyPresent -and
            $apkBundledChannelPresent -and
            $apkBinaryProven

$status = if ($InventoryOnly) {
    if ($inventoryReady) { "OTA_TRUST_INVENTORY_ONLY" } else { "OTA_TRUST_INVENTORY_INCOMPLETE" }
} elseif ($otaReady) {
    "OTA_PROVISIONED_READY"
} elseif ($useMocks) {
    "OTA_MOCK_EVIDENCE_NOT_AUTHORITATIVE"
} elseif ($apkArtifactClass -eq "SYNTHETIC_HOST_FIXTURE" -and ($reasons.Count -eq 1) -and ($reasons[0] -eq "APK_SYNTHETIC_FIXTURE_NOT_OWNER_SIGNED")) {
    "OTA_SYNTHETIC_FIXTURE_NOT_OWNER_SIGNED_APK"
} else {
    "OTA_UNPROVISIONED_NOT_READY"
}

$verdict = [ordered]@{
    otaReady = $otaReady
    inventoryOnly = [bool]$InventoryOnly
    inventoryReady = $inventoryReady
    mockEvidenceInjected = [bool]$useMocks
    realToolsVerified = [bool]$realToolsVerified
    status = $status
    channelProfile = $ChannelProfile
    trustDirectoryPresent = $trustDirExists
    trustKeyPresent = $trustKeyPresent
    trustKeySha256 = $trustKeySha256
    channelConfigured = $channelConfigured
    manifestChecked = $manifestChecked
    manifestVersionCode = $manifestVersionCode
    manifestBuildProfile = $manifestBuildProfile
    manifestDebuggable = $manifestDebuggable
    manifestSignerSha256 = $manifestSignerSha256
    manifestOtaProvisioned = $manifestOtaProvisioned
    apkChecked = $apkChecked
    apkArtifactClass = $apkArtifactClass
    apkBinaryProven = $apkBinaryProven
    apkBundledKeyPresent = $apkBundledKeyPresent
    apkBundledKeySha256 = $apkBundledKeySha256
    apkBundledChannelPresent = $apkBundledChannelPresent
    apkActualPackageName = $apkActualPackageName
    apkActualVersionCode = $apkActualVersionCode
    apkActualVersionName = $apkActualVersionName
    apkActualDebuggable = $apkActualDebuggable
    apkActualSignerSha256 = $apkActualSignerSha256
    nextRecommendedReleaseVersionCode = $nextRecommendedReleaseVersionCode
    reasons = @($reasons)
}

Write-Output ($verdict | ConvertTo-Json -Depth 4)
if ($InventoryOnly) {
    if (-not $inventoryReady) { exit 1 }
    exit 0
}
if (-not $otaReady) {
    exit 1
}
exit 0
