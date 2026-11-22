# ==============================================================================
# AKAI Custom TV - Script 17: CHECK READ-ONLY OTA RELEASE PROVISIONING READINESS
# Verifica rigorosamente in sola lettura se la trust root OTA offline e l'APK
# candidato risultano provisionati con chiave pubblica pinned + manifest URL HTTPS.
# Non genera ne' scrive mai chiavi reali; exit 1 finche' OTA non e' pronto.
# Zero comandi ADB.
# ==============================================================================

param(
    [string]$ApkPath = $null,
    [string]$BuildManifestPath = $null,
    [string]$OtaReleasePublicKeyPath = $null,
    [string]$OtaReleaseManifestUrl = $null,
    [ValidateSet('Release', 'Staging')]
    [string]$ChannelProfile = 'Release',
    [ValidateRange(0, 2147483646)]
    [int]$RescueVersionCode = 0
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

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
    if (-not $rawPath.EndsWith(".manifest", [StringComparison]::Ordinal)) { return $null }
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
$manifestVersionCode = $null
$manifestOtaProvisioned = $null
$nextRecommendedReleaseVersionCode = 6

$manFloor = 0
if (-not [string]::IsNullOrWhiteSpace($BuildManifestPath)) {
    if (-not (Test-Path -LiteralPath $BuildManifestPath -PathType Leaf)) {
        [void]$reasons.Add("MISSING_BUILD_MANIFEST")
    } else {
        $man = Get-Content -LiteralPath $BuildManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($man.versionCode) {
            $manifestVersionCode = [int]$man.versionCode
            $manFloor = $manifestVersionCode + 1
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$man.buildProfile)) {
            $prof = [string]$man.buildProfile
            if ($ChannelProfile -eq 'Staging') {
                if ($prof -ne 'Diagnostic') {
                    [void]$reasons.Add("STAGING_BUILD_MANIFEST_PROFILE_MISMATCH")
                }
                if ($man.versionCode -and [int]$man.versionCode -gt 99) {
                    [void]$reasons.Add("STAGING_VERSION_CODE_OUT_OF_RANGE")
                }
            } elseif ($ChannelProfile -eq 'Release' -and $prof -ne 'Release') {
                [void]$reasons.Add("RELEASE_BUILD_MANIFEST_PROFILE_MISMATCH")
            }
        }
        if ($null -ne $man.otaProvisioned) {
            $manifestOtaProvisioned = [bool]$man.otaProvisioned
            if (-not $manifestOtaProvisioned) {
                [void]$reasons.Add("BUILD_MANIFEST_OTA_NOT_PROVISIONED")
            }
        }
        if ([string]::IsNullOrWhiteSpace($effectiveUrl) -and $man.otaReleaseManifestUrl) {
            $effectiveUrl = [string]$man.otaReleaseManifestUrl
        }
        if ($trustKeySha256 -and $man.otaReleasePublicKeySha256 -and ([string]$man.otaReleasePublicKeySha256).ToLowerInvariant() -ne $trustKeySha256) {
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

if (-not [string]::IsNullOrWhiteSpace($ApkPath)) {
    $apkChecked = $true
    if (-not (Test-Path -LiteralPath $ApkPath -PathType Leaf)) {
        [void]$reasons.Add("MISSING_APK_FILE")
    } else {
        $zip = [System.IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($ApkPath))
        try {
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
        } finally {
            $zip.Dispose()
        }

        if ($trustKeySha256 -and $apkBundledKeySha256 -and $apkBundledKeySha256 -ne $trustKeySha256) {
            [void]$reasons.Add("APK_PUBLIC_KEY_MISMATCH_WITH_TRUST_DIR")
        }
        if ($channelConfigured -and $apkBundledChannelUrl -and $apkBundledChannelUrl -ne $effectiveUrl) {
            [void]$reasons.Add("APK_CHANNEL_URL_MISMATCH")
        }
    }
}

$otaReady = ($reasons.Count -eq 0) -and $trustKeyPresent -and $channelConfigured -and ((-not $apkChecked) -or ($apkBundledKeyPresent -and $apkBundledChannelPresent))
$verdict = [ordered]@{
    otaReady = $otaReady
    status = if ($otaReady) { "OTA_PROVISIONED_READY" } else { "OTA_UNPROVISIONED_NOT_READY" }
    trustDirectoryPresent = $trustDirExists
    trustKeyPresent = $trustKeyPresent
    trustKeySha256 = $trustKeySha256
    channelConfigured = $channelConfigured
    manifestVersionCode = $manifestVersionCode
    manifestOtaProvisioned = $manifestOtaProvisioned
    apkChecked = $apkChecked
    apkBundledKeyPresent = $apkBundledKeyPresent
    apkBundledKeySha256 = $apkBundledKeySha256
    apkBundledChannelPresent = $apkBundledChannelPresent
    nextRecommendedReleaseVersionCode = $nextRecommendedReleaseVersionCode
    reasons = @($reasons)
}

Write-Output ($verdict | ConvertTo-Json -Depth 4)
if (-not $otaReady) {
    exit 1
}
exit 0
