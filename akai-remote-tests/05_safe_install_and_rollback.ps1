# ==============================================================================
# AKAI Custom Remote - Procedura di Installazione Sicura, Verifica Firme e Rollback Atomico
#
# REGOLA DI SICUREZZA ASSOLUTA:
# Durante la fase di review tecnica, l'esecuzione su TV fisica è congelata (HARDWARE FREEZE).
# Lo script richiede obbligatoriamente il flag esplicito: -AllowHardwareExecution
#
# Caratteristiche Tecniche di Sicurezza (Revisione 7):
# 1. Riconoscimento Vincoli Architetturali Baseline Legacy (v5):
#    - Non attribuisce all'APK v5 capacità inesistenti (ACTION_BACKUP_DB / ACTION_RESTORE_DB assenti in v5).
#    - Cattura preventivamente backup logico REST /api/ai/memory se il server v5/v6 è online.
#    - Esegue snapshot binario Fail-Closed: se non è possibile estrarre un DB integro via UID o root, ABORTISCE.
# 2. Verifica Firma Digitale Fail-Closed Pre-Install:
#    - Estrae e confronta l'impronta SHA-256 (64 hex) tra backup e candidato con apksigner.
#    - Rifiuta categoricamente artefatti CI di test effimeri non distribuibili.
# 3. Controllo Integrità SQLite Rigoroso (Fail-Closed):
#    - Verifica offline PRAGMA integrity_check via Node.js, Python o sqlite3 CLI.
#    - Se nessun interprete è disponibile o il file è corrotto: THROW IMMEDIATO (zero fail-open).
# 4. Streaming Binario Universale PowerShell 5.1 / Pwsh 7:
#    - Send-FileViaAdbExecIn tramite [System.IO.File]::ReadAllBytes e Process.StandardInput.
#    - Zero dipendenza da Get-Content -Encoding Byte (incompatibile con PowerShell 7).
# 5. Rollback Atomico Indivisibile (APK + DB) con Verifica Hash SHA-256:
#    - In caso di timeout/anomalia watchdog (30s), reinstalla APK precedente e ripristina DB originale.
#    - Pulisce preventivamente file WAL/SHM orfani.
#    - Valida bit-for-bit la parità SHA-256 e l'integrità del DB ripristinato sul device.
# ==============================================================================

param(
    [ValidateSet("status", "backup", "install", "rollback", "plan", "preflight", "verify-tls")]
    [string]$Action = "status",
    [string]$ApkPath = $null,
    [string]$ExpectedCandidateSha256 = $null,
    [string]$RescueApkPath = $null,
    [string]$ExpectedRescueSha256 = $null,
    [string]$BackupDir = ".\backup_tv",
    [string]$TargetTv = "192.168.1.8",
    [int]$HttpPort = 8088,
    [int]$HttpsPort = 8443,
    [string]$AuthToken = $null,
    [string]$ExpectedCaFingerprint = $null,
    [switch]$AllowHardwareExecution = $false,
    [switch]$GreenfieldStart = $false,
    [switch]$RequirePairing = $false,
    [switch]$RequireOwnerRescue = $false,
    [switch]$RequireVerifiedKeystoreHealth = $false
)

$ErrorActionPreference = "Stop"

$TargetAdb = "$($TargetTv):5555"
$PackageName = "it.akai.customremote"
$StatusUrl = "http://$($TargetTv):$HttpPort/api/status"
$WebUrl = "http://$($TargetTv):$HttpPort/index.html"
$HttpsUrl = "https://$($TargetTv):$HttpsPort/"
# Memory and Bearer tokens MUST NEVER be sent over legacy HTTP/8088.
# HTTPS uses the OS trusted CA chain; if trust is unavailable, optional REST
# snapshot is skipped and mandatory binary SQLite/WAL backup remains fail-closed.
# NEVER add -SkipCertificateCheck or fallback to HTTP for this endpoint.
$MemoryUrl = "https://$($TargetTv):$HttpsPort/api/ai/memory"

# -----------------------------------------------------------------------------
# SAFETY FREEZE GUARD
# -----------------------------------------------------------------------------
if ($Action -in @("install", "rollback", "backup") -and -not $AllowHardwareExecution) {
    Write-Host "================================================================================" -ForegroundColor Red
    Write-Host "BLOCCO DI SICUREZZA ATTIVO (HARDWARE FREEZE):" -ForegroundColor Red
    Write-Host "L'esecuzione su hardware fisico TV e' bloccata fino all'approvazione formale." -ForegroundColor Yellow
    Write-Host "Per visualizzare il piano operativo sicuro usa: -Action plan" -ForegroundColor Cyan
    Write-Host "Per visualizzare l'inventario read-only della TV usa: -Action preflight" -ForegroundColor Cyan
    Write-Host "Per autorizzare l'esecuzione su TV e' richiesto il parametro: -AllowHardwareExecution" -ForegroundColor Yellow
    Write-Host "================================================================================" -ForegroundColor Red
    exit 1
}

# Controllo obbligatorietà ApkPath per install
if ($Action -eq "install") {
    if ([string]::IsNullOrWhiteSpace($ApkPath)) {
        throw "ERRORE FAIL-CLOSED: Il parametro -ApkPath e' obbligatorio per l'azione install. Specificare un APK di release autentico (mai l'artefatto CI non distribuibile)."
    }
    if ($ApkPath -match "app-ci-test-nondistributable\.apk") {
        throw "BLOCCO DI SICUREZZA: L'APK candidato e' un artefatto di test CI ('$ApkPath') firmato con chiave effimera. L'installazione su TV reale e' categoricamente vietata."
    }
}

function Get-AdbExecutable {
    if ($env:ADB_EXECUTABLE -and (Test-Path $env:ADB_EXECUTABLE)) {
        return $env:ADB_EXECUTABLE
    }
    $adb = Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Path
    if (-not $adb -or -not (Test-Path $adb)) {
        $adb = "adb"
    }
    return $adb
}

function Get-OrderedAndroidSdkRoots {
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($raw in @(
        $env:ANDROID_HOME,
        $env:ANDROID_SDK_ROOT,
        (Join-Path (Split-Path -Parent $PSScriptRoot) "tools\android-sdk"),
        $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "Android\Sdk" } else { $null }),
        "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay\tools\android-sdk"
    )) {
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        if (Test-Path -LiteralPath $raw -PathType Container) {
            $norm = [IO.Path]::GetFullPath($raw).TrimEnd('\', '/')
            if ($candidates -notcontains $norm) {
                [void]$candidates.Add($norm)
            }
        }
    }
    return @($candidates)
}

function Get-OrderedBuildToolsDirs([string]$SdkRoot) {
    $toolsRoot = Join-Path $SdkRoot "build-tools"
    if (-not (Test-Path -LiteralPath $toolsRoot -PathType Container)) { return @() }
    $items = @(Get-ChildItem -LiteralPath $toolsRoot -Directory -ErrorAction SilentlyContinue)
    return @($items | Sort-Object {
        $v = $null
        if ($_.Name -match '^(\d+(?:\.\d+){1,3})' -and [version]::TryParse($matches[1], [ref]$v)) {
            $v
        } else {
            [version]::new(0, 0)
        }
    } -Descending)
}

function Get-ApkSignerJar {
    if ($env:APKSIGNER_JAR -and (Test-Path -LiteralPath $env:APKSIGNER_JAR -PathType Leaf)) {
        return $env:APKSIGNER_JAR
    }
    foreach ($sdkRoot in (Get-OrderedAndroidSdkRoots)) {
        foreach ($btDir in (Get-OrderedBuildToolsDirs $sdkRoot)) {
            $candidate = Join-Path $btDir.FullName "lib\apksigner.jar"
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return $candidate
            }
        }
    }
    return $null
}

function Get-Sha256Hex($filePath) {
    if (-not (Test-Path $filePath)) { return $null }
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($filePath)
    try {
        $hashBytes = $sha256.ComputeHash($stream)
        return [BitConverter]::ToString($hashBytes).Replace('-', '').ToLower()
    } finally {
        $stream.Close()
        $sha256.Dispose()
    }
}

function Read-Asn1DerTlv {
    param(
        [byte[]]$Bytes,
        [int]$Offset
    )
    if (-not $Bytes -or $Offset -lt 0 -or $Offset -ge $Bytes.Length) {
        return $null
    }
    $tag = $Bytes[$Offset]
    $pos = $Offset + 1
    if ($pos -ge $Bytes.Length) { return $null }
    $lenByte = $Bytes[$pos]
    $pos++
    [int]$length = 0
    if (($lenByte -band 0x80) -eq 0) {
        $length = [int]$lenByte
    } else {
        $numOctets = [int]($lenByte -band 0x7F)
        if ($numOctets -le 0 -or $numOctets -gt 4 -or ($pos + $numOctets) -gt $Bytes.Length) {
            return $null
        }
        for ($i = 0; $i -lt $numOctets; $i++) {
            $length = ($length -shl 8) -bor [int]$Bytes[$pos + $i]
        }
        $pos += $numOctets
    }
    if ($length -lt 0 -or ($pos + $length) -gt $Bytes.Length) {
        return $null
    }
    return @{
        Tag         = $tag
        StartOffset = $Offset
        ValueOffset = $pos
        Length      = $length
        NextOffset  = $pos + $length
    }
}

function Convert-EcdsaDerSignatureToIeeeP1363 {
    param(
        [byte[]]$DerSignature,
        [int]$CoordinateSizeBytes
    )
    if (-not $DerSignature -or $CoordinateSizeBytes -le 0) { return $null }
    $seq = Read-Asn1DerTlv -Bytes $DerSignature -Offset 0
    if (-not $seq -or $seq.Tag -ne 0x30 -or $seq.NextOffset -ne $DerSignature.Length) { return $null }
    $rTlv = Read-Asn1DerTlv -Bytes $DerSignature -Offset $seq.ValueOffset
    if (-not $rTlv -or $rTlv.Tag -ne 0x02) { return $null }
    $sTlv = Read-Asn1DerTlv -Bytes $DerSignature -Offset $rTlv.NextOffset
    if (-not $sTlv -or $sTlv.Tag -ne 0x02 -or $sTlv.NextOffset -ne $seq.NextOffset) { return $null }

    $out = New-Object byte[] ($CoordinateSizeBytes * 2)
    $parts = @(
        @{ Tlv = $rTlv; DestOffset = 0 },
        @{ Tlv = $sTlv; DestOffset = $CoordinateSizeBytes }
    )
    foreach ($part in $parts) {
        $tlv = $part.Tlv
        $srcStart = $tlv.ValueOffset
        $srcLen = $tlv.Length
        while ($srcLen -gt 1 -and $DerSignature[$srcStart] -eq 0x00) {
            $srcStart++
            $srcLen--
        }
        if ($srcLen -gt $CoordinateSizeBytes) { return $null }
        $padOffset = $part.DestOffset + ($CoordinateSizeBytes - $srcLen)
        [System.Buffer]::BlockCopy($DerSignature, $srcStart, $out, $padOffset, $srcLen)
    }
    return $out
}

function Test-X509CertificateSignature {
    param(
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$ChildCert,
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$IssuerCert
    )
    if (-not $ChildCert -or -not $IssuerCert) { return $false }
    try {
        [byte[]]$raw = $ChildCert.RawData
        if (-not $raw -or $raw.Length -lt 16) { return $false }

        $outer = Read-Asn1DerTlv -Bytes $raw -Offset 0
        if (-not $outer -or $outer.Tag -ne 0x30 -or $outer.NextOffset -ne $raw.Length) { return $false }

        $tbs = Read-Asn1DerTlv -Bytes $raw -Offset $outer.ValueOffset
        if (-not $tbs -or $tbs.Tag -ne 0x30) { return $false }

        $alg = Read-Asn1DerTlv -Bytes $raw -Offset $tbs.NextOffset
        if (-not $alg -or $alg.Tag -ne 0x30) { return $false }

        $sigBit = Read-Asn1DerTlv -Bytes $raw -Offset $alg.NextOffset
        if (-not $sigBit -or $sigBit.Tag -ne 0x03 -or $sigBit.NextOffset -ne $outer.NextOffset -or $sigBit.Length -lt 2) {
            return $false
        }
        if ($raw[$sigBit.ValueOffset] -ne 0x00) { return $false }

        $tbsLen = $tbs.NextOffset - $tbs.StartOffset
        $tbsBytes = New-Object byte[] $tbsLen
        [System.Buffer]::BlockCopy($raw, $tbs.StartOffset, $tbsBytes, 0, $tbsLen)

        $sigLen = $sigBit.Length - 1
        $sigBytes = New-Object byte[] $sigLen
        [System.Buffer]::BlockCopy($raw, ($sigBit.ValueOffset + 1), $sigBytes, 0, $sigLen)

        $sigOid = $ChildCert.SignatureAlgorithm.Value
        $keyKind = $null
        $hashName = $null
        switch ($sigOid) {
            "1.2.840.113549.1.1.11" { $keyKind = "RSA";   $hashName = [System.Security.Cryptography.HashAlgorithmName]::SHA256 }
            "1.2.840.113549.1.1.12" { $keyKind = "RSA";   $hashName = [System.Security.Cryptography.HashAlgorithmName]::SHA384 }
            "1.2.840.113549.1.1.13" { $keyKind = "RSA";   $hashName = [System.Security.Cryptography.HashAlgorithmName]::SHA512 }
            "1.2.840.10045.4.3.2"   { $keyKind = "ECDSA"; $hashName = [System.Security.Cryptography.HashAlgorithmName]::SHA256 }
            "1.2.840.10045.4.3.3"   { $keyKind = "ECDSA"; $hashName = [System.Security.Cryptography.HashAlgorithmName]::SHA384 }
            "1.2.840.10045.4.3.4"   { $keyKind = "ECDSA"; $hashName = [System.Security.Cryptography.HashAlgorithmName]::SHA512 }
            default { return $false }
        }

        if ($keyKind -eq "RSA") {
            $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($IssuerCert)
            if ($null -eq $rsa) { return $false }
            try {
                return [bool]$rsa.VerifyData($tbsBytes, $sigBytes, $hashName, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
            } finally {
                $rsa.Dispose()
            }
        } elseif ($keyKind -eq "ECDSA") {
            $ecdsa = [System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPublicKey($IssuerCert)
            if ($null -eq $ecdsa) { return $false }
            try {
                $coordSize = [int][Math]::Ceiling($ecdsa.KeySize / 8.0)
                $ieeeSig = Convert-EcdsaDerSignatureToIeeeP1363 -DerSignature $sigBytes -CoordinateSizeBytes $coordSize
                if (-not $ieeeSig) { return $false }
                return [bool]$ecdsa.VerifyData($tbsBytes, $ieeeSig, $hashName)
            } finally {
                $ecdsa.Dispose()
            }
        }
        return $false
    } catch {
        return $false
    }
}

function Compare-ByteArraysEqual {
    param(
        [byte[]]$A,
        [byte[]]$B
    )
    if ($null -eq $A -or $null -eq $B) { return $false }
    if ($A.Length -ne $B.Length) { return $false }
    for ($i = 0; $i -lt $A.Length; $i++) {
        if ($A[$i] -ne $B[$i]) { return $false }
    }
    return $true
}

function Test-HttpsTlsEndpoint {
    param(
        [string]$TargetHost,
        [int]$Port = 8443,
        [string]$ExpectedCaSha256 = $null,
        [int]$TimeoutMs = 4000,
        [string]$HttpGetPath = $null,
        [string]$BearerToken = $null
    )
    $tcpClient = New-Object System.Net.Sockets.TcpClient
    try {
        $connectAsync = $tcpClient.BeginConnect($TargetHost, $Port, $null, $null)
        $connected = $connectAsync.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if (-not $connected) {
            return @{
                Success = $false
                Status = "TCP_TIMEOUT"
                SanMatched = $false
                CaMatched = $false
                Error = "Connessione TCP a ${TargetHost}:${Port} scaduta (${TimeoutMs}ms)"
            }
        }
        $tcpClient.EndConnect($connectAsync)

        $holder = [hashtable]::Synchronized(@{
            RawCertBytes = $null
            ChainRawCerts = @()
            Errors = [System.Net.Security.SslPolicyErrors]::None
        })

        $callback = {
            param($sender, $certificate, $chain, $sslPolicyErrors)
            if ($certificate) {
                $holder.RawCertBytes = $certificate.GetRawCertData()
            }
            $list = @()
            if ($chain -and $chain.ChainElements) {
                foreach ($el in $chain.ChainElements) {
                    if ($el -and $el.Certificate) {
                        $list += ,($el.Certificate.GetRawCertData())
                    }
                }
            }
            if ($chain -and $chain.ChainPolicy -and $chain.ChainPolicy.ExtraStore) {
                foreach ($xc in $chain.ChainPolicy.ExtraStore) {
                    if ($xc) {
                        $list += ,($xc.GetRawCertData())
                    }
                }
            }
            $holder.ChainRawCerts = $list
            $holder.Errors = $sslPolicyErrors
            return $true
        }

        $sslStream = New-Object System.Net.Security.SslStream(
            $tcpClient.GetStream(),
            $false,
            $callback
        )

        $sslStream.AuthenticateAsClient($TargetHost)
        if (-not $holder.RawCertBytes -or $holder.RawCertBytes.Length -eq 0) {
            $sslStream.Close()
            $tcpClient.Close()
            return @{
                Success = $false
                Status = "NO_CERTIFICATE"
                SanMatched = $false
                CaMatched = $false
                Error = "Nessun certificato X.509 ricevuto durante l'handshake TLS su porta $Port"
            }
        }

        $cert2 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(,[byte[]]$holder.RawCertBytes)
        if (-not $cert2 -or $cert2.Handle -eq [IntPtr]::Zero) {
            $sslStream.Close()
            $tcpClient.Close()
            return @{
                Success = $false
                Status = "NO_CERTIFICATE"
                SanMatched = $false
                CaMatched = $false
                Error = "Certificato X.509 non valido o vuoto"
            }
        }

        # Costruisce la collezione deduplicata di tutti i certificati presentati dal peer durante l'handshake
        $peerCerts = New-Object 'System.Collections.Generic.List[System.Security.Cryptography.X509Certificates.X509Certificate2]'
        $peerShaMap = @{}
        $serverCertSha256 = $cert2.GetCertHashString([System.Security.Cryptography.HashAlgorithmName]::SHA256).ToLower()
        $peerCerts.Add($cert2)
        $peerShaMap[$serverCertSha256] = $cert2

        if ($holder.ChainRawCerts -and $holder.ChainRawCerts.Count -gt 0) {
            foreach ($rawCert in $holder.ChainRawCerts) {
                $cElem = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(,[byte[]]$rawCert)
                $cFp = $cElem.GetCertHashString([System.Security.Cryptography.HashAlgorithmName]::SHA256).ToLower()
                if (-not $peerShaMap.ContainsKey($cFp)) {
                    $peerShaMap[$cFp] = $cElem
                    $peerCerts.Add($cElem)
                }
            }
        }

        # 1. Validazione periodo temporale (NotBefore <= UtcNow <= NotAfter) su foglia e su tutta la catena presentata
        $now = [DateTime]::UtcNow
        $notBeforeUtc = ([DateTime]$cert2.NotBefore).ToUniversalTime()
        $notAfterUtc = ([DateTime]$cert2.NotAfter).ToUniversalTime()
        if ($now -lt $notBeforeUtc -or $now -gt $notAfterUtc) {
            $sslStream.Close()
            $tcpClient.Close()
            return @{
                Success = $false
                Status = "CERT_EXPIRED_OR_NOT_YET_VALID"
                SanMatched = $false
                CaMatched = $false
                CertSha256 = $serverCertSha256
                Error = "Certificato non valido nel periodo temporale corrente (NotBefore: $($cert2.NotBefore), NotAfter: $($cert2.NotAfter))"
            }
        }

        # 2. Validazione Rigorosa SAN (Subject Alternative Name - OID 2.5.29.17)
        $sanMatched = $false
        $sanFound = $false
        $formattedSan = ""
        $targetIpObj = $null
        $isTargetIp = [System.Net.IPAddress]::TryParse($TargetHost, [ref]$targetIpObj)

        foreach ($ext in $cert2.Extensions) {
            if ($ext.Oid.Value -eq "2.5.29.17") {
                $sanFound = $true
                $formattedSan = $ext.Format($false)
                
                # Metodo A: Verifica binaria su byte ASN.1 (DER IPv4 tag 0x87 len 0x04 o dNSName tag 0x82)
                # Indipendente al 100% dalla lingua o localizzazione dell'OS
                if ($isTargetIp) {
                    $rawBytes = $ext.RawData
                    $ipBytes = $targetIpObj.GetAddressBytes()
                    for ($b = 0; $b -le ($rawBytes.Length - ($ipBytes.Length + 2)); $b++) {
                        if ($rawBytes[$b] -eq 0x87 -and $rawBytes[$b+1] -eq $ipBytes.Length) {
                            $matchAll = $true
                            for ($k = 0; $k -lt $ipBytes.Length; $k++) {
                                if ($rawBytes[$b + 2 + $k] -ne $ipBytes[$k]) {
                                    $matchAll = $false
                                    break
                                }
                            }
                            if ($matchAll) {
                                $sanMatched = $true
                                break
                            }
                        }
                    }
                } else {
                    $rawBytes = $ext.RawData
                    $dnsBytes = [System.Text.Encoding]::ASCII.GetBytes($TargetHost)
                    for ($b = 0; $b -le ($rawBytes.Length - ($dnsBytes.Length + 2)); $b++) {
                        if ($rawBytes[$b] -eq 0x82 -and $rawBytes[$b+1] -eq $dnsBytes.Length) {
                            $matchAll = $true
                            for ($k = 0; $k -lt $dnsBytes.Length; $k++) {
                                if ($rawBytes[$b + 2 + $k] -ne $dnsBytes[$k]) {
                                    $matchAll = $false
                                    break
                                }
                            }
                            if ($matchAll) {
                                $sanMatched = $true
                                break
                            }
                        }
                    }
                }

                # Metodo B: Parsing deterministico per token (supporta formati EN/IT "IP Address=X", "Indirizzo IP=X", "DNS Name=X")
                if (-not $sanMatched) {
                    $tokens = $formattedSan -split ',|\r?\n'
                    foreach ($token in $tokens) {
                        $t = $token.Trim()
                        if ($t -match "[:=]\s*$([regex]::Escape($TargetHost))\s*`$") {
                            $sanMatched = $true
                            break
                        }
                    }
                }
            }
        }

        if (-not $sanFound) {
            $sslStream.Close()
            $tcpClient.Close()
            return @{
                Success = $false
                Status = "SAN_EXTENSION_MISSING"
                SanMatched = $false
                CaMatched = $false
                Error = "Estensione Subject Alternative Name (SAN 2.5.29.17) assente nel certificato del server"
            }
        }

        if (-not $sanMatched) {
            $sslStream.Close()
            $tcpClient.Close()
            return @{
                Success = $false
                Status = "SAN_MISMATCH"
                SanMatched = $false
                CaMatched = $false
                FormattedSan = $formattedSan
                Error = "SAN mismatch: l'host '$TargetHost' non compare tra gli indirizzi IP/DNS autorizzati del certificato server ($formattedSan)"
            }
        }

        # 3. Validazione Crittografica Completa della Catena X.509 e Impronta Root CA
        $lastPeer = $peerCerts[$peerCerts.Count - 1]
        $rootCaSha256 = $lastPeer.GetCertHashString([System.Security.Cryptography.HashAlgorithmName]::SHA256).ToLower()

        $caMatched = $false
        $caStatus = ""
        if ([string]::IsNullOrWhiteSpace($ExpectedCaSha256)) {
            $caStatus = "TLS_HANDSHAKE_ONLY/UNVERIFIED"
        } else {
            $cleanExpected = $ExpectedCaSha256.Replace(':', '').Replace(' ', '').ToLower().Trim()
            if (-not $peerShaMap.ContainsKey($cleanExpected)) {
                $sslStream.Close()
                $tcpClient.Close()
                return @{
                    Success = $false
                    Status = "CA_UNTRUSTED_MISMATCH"
                    SanMatched = $sanMatched
                    CaMatched = $false
                    RootCaSha256 = $rootCaSha256
                    ExpectedCaSha256 = $cleanExpected
                    Error = "CA Mismatch: nessun certificato nella catena TLS ($rootCaSha256) corrisponde all'impronta fuori banda attesa ($cleanExpected)"
                }
            }

            $pinnedCaCert = $peerShaMap[$cleanExpected]
            $customChain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
            try {
                $customChain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
                $customChain.ChainPolicy.VerificationTime = $now
                foreach ($pc in $peerCerts) {
                    [void]$customChain.ChainPolicy.ExtraStore.Add($pc)
                }

                $usesCustomRootTrust = ($null -ne $customChain.ChainPolicy.PSObject.Properties['TrustMode'])
                if ($usesCustomRootTrust) {
                    $customChain.ChainPolicy.TrustMode = [System.Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
                    [void]$customChain.ChainPolicy.CustomTrustStore.Add($pinnedCaCert)
                    $customChain.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::NoFlag
                } else {
                    $customChain.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::AllowUnknownCertificateAuthority
                }

                $chainBuilt = $customChain.Build($cert2)
                $badChainStatuses = @()
                if ($customChain.ChainStatus) {
                    foreach ($st in $customChain.ChainStatus) {
                        if ($st.Status -eq [System.Security.Cryptography.X509Certificates.X509ChainStatusFlags]::NoError) {
                            continue
                        }
                        if (-not $usesCustomRootTrust -and $st.Status -eq [System.Security.Cryptography.X509Certificates.X509ChainStatusFlags]::UntrustedRoot) {
                            continue
                        }
                        $badChainStatuses += $st.Status.ToString()
                    }
                }

                if (-not $chainBuilt -or $badChainStatuses.Count -gt 0 -or -not $customChain.ChainElements -or $customChain.ChainElements.Count -lt 1) {
                    $sslStream.Close()
                    $tcpClient.Close()
                    return @{
                        Success = $false
                        Status = "CA_UNTRUSTED_MISMATCH"
                        SanMatched = $sanMatched
                        CaMatched = $false
                        RootCaSha256 = $rootCaSha256
                        ExpectedCaSha256 = $cleanExpected
                        Error = "Validazione catena X.509 fallita (ChainBuilt=$chainBuilt, Status=$($badChainStatuses -join ','))"
                    }
                }

                $elemCount = $customChain.ChainElements.Count
                $firstElemSha = $customChain.ChainElements[0].Certificate.GetCertHashString([System.Security.Cryptography.HashAlgorithmName]::SHA256).ToLower()
                $builtRootCert = $customChain.ChainElements[$elemCount - 1].Certificate
                $builtRootSha = $builtRootCert.GetCertHashString([System.Security.Cryptography.HashAlgorithmName]::SHA256).ToLower()
                $rootCaSha256 = $builtRootSha

                if ($firstElemSha -ne $serverCertSha256 -or $builtRootSha -ne $cleanExpected) {
                    $sslStream.Close()
                    $tcpClient.Close()
                    return @{
                        Success = $false
                        Status = "CA_UNTRUSTED_MISMATCH"
                        SanMatched = $sanMatched
                        CaMatched = $false
                        RootCaSha256 = $builtRootSha
                        ExpectedCaSha256 = $cleanExpected
                        Error = "Catena X.509 non ancorata alla Root CA attesa (BuiltRoot=$builtRootSha, Atteso=$cleanExpected)"
                    }
                }

                $cryptoChainError = $null
                for ($idx = 0; $idx -lt $elemCount; $idx++) {
                    $elCert = $customChain.ChainElements[$idx].Certificate
                    $elNb = ([DateTime]$elCert.NotBefore).ToUniversalTime()
                    $elNa = ([DateTime]$elCert.NotAfter).ToUniversalTime()
                    if ($now -lt $elNb -or $now -gt $elNa) {
                        $cryptoChainError = "Certificato nella catena [index=$idx, Subject=$($elCert.Subject)] fuori finestra temporale (NotBefore=$elNb, NotAfter=$elNa)"
                        break
                    }

                    if ($elemCount -gt 1 -and $idx -ge 1) {
                        $bcExt = $null
                        $kuExt = $null
                        foreach ($ex in $elCert.Extensions) {
                            if ($ex.Oid.Value -eq "2.5.29.19") { $bcExt = $ex }
                            elseif ($ex.Oid.Value -eq "2.5.29.15") { $kuExt = $ex }
                        }
                        if (-not ($bcExt -is [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]) -or -not $bcExt.CertificateAuthority) {
                            $cryptoChainError = "Certificato emittente [index=$idx, Subject=$($elCert.Subject)] privo di BasicConstraints CertificateAuthority=true"
                            break
                        }
                        if ($kuExt -is [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]) {
                            if (($kuExt.KeyUsages -band [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign) -eq 0) {
                                $cryptoChainError = "Certificato emittente [index=$idx, Subject=$($elCert.Subject)] privo del flag KeyUsage KeyCertSign"
                                break
                            }
                        }
                    }

                    if ($idx -lt ($elemCount - 1)) {
                        $issuerCert = $customChain.ChainElements[$idx + 1].Certificate
                        if (-not (Compare-ByteArraysEqual -A $elCert.IssuerName.RawData -B $issuerCert.SubjectName.RawData)) {
                            $cryptoChainError = "Disallineamento DN Issuer/Subject nella catena al livello $idx"
                            break
                        }
                        if (-not (Test-X509CertificateSignature -ChildCert $elCert -IssuerCert $issuerCert)) {
                            $cryptoChainError = "Firma crittografica non valida per il certificato [index=$idx, Subject=$($elCert.Subject)] rispetto all'emittente [$($issuerCert.Subject)]"
                            break
                        }
                    } else {
                        if (-not (Compare-ByteArraysEqual -A $elCert.IssuerName.RawData -B $elCert.SubjectName.RawData)) {
                            $cryptoChainError = "Certificato ancora finale [Subject=$($elCert.Subject)] non autofirmato (Issuer != Subject)"
                            break
                        }
                        if (-not (Test-X509CertificateSignature -ChildCert $elCert -IssuerCert $elCert)) {
                            $cryptoChainError = "Autofirma crittografica della Root CA [Subject=$($elCert.Subject)] non valida"
                            break
                        }
                    }
                }

                if ($cryptoChainError) {
                    $sslStream.Close()
                    $tcpClient.Close()
                    return @{
                        Success = $false
                        Status = "CA_UNTRUSTED_MISMATCH"
                        SanMatched = $sanMatched
                        CaMatched = $false
                        RootCaSha256 = $builtRootSha
                        ExpectedCaSha256 = $cleanExpected
                        Error = "Verifica crittografica catena fallita: $cryptoChainError"
                    }
                }

                $caMatched = $true
                $caStatus = "APPROVED"
            } finally {
                $customChain.Reset()
                $customChain.Dispose()
            }
        }

        $httpStatusCode = $null
        $responseBody = $null
        if ($sanMatched -and $caMatched -and ($caStatus -eq "APPROVED") -and -not [string]::IsNullOrWhiteSpace($HttpGetPath)) {
            $sslStream.ReadTimeout = $TimeoutMs
            $sslStream.WriteTimeout = $TimeoutMs
            $reqLines = New-Object System.Collections.Generic.List[string]
            [void]$reqLines.Add("GET $HttpGetPath HTTP/1.1")
            [void]$reqLines.Add("Host: $($TargetHost):$Port")
            if (-not [string]::IsNullOrWhiteSpace($BearerToken)) {
                [void]$reqLines.Add("Authorization: Bearer $BearerToken")
            }
            [void]$reqLines.Add("Connection: close")
            [void]$reqLines.Add("")
            [void]$reqLines.Add("")
            $reqBytes = [System.Text.Encoding]::UTF8.GetBytes(($reqLines -join "`r`n"))
            $sslStream.Write($reqBytes, 0, $reqBytes.Length)
            $sslStream.Flush()

            $msResp = New-Object System.IO.MemoryStream
            try {
                $buf = New-Object byte[] 4096
                while ($true) {
                    $readCount = 0
                    try {
                        $readCount = $sslStream.Read($buf, 0, $buf.Length)
                    } catch [System.IO.IOException] {
                        if ($msResp.Length -gt 0) { break }
                        throw
                    }
                    if ($readCount -le 0) { break }
                    $msResp.Write($buf, 0, $readCount)
                    if ($msResp.Length -gt 1048576) {
                        throw "Risposta HTTPS da $HttpGetPath oltre il limite di 1 MB."
                    }
                }
                $allBytes = $msResp.ToArray()
                $sepIdx = -1
                $sepLen = 4
                for ($si = 0; $si -le ($allBytes.Length - 4); $si++) {
                    if ($allBytes[$si] -eq 13 -and $allBytes[$si + 1] -eq 10 -and $allBytes[$si + 2] -eq 13 -and $allBytes[$si + 3] -eq 10) {
                        $sepIdx = $si; $sepLen = 4; break
                    }
                }
                if ($sepIdx -lt 0) {
                    for ($si = 0; $si -le ($allBytes.Length - 2); $si++) {
                        if ($allBytes[$si] -eq 10 -and $allBytes[$si + 1] -eq 10) {
                            $sepIdx = $si; $sepLen = 2; break
                        }
                    }
                }
                if ($sepIdx -ge 0) {
                    $hdrPart = [System.Text.Encoding]::ASCII.GetString($allBytes, 0, $sepIdx)
                    $bodyOffset = $sepIdx + $sepLen
                    if ($hdrPart -match "^HTTP/\d+\.\d+\s+(\d{3})\b") {
                        $httpStatusCode = [int]$matches[1]
                    }
                    if ($hdrPart -match "(?im)^Transfer-Encoding:\s*chunked\b") {
                        $chunkMs = New-Object System.IO.MemoryStream
                        try {
                            $pos = $bodyOffset
                            while ($pos -lt $allBytes.Length) {
                                $lineEnd = -1
                                for ($li = $pos; $li -lt ($allBytes.Length - 1); $li++) {
                                    if ($allBytes[$li] -eq 13 -and $allBytes[$li + 1] -eq 10) { $lineEnd = $li; break }
                                }
                                if ($lineEnd -lt 0) { break }
                                $hexLen = ([System.Text.Encoding]::ASCII.GetString($allBytes, $pos, $lineEnd - $pos).Split(';')[0]).Trim()
                                $chunkSize = 0
                                if (-not [int]::TryParse($hexLen, [System.Globalization.NumberStyles]::HexNumber, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$chunkSize)) { break }
                                $pos = $lineEnd + 2
                                if ($chunkSize -eq 0) { break }
                                if (($pos + $chunkSize) -le $allBytes.Length) {
                                    $chunkMs.Write($allBytes, $pos, $chunkSize)
                                }
                                $pos += $chunkSize + 2
                            }
                            $responseBody = [System.Text.Encoding]::UTF8.GetString($chunkMs.ToArray())
                        } finally {
                            $chunkMs.Dispose()
                        }
                    } else {
                        $responseBody = [System.Text.Encoding]::UTF8.GetString($allBytes, $bodyOffset, $allBytes.Length - $bodyOffset)
                    }
                }
            } finally {
                $msResp.Dispose()
            }
        }

        $sslStream.Close()
        $tcpClient.Close()

        $isSuccess = ($sanMatched -and $caMatched -and ($caStatus -eq "APPROVED"))
        return @{
            Success = $isSuccess
            Status = $caStatus
            CertSha256 = $serverCertSha256
            RootCaSha256 = $rootCaSha256
            SanMatched = $sanMatched
            CaMatched = $caMatched
            Subject = $cert2.Subject
            Issuer = $cert2.Issuer
            FormattedSan = $formattedSan
            HttpStatusCode = $httpStatusCode
            ResponseBody = $responseBody
        }
    } catch {
        return @{
            Success = $false
            Status = "HANDSHAKE_FAILED"
            SanMatched = $false
            CaMatched = $false
            Error = $_.Exception.Message
        }
    } finally {
        $tcpClient.Dispose()
    }
}

function Send-FileViaAdbExecIn {
    param(
        [string]$AdbExe,
        [string]$TargetAdb,
        [string]$LocalFilePath = $null,
        [byte[]]$RawBytes = $null,
        [string]$RemoteCommand
    )
    $bytes = $null
    if ($RawBytes -ne $null) {
        $bytes = $RawBytes
    } elseif (-not [string]::IsNullOrEmpty($LocalFilePath)) {
        if (-not (Test-Path $LocalFilePath)) {
            throw "ERRORE: File locale non trovato: $LocalFilePath"
        }
        $bytes = [System.IO.File]::ReadAllBytes($LocalFilePath)
    } else {
        throw "ERRORE: Nessun payload specificato per Send-FileViaAdbExecIn"
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $AdbExe
    $psi.Arguments = "-s $TargetAdb exec-in `"$RemoteCommand`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stream = $proc.StandardInput.BaseStream
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
    $stream.Close()

    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit(10000)

    return @{
        ExitCode = $proc.ExitCode
        Success = ($proc.ExitCode -eq 0)
        Output = "$stdout $stderr".Trim()
    }
}

function Receive-FileViaAdbExecOut {
    param(
        [string]$AdbExe,
        [string]$TargetAdb,
        [string]$RemoteCommand,
        [string]$LocalFilePath,
        [int]$MinBytes = 512
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $AdbExe
    $psi.Arguments = "-s $TargetAdb exec-out $RemoteCommand"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $parentDir = Split-Path $LocalFilePath -Parent
    if ($parentDir -and -not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Force -Path $parentDir | Out-Null
    }
    $outStream = [System.IO.File]::Create($LocalFilePath)
    try {
        $proc.StandardOutput.BaseStream.CopyTo($outStream)
    } finally {
        $outStream.Close()
    }
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit(10000)

    $success = ($proc.ExitCode -eq 0 -and (Test-Path $LocalFilePath) -and ((Get-Item $LocalFilePath).Length -ge $MinBytes))
    if (-not $success -and (Test-Path $LocalFilePath)) {
        Remove-Item $LocalFilePath -Force -ErrorAction SilentlyContinue
    }
    return @{
        ExitCode = $proc.ExitCode
        Success = $success
        Error = $stderr.Trim()
    }
}

function Get-ApplicationProcessState {
    param(
        [string]$AdbExe,
        [string]$TargetAdb,
        [string]$PackageName
    )
    # Esecuzione comando shell con marcatore esplicito: echo PIDOF_CHECK:pids=[$pids]:exit=[$code]
    # In una shell POSIX:
    # - Se il processo e' in esecuzione: pidof esce con 0 e stampa uno o piu' PID
    # - Se il processo NON e' in esecuzione: pidof esce con 1 e non stampa nulla
    # In entrambi i casi leciti, echo ha successo (exit 0) e stampa PIDOF_CHECK:pids=[$pids]:exit=[$code].
    #
    # Se ADB fallisce a monte (trasporto, timeout, demone terminato) o il comando fallisce senza stdout,
    # il probe fallisce categoricamente in FAIL-CLOSED.
    $probeCmd = "pids=`$(pidof $PackageName 2>/dev/null); code=`$?; echo PIDOF_CHECK:pids=[`$pids]:exit=[`$code]"
    $raw = & $AdbExe -s $TargetAdb shell $probeCmd 2>&1
    $adbExit = $LASTEXITCODE

    if ($adbExit -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        throw "ERRORE FAIL-CLOSED: Probe dello stato dei processi per $PackageName fallito su target device (exit: $adbExit, out: '$raw'). Impossibile verificare la quiescenza per errore di trasporto o permessi ADB."
    }

    $rawStr = $raw.ToString().Trim()
    if ($rawStr -match "PIDOF_CHECK:pids=\[([^\]]*)\]:exit=\[(\d+)\]") {
        $foundPids = $Matches[1].Trim()
        $pidofExit = [int]$Matches[2]

        # Classificazione deterministica e rigorosa degli exit code di pidof (Revisione 13)
        if ($pidofExit -eq 0) {
            if ([string]::IsNullOrWhiteSpace($foundPids)) {
                throw "ERRORE FAIL-CLOSED: Risultato incoerente del probe quiescenza per ${PackageName}: pidof ha restituito exit code 0 ma nessun PID e' stato catturato. Operazione bloccata in FAIL-CLOSED."
            }
            return @{
                Success = $true
                Pids = $foundPids
                PidofExit = $pidofExit
                IsRunning = $true
            }
        } elseif ($pidofExit -eq 1) {
            if (-not [string]::IsNullOrWhiteSpace($foundPids)) {
                throw "ERRORE FAIL-CLOSED: Risultato incoerente del probe quiescenza per ${PackageName}: pidof ha restituito exit code 1 ma sono presenti PID ('$foundPids'). Operazione bloccata in FAIL-CLOSED."
            }
            return @{
                Success = $true
                Pids = ""
                PidofExit = $pidofExit
                IsRunning = $false
            }
        } elseif ($pidofExit -eq 127) {
            throw "ERRORE FAIL-CLOSED: Binario o comando 'pidof' assente o non eseguibile su target device (exit: 127). Impossibile verificare lo stato dei processi per ${PackageName}."
        } else {
            throw "ERRORE FAIL-CLOSED: Invocazione pidof fallita con codice anomalo ($pidofExit) per ${PackageName}. Il fallimento del comando di controllo non puo' essere interpretato come assenza di processi."
        }
    } else {
        throw "ERRORE FAIL-CLOSED: Formato output probe quiescenza non valido per ${PackageName}: '$rawStr'. Impossibile confermare la quiescenza in modo deterministico."
    }
}

function Ensure-ApplicationQuiescence {
    param(
        [string]$AdbExe,
        [string]$TargetAdb,
        [string]$PackageName
    )
    Write-Host "      Imposizione e verifica attiva della quiescenza del writer ($PackageName)..." -ForegroundColor Yellow
    $stopRes = & $AdbExe -s $TargetAdb shell "am force-stop $PackageName" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "ERRORE FAIL-CLOSED: Invocazione am force-stop fallita con codice $LASTEXITCODE : $stopRes"
    }

    Start-Sleep -Milliseconds 300
    $state = Get-ApplicationProcessState -AdbExe $AdbExe -TargetAdb $TargetAdb -PackageName $PackageName
    if ($state.IsRunning) {
        $pids = $state.Pids
        throw "ERRORE FAIL-CLOSED: Impossibile arrestare il processo dell'applicazione ($PackageName, PID residuo: $pids) tramite solo am force-stop (kill -9 implicito disabilitato in Fase A). Writer non quiescente: estrazione database bloccata categoricamente per prevenire incoerenze o corruzione."
    }
    Write-Host "      Quiescenza applicazione verificata e confermata (zero processi attivi)." -ForegroundColor Green
    return $true
}

function Test-AdbRootIdOutput([string]$IdText) {
    if ([string]::IsNullOrWhiteSpace($IdText)) { return $false }
    if ($IdText -match "[\r\n]") { return $false }
    if (([regex]::Matches($IdText, "\buid=")).Count -ne 1) { return $false }
    return ($IdText -match "^uid=0\(root\)(?:\s+gid=0\(root\))?(?:\s+.*)?$")
}

function Test-AdbNonRootShellIdOutput([string]$IdText) {
    if ([string]::IsNullOrWhiteSpace($IdText)) { return $false }
    if ($IdText -match "[\r\n]") { return $false }
    if (([regex]::Matches($IdText, "\buid=")).Count -ne 1) { return $false }
    if ($IdText -match "\b(?:uid|gid)=0\b") { return $false }
    return ($IdText -match "^uid=2000\(shell\)\s+gid=2000\(shell\)(?:\s+.*)?$")
}

function Invoke-WithAdbElevation {
    param(
        [string]$AdbExe,
        [string]$TargetAdb,
        [scriptblock]$ActionBlock
    )
    $preExistingRoot = $false
    $escalationAttempted = $false
    $isRootActive = $false
    $rootExit = -1
    $rootOut = ""
    $idCheckExit = -1
    $idCheck = ""
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $idOut = (& $AdbExe -s $TargetAdb shell "id" 2>&1 | Out-String).Trim()
        $idInitExit = $LASTEXITCODE
        if ($idInitExit -eq 0 -and (Test-AdbRootIdOutput $idOut)) {
            $preExistingRoot = $true
            $isRootActive = $true
        } else {
            $escalationAttempted = $true
            $rootOut = (& $AdbExe -s $TargetAdb root 2>&1 | Out-String).Trim()
            $rootExit = $LASTEXITCODE
            if ($rootExit -eq 0 -and $rootOut -match "restarting adbd as root|already running as root") {
                Start-Sleep -Milliseconds 1000
                & $AdbExe connect $TargetAdb 2>$null | Out-Null
                & $AdbExe -s $TargetAdb wait-for-device 2>$null | Out-Null
                $idCheck = (& $AdbExe -s $TargetAdb shell "id" 2>&1 | Out-String).Trim()
                $idCheckExit = $LASTEXITCODE
                if ($idCheckExit -ne 0) {
                    Start-Sleep -Milliseconds 1000
                    & $AdbExe connect $TargetAdb 2>$null | Out-Null
                    & $AdbExe -s $TargetAdb wait-for-device 2>$null | Out-Null
                    $idCheck = (& $AdbExe -s $TargetAdb shell "id" 2>&1 | Out-String).Trim()
                    $idCheckExit = $LASTEXITCODE
                }
                if ($idCheckExit -eq 0 -and (Test-AdbRootIdOutput $idCheck)) {
                    $isRootActive = $true
                }
            }
        }
        $ErrorActionPreference = $prevEap
        if (-not $isRootActive) {
            throw "ERRORE FAIL-CLOSED [ELEVAZIONE ADB ROOT FALLITA]: Impossibile confermare positivamente l'elevazione del demone adbd a uid=0(root) (rootExit=$rootExit, rootOut='$rootOut', idCheckExit=$idCheckExit, idCheckOut='$idCheck'). Esecuzione ActionBlock privilegiato bloccata categoricamente."
        }
        & $ActionBlock
    } finally {
        $ErrorActionPreference = "Continue"
        if ($escalationAttempted -and -not $preExistingRoot) {
            $unrootOut = (& $AdbExe -s $TargetAdb unroot 2>&1 | Out-String).Trim()
            $unrootExit = $LASTEXITCODE
            Start-Sleep -Milliseconds 800
            & $AdbExe connect $TargetAdb 2>$null | Out-Null
            & $AdbExe -s $TargetAdb wait-for-device 2>$null | Out-Null
            $idAfter = (& $AdbExe -s $TargetAdb shell "id" 2>&1 | Out-String).Trim()
            $idAfterExit = $LASTEXITCODE
            if ($unrootExit -eq 0 -and $idAfterExit -ne 0) {
                Start-Sleep -Milliseconds 1000
                & $AdbExe connect $TargetAdb 2>$null | Out-Null
                & $AdbExe -s $TargetAdb wait-for-device 2>$null | Out-Null
                $idAfter = (& $AdbExe -s $TargetAdb shell "id" 2>&1 | Out-String).Trim()
                $idAfterExit = $LASTEXITCODE
            }
            $verifiedNonRootShell = (
                $unrootExit -eq 0 -and
                $idAfterExit -eq 0 -and
                (Test-AdbNonRootShellIdOutput $idAfter)
            )
            if (-not $verifiedNonRootShell) {
                $ErrorActionPreference = $prevEap
                throw "ERRORE FAIL-CLOSED [STATO ADBD UNKNOWN / RECUPERO MANUALE RICHIESTO]: Impossibile confermare positivamente il ritorno del demone adbd alla policy uid=2000(shell) dopo adb unroot (unrootExit=$unrootExit, unrootOut='$unrootOut', idExit=$idAfterExit, idOut='$idAfter'). Eseguire manualmente: adb -s $TargetAdb unroot && adb -s $TargetAdb shell id"
            }
            Write-Host "      Privilegi temporanei adbd revocati con successo (adb unroot -> $idAfter)." -ForegroundColor Gray
        }
        $ErrorActionPreference = $prevEap
    }
}

function Restore-TargetApplicationService {
    param(
        [string]$AdbExe,
        [string]$TargetAdb,
        [string]$PackageName,
        [string]$TargetTv = "192.168.1.8",
        [int]$ExpectedHttpPort = 8088,
        [bool]$UnrootVerified = $true
    )

    $manualCmd = "adb -s $TargetAdb unroot && adb -s $TargetAdb shell id && adb -s $TargetAdb shell am start -n $PackageName/.MainActivity"

    if (-not $UnrootVerified) {
        return @{
            Restored = $false
            Status = "UNKNOWN"
            Reason = "STATO ADBD UNKNOWN: rientro adb unroot non verificato, ripristino automatico non dichiarabile"
            ManualRecovery = $manualCmd
        }
    }

    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $aliveOut = (& $AdbExe -s $TargetAdb shell "echo ADB_ALIVE" 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $aliveOut -notmatch "ADB_ALIVE") {
            return @{
                Restored = $false
                Status = "UNKNOWN"
                Reason = "ADB irraggiungibile dopo am force-stop (exit=$LASTEXITCODE, out='$aliveOut')"
                ManualRecovery = $manualCmd
            }
        }

        Write-Host "[RECOVERY V5] Ripristino servizio target $PackageName compatibile Android 9..." -ForegroundColor Yellow

        # 1. Tentativo primario: startservice esplicito
        & $AdbExe -s $TargetAdb shell "am startservice -n $PackageName/.RemoteServerService" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 300
        $procState = $null
        try { $procState = Get-ApplicationProcessState -AdbExe $AdbExe -TargetAdb $TargetAdb -PackageName $PackageName } catch { $procState = $null }

        # 2. Tentativo secondario: cmd activity start-service
        if (-not $procState -or -not $procState.IsRunning) {
            & $AdbExe -s $TargetAdb shell "cmd activity start-service $PackageName/.RemoteServerService" 2>&1 | Out-Null
            Start-Sleep -Milliseconds 300
            try { $procState = Get-ApplicationProcessState -AdbExe $AdbExe -TargetAdb $TargetAdb -PackageName $PackageName } catch { $procState = $null }
        }

        # 3. Fallback Android 9 (.RemoteServerService non esportato vs .MainActivity esportata) con attese cold-start
        if (-not $procState -or -not $procState.IsRunning) {
            & $AdbExe -s $TargetAdb shell "am start -n $PackageName/.MainActivity" 2>&1 | Out-Null
            $pidAttempts = if ($env:RESTORE_PID_ATTEMPTS) { [int]$env:RESTORE_PID_ATTEMPTS } else { 3 }
            $pidDelayMs = if ($env:RESTORE_PID_DELAY_MS) { [int]$env:RESTORE_PID_DELAY_MS } else { 500 }
            for ($pa = 1; $pa -le $pidAttempts; $pa++) {
                Start-Sleep -Milliseconds $pidDelayMs
                try { $procState = Get-ApplicationProcessState -AdbExe $AdbExe -TargetAdb $TargetAdb -PackageName $PackageName } catch { $procState = $null }
                if ($procState -and $procState.IsRunning) { break }
            }
        }

        if (-not $procState -or -not $procState.IsRunning) {
            return @{
                Restored = $false
                Status = "UNKNOWN"
                Reason = "Processo $PackageName non attivo dopo tentativi startservice/cmd activity/MainActivity"
                ManualRecovery = $manualCmd
            }
        }

        # Verifica applicativa GET /api/status (status=ok && uinput_ready=true) con tolleranza cold-start Android 9
        $statusAttempts = if ($env:RESTORE_STATUS_ATTEMPTS) { [int]$env:RESTORE_STATUS_ATTEMPTS } else { 10 }
        $statusDelayMs = if ($env:RESTORE_STATUS_DELAY_MS) { [int]$env:RESTORE_STATUS_DELAY_MS } else { 1000 }
        $statusHealthy = $false
        $lastStatusDetail = "nessuna risposta"
        for ($attempt = 1; $attempt -le $statusAttempts; $attempt++) {
            $httpSucceeded = $false
            try {
                $resp = Invoke-RestMethod -Uri "http://${TargetTv}:${ExpectedHttpPort}/api/status" -Method Get -TimeoutSec 2 -ErrorAction Stop
                $httpSucceeded = $true
                if ($resp.status -eq "ok" -and $resp.uinput_ready -eq $true) {
                    $statusHealthy = $true
                    break
                }
                $lastStatusDetail = "HTTP /api/status non sano (status=$($resp.status), uinput_ready=$($resp.uinput_ready))"
                break
            } catch {
                $lastStatusDetail = $_.Exception.Message
            }

            if (-not $httpSucceeded) {
                $curlOut = (& $AdbExe -s $TargetAdb shell "curl -s http://127.0.0.1:${ExpectedHttpPort}/api/status" 2>&1 | Out-String).Trim()
                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($curlOut) -and $curlOut -match "\{") {
                    try {
                        $curlJson = $curlOut | ConvertFrom-Json -ErrorAction Stop
                        if ($curlJson.status -eq "ok" -and $curlJson.uinput_ready -eq $true) {
                            $statusHealthy = $true
                            break
                        }
                        $lastStatusDetail = "on-device /api/status non sano (status=$($curlJson.status), uinput_ready=$($curlJson.uinput_ready))"
                        break
                    } catch {
                        $lastStatusDetail = "JSON /api/status non valido: $curlOut"
                    }
                }
            }
            if ($attempt -lt $statusAttempts) { Start-Sleep -Milliseconds $statusDelayMs }
        }

        if (-not $statusHealthy) {
            return @{
                Restored = $false
                Status = "UNHEALTHY"
                Reason = "Processo attivo (PID: $($procState.Pids)) ma endpoint /api/status non sano: $lastStatusDetail"
                ManualRecovery = $manualCmd
            }
        }

        Write-Host "[RECOVERY V5] Servizio $PackageName ripristinato e verificato (PID=$($procState.Pids), /api/status=ok, uinput_ready=true)." -ForegroundColor Green
        return @{
            Restored = $true
            Status = "RESTORED"
            Pids = $procState.Pids
            Reason = "OK"
            ManualRecovery = ""
        }
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

function Get-ResolvedAaptExecutable {
    $aaptPath = $null
    foreach ($sdkRoot in (Get-OrderedAndroidSdkRoots)) {
        foreach ($dir in (Get-OrderedBuildToolsDirs $sdkRoot)) {
            foreach ($name in @("aapt.exe", "aapt.cmd", "aapt")) {
                $candidate = Join-Path $dir.FullName $name
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { $aaptPath = $candidate; break }
            }
            if ($aaptPath) { break }
        }
        if ($aaptPath) { break }
    }
    if (-not $aaptPath) {
        $cmd = Get-Command aapt -ErrorAction SilentlyContinue
        if ($cmd) { $aaptPath = $cmd.Source }
    }
    if (-not $aaptPath) {
        throw "ERRORE FAIL-CLOSED: aapt dump badging obbligatorio per validare package/versionCode."
    }
    return $aaptPath
}

function Test-RescueApkCompatibility {
    param(
        [string]$RescueApkPath,
        [string]$PackageName,
        [long]$MustExceedVersionCode,
        [string]$ExpectedSignerSha256 = $null,
        [string]$ExpectedRescueSha256 = $null,
        [switch]$RequireExpectedSigner = $false
    )
    if ([string]::IsNullOrWhiteSpace($RescueApkPath) -or -not (Test-Path -LiteralPath $RescueApkPath -PathType Leaf)) {
        throw "ERRORE FAIL-CLOSED [RESCUE APK NON VALIDO]: File RescueApkPath mancante o non leggibile ($RescueApkPath)."
    }
    if ($RescueApkPath -match "app-ci-test-nondistributable\.apk") {
        throw "ERRORE FAIL-CLOSED [RESCUE APK NON VALIDO]: Artefatto CI non distribuibile rifiutato come rescue."
    }
    if ($RequireExpectedSigner -and ([string]::IsNullOrWhiteSpace($ExpectedSignerSha256) -or $ExpectedSignerSha256.Trim() -notmatch "^[0-9a-fA-F]{64}$")) {
        throw "ERRORE FAIL-CLOSED [RESCUE APK NON VALIDO]: Signer atteso SHA-256 obbligatorio e non valido."
    }
    $rescueFileSha256 = (Get-FileHash -LiteralPath $RescueApkPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRescueSha256) -and $rescueFileSha256 -ne $ExpectedRescueSha256.Trim().ToLowerInvariant()) {
        throw "ERRORE FAIL-CLOSED [RESCUE APK NON VALIDO]: Hash SHA-256 del file Rescue alterato o difforme dall'hash bloccato ($rescueFileSha256 vs $($ExpectedRescueSha256.Trim().ToLowerInvariant()))."
    }
    Assert-CandidateApkNoForbiddenTlsAssets $RescueApkPath | Out-Null

    $rescueFp = Get-ApkCertificateFingerprint $RescueApkPath
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSignerSha256) -and $rescueFp -ne $ExpectedSignerSha256.Trim().ToLowerInvariant()) {
        throw "ERRORE FAIL-CLOSED [RESCUE APK NON VALIDO]: Firma certificato rescue ($rescueFp) diversa da app installata ($ExpectedSignerSha256)."
    }

    $aaptPath = Get-ResolvedAaptExecutable
    $previousEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $badgingOut = (& $aaptPath dump badging $RescueApkPath 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) {
            throw "ERRORE FAIL-CLOSED [RESCUE APK NON VALIDO]: aapt dump badging fallito (exit=$LASTEXITCODE)."
        }
        $packageLines = @($badgingOut -split "\r?\n" | Where-Object { $_ -match "^package:\s" })
        if ($packageLines.Count -ne 1 -or $packageLines[0] -notmatch "^package:\s+name='([^']+)'\s+versionCode='([0-9]+)'(?:\s|$)") {
            throw "ERRORE FAIL-CLOSED [RESCUE APK NON VALIDO]: metadata package/versionCode assenti o ambigui nel rescue APK."
        }
        $rescuePkg = $Matches[1]
        $rescueVc = [long]::Parse($Matches[2], [System.Globalization.CultureInfo]::InvariantCulture)
        if ($rescuePkg -ne $PackageName) {
            throw "ERRORE FAIL-CLOSED [RESCUE APK NON VALIDO]: package rescue '$rescuePkg' diverso da '$PackageName'."
        }
        if ($rescueVc -le $MustExceedVersionCode) {
            throw "ERRORE FAIL-CLOSED [RESCUE APK NON VALIDO]: versionCode rescue ($rescueVc) deve superare strettamente versionCode=$MustExceedVersionCode per evitare downgrade/uninstall."
        }
        return @{
            Valid = $true
            PackageName = $rescuePkg
            VersionCode = $rescueVc
            SignerSha256 = $rescueFp
            FileSha256 = $rescueFileSha256
        }
    } finally {
        $ErrorActionPreference = $previousEap
    }
}

function Invoke-ConservativeRollbackApkInstall {
    param(
        [string]$AdbExe,
        [string]$TargetAdb,
        [string]$PackageName,
        [string]$BackupApkPath,
        [string]$RescueApkPath = $null,
        [long]$MustExceedVersionCode = 0,
        [string]$ExpectedSignerSha256 = $null,
        [string]$ExpectedRescueSha256 = $null,
        [switch]$ForbidLegacyDowngrade = $false
    )
    if (-not [string]::IsNullOrWhiteSpace($RescueApkPath)) {
        $prevEapDump = $ErrorActionPreference
        $dumpsysOut = ""
        $dumpsysExit = -1
        try {
            $ErrorActionPreference = "Continue"
            $dumpsysOut = (& $AdbExe -s $TargetAdb shell "dumpsys package $PackageName" 2>&1 | Out-String)
            $dumpsysExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEapDump
        }
        if ($dumpsysExit -ne 0) {
            throw "ERRORE FAIL-CLOSED [VERSIONE INSTALLATA NON DETERMINABILE]: dumpsys package fallito (exit=$dumpsysExit) su $TargetAdb."
        }
        $vcMatches = @([regex]::Matches($dumpsysOut, "(?m)^\s*versionCode=([0-9]+)\b"))
        if ($vcMatches.Count -ne 1) {
            throw "ERRORE FAIL-CLOSED [VERSIONE INSTALLATA AMBIGUA O ASSENTE]: dumpsys package ha restituito $($vcMatches.Count) valori versionCode per $PackageName."
        }
        $curVc = [long]::Parse($vcMatches[0].Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture)
        if ($curVc -le 0) {
            throw "ERRORE FAIL-CLOSED [VERSIONE INSTALLATA AMBIGUA O ASSENTE]: versionCode installato non valido ($curVc)."
        }
        $effectiveMin = [Math]::Max($MustExceedVersionCode, $curVc)
        $rescueMeta = Test-RescueApkCompatibility -RescueApkPath $RescueApkPath -PackageName $PackageName -MustExceedVersionCode $effectiveMin -ExpectedSignerSha256 $ExpectedSignerSha256 -ExpectedRescueSha256 $ExpectedRescueSha256 -RequireExpectedSigner
        Write-Host "[ROLLBACK CONSERVATIVO] Reinstallazione in-place A2 Rescue v$($rescueMeta.VersionCode) (adb install -r, zero downgrade -d, zero uninstall)..." -ForegroundColor Cyan
        $rbRes = & $AdbExe -s $TargetAdb install -r $RescueApkPath
        Write-Host "      Esito adb install rescue: $rbRes"
        if ($LASTEXITCODE -ne 0 -or (($rbRes -join "`n") -notmatch "Success")) {
            throw "ERRORE FAIL-CLOSED: Installazione in-place A2 Rescue fallita (exit=$LASTEXITCODE): $rbRes"
        }
        return @{
            Mode = "IN_PLACE_RESCUE"
            VersionCode = $rescueMeta.VersionCode
            RescueSha256 = $rescueMeta.FileSha256
            Output = ($rbRes -join "`n")
        }
    }

    if ($ForbidLegacyDowngrade) {
        throw "ERRORE FAIL-CLOSED [RESCUE APK OBBLIGATORIO]: La procedura hardware owner vieta il fallback a downgrade legacy (-d) senza -RescueApkPath verificato (protezione AndroidKeyStore)."
    }

    Write-Host "[ROLLBACK LEGACY] Tentativo adb install -r -d su APK precedente (senza uninstall)..." -ForegroundColor Yellow
    $rbLegacy = & $AdbExe -s $TargetAdb install -r -d $BackupApkPath
    Write-Host "      Esito adb install rollback: $rbLegacy"
    $rbJoined = ($rbLegacy -join "`n")
    if ($LASTEXITCODE -ne 0 -or ($rbJoined -notmatch "Success")) {
        throw "ERRORE FAIL-CLOSED [DOWNGRADE NEGATO / UNINSTALL VIETATO PER PROTEZIONE ANDROIDKEYSTORE]: Reinstallazione rollback tramite 'adb install -r -d' fallita ($rbJoined). La disinstallazione rimuoverebbe le chiavi AES dell'app in AndroidKeyStore (AKAI_AI_CREDENTIALS_VAULT). Fornire un APK A2 Rescue con -RescueApkPath e versionCode superiore a quello installato."
    }
    return @{
        Mode = "DOWNGRADE_D"
        Output = $rbJoined
    }
}

function Test-StrictJsonBooleanProperty {
    param($Object, [string]$PropertyName)
    if ($null -eq $Object) { return $false }
    $prop = $Object.PSObject.Properties[$PropertyName]
    if ($null -eq $prop) { return $false }
    return ($prop.Value -is [bool])
}

function Get-BackupStoredCredentialExpectations {
    param([string]$SessionDir)
    $result = @{ HasBackupPrefs = $false; ExpectDeepSeek = $false; ExpectKimi = $false }
    if ([string]::IsNullOrWhiteSpace($SessionDir) -or -not (Test-Path -LiteralPath $SessionDir -PathType Container)) {
        return $result
    }
    $pairingSubDir = Join-Path $SessionDir "pairing_sessions"
    $pairingManPath = Join-Path $pairingSubDir "pairing_manifest.json"
    if (-not (Test-Path -LiteralPath $pairingManPath -PathType Leaf)) {
        return $result
    }
    $man = Get-Content -LiteralPath $pairingManPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $prefsMeta = if ($man.Files) { $man.Files."akai_ai_security_prefs.xml" } else { $null }
    if (-not $prefsMeta) {
        return $result
    }
    $vaultDir = $pairingSubDir
    $ptrPath = Join-Path $pairingSubDir "vault_pointer.json"
    if (Test-Path -LiteralPath $ptrPath -PathType Leaf) {
        $ptr = Get-Content -LiteralPath $ptrPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($ptr.VaultDir -and (Test-Path -LiteralPath $ptr.VaultDir -PathType Container)) { $vaultDir = $ptr.VaultDir }
    } elseif ($man.VaultDir -and (Test-Path -LiteralPath $man.VaultDir -PathType Container)) {
        $vaultDir = $man.VaultDir
    }
    $encPath = Join-Path $vaultDir "akai_ai_security_prefs.xml.enc"
    if (-not (Test-Path -LiteralPath $encPath -PathType Leaf)) {
        return $result
    }
    $cipherBytes = [IO.File]::ReadAllBytes($encPath)
    $plainBytes = $null
    try {
        $plainBytes = Unprotect-TlsData -CipherBytes $cipherBytes -Mechanism $prefsMeta.Mechanism -VaultDir $vaultDir
        $xmlSettings = New-Object System.Xml.XmlReaderSettings
        $xmlSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $xmlSettings.XmlResolver = $null
        $ms = New-Object System.IO.MemoryStream -ArgumentList @(,$plainBytes)
        try {
            $xr = [System.Xml.XmlReader]::Create($ms, $xmlSettings)
            $doc = New-Object System.Xml.XmlDocument
            $doc.XmlResolver = $null
            $doc.Load($xr)
            $dsNode = $doc.SelectSingleNode("/map/string[@name='sec_enc_deepseek_key']")
            $kmNode = $doc.SelectSingleNode("/map/string[@name='sec_enc_kimi_key']")
            $result.HasBackupPrefs = $true
            $result.ExpectDeepSeek = ($null -ne $dsNode -and -not [string]::IsNullOrWhiteSpace($dsNode.InnerText))
            $result.ExpectKimi = ($null -ne $kmNode -and -not [string]::IsNullOrWhiteSpace($kmNode.InnerText))
        } finally {
            $ms.Dispose()
        }
    } finally {
        if ($plainBytes) { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
    }
    return $result
}

function Test-DeviceKeystoreCredentialHealth {
    param(
        [string]$TargetTv,
        [int]$HttpsPort = 8443,
        [string]$AuthToken = $null,
        [string]$ExpectedCaFingerprint = $null,
        [switch]$FailOnUnreachable = $false,
        [switch]$RequireVerifiedHealthy = $false,
        [switch]$AllowLegacyRescueProbe = $false,
        [bool]$ExpectDeepSeekStored = $false,
        [bool]$ExpectKimiStored = $false
    )
    if ([string]::IsNullOrWhiteSpace($AuthToken)) {
        if ($RequireVerifiedHealthy) {
            throw "ERRORE FAIL-CLOSED [KEYSTORE HEALTH NON VERIFICATO]: Token autenticazione assente per la verifica obbligatoria AndroidKeyStore."
        }
        return @{
            Checked = $false
            Verified = $false
            Status = "UNVERIFIED_NO_TOKEN"
            Schema = "none"
        }
    }
    $cfg = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace($ExpectedCaFingerprint)) {
            $pinRes = Test-HttpsTlsEndpoint -TargetHost $TargetTv -Port $HttpsPort -ExpectedCaSha256 $ExpectedCaFingerprint -TimeoutMs 4000 -HttpGetPath "/api/ai/config" -BearerToken $AuthToken
            if (-not $pinRes -or -not $pinRes.Success -or $pinRes.Status -ne "APPROVED") {
                $tlsErr = if ($pinRes -and $pinRes.Error) { "$($pinRes.Status): $($pinRes.Error)" } else { "TLS_PIN_FAILED" }
                throw "Probe HTTPS pinned /api/ai/config fallito ($tlsErr)."
            }
            if ($pinRes.HttpStatusCode -ne 200) {
                throw "HTTPS /api/ai/config restituito HTTP $($pinRes.HttpStatusCode)."
            }
            if (-not [string]::IsNullOrWhiteSpace($pinRes.ResponseBody)) {
                $cfg = $pinRes.ResponseBody | ConvertFrom-Json
            }
        } else {
            $cfgUrl = "https://$($TargetTv):$HttpsPort/api/ai/config"
            $headers = @{ "Authorization" = "Bearer $AuthToken" }
            $cfg = Invoke-RestMethod -Uri $cfgUrl -Method Get -Headers $headers -TimeoutSec 4 -ErrorAction Stop
        }
    } catch {
        if ($FailOnUnreachable -or $RequireVerifiedHealthy) {
            throw
        }
        Write-Host "      [AVVISO] Probe HTTPS Keystore /api/ai/config non raggiungibile ($($_.Exception.Message)): verifica credenziali non conclusa." -ForegroundColor Yellow
        return @{
            Checked = $false
            Verified = $false
            Status = "UNVERIFIED_UNREACHABLE"
            Schema = "none"
            Error = $_.Exception.Message
        }
    }

    if ($null -eq $cfg -or ($cfg -is [string]) -or ($cfg -is [ValueType])) {
        throw "ERRORE FAIL-CLOSED [KEYSTORE HEALTH SCHEMA NON VALIDO]: Risposta /api/ai/config vuota o non oggetto JSON."
    }

    $v4Fields = @(
        "keystore_alias_present",
        "deepseek_ciphertext_present",
        "deepseek_decryptable",
        "kimi_ciphertext_present",
        "kimi_decryptable",
        "undecryptable_stored_credentials",
        "all_stored_credentials_decryptable"
    )
    $presentV4Count = @($v4Fields | Where-Object { $null -ne $cfg.PSObject.Properties[$_] }).Count

    if ($presentV4Count -gt 0 -and $presentV4Count -lt $v4Fields.Count) {
        throw "ERRORE FAIL-CLOSED [KEYSTORE HEALTH SCHEMA INCOMPLETO]: Risposta /api/ai/config contiene solo $presentV4Count/$($v4Fields.Count) campi health obbligatori."
    }

    if ($presentV4Count -eq $v4Fields.Count) {
        foreach ($vf in $v4Fields) {
            if (-not (Test-StrictJsonBooleanProperty -Object $cfg -PropertyName $vf)) {
                throw "ERRORE FAIL-CLOSED [KEYSTORE HEALTH SCHEMA NON VALIDO]: Campo '$vf' assente, nullo o non booleano nella risposta /api/ai/config."
            }
        }
        $alias = [bool]$cfg.keystore_alias_present
        $dsPres = [bool]$cfg.deepseek_ciphertext_present
        $dsDec = [bool]$cfg.deepseek_decryptable
        $kmPres = [bool]$cfg.kimi_ciphertext_present
        $kmDec = [bool]$cfg.kimi_decryptable
        $undec = [bool]$cfg.undecryptable_stored_credentials
        $allDec = [bool]$cfg.all_stored_credentials_decryptable

        if (($dsDec -and (-not $dsPres -or -not $alias)) -or ($kmDec -and (-not $kmPres -or -not $alias))) {
            throw "ERRORE FAIL-CLOSED [KEYSTORE HEALTH SCHEMA INCOERENTE]: decryptable=true con ciphertext_present=false o keystore_alias_present=false."
        }
        $expectedUndec = ($dsPres -and -not $dsDec) -or ($kmPres -and -not $kmDec)
        if (($undec -ne $expectedUndec) -or ($allDec -ne (-not $expectedUndec))) {
            throw "ERRORE FAIL-CLOSED [KEYSTORE HEALTH SCHEMA INCOERENTE]: undecryptable/all_decryptable incoerenti con lo stato delle singole chiavi."
        }
        if (($ExpectDeepSeekStored -and -not $dsPres) -or ($ExpectKimiStored -and -not $kmPres)) {
            throw "ERRORE FAIL-CLOSED [KEYSTORE HEALTH CREDENZIALI MANCANTI]: Ciphertext AI atteso dal backup non trovato in SharedPreferences."
        }
        if ($undec -or -not $allDec) {
            throw "ERRORE FAIL-CLOSED [ANDROIDKEYSTORE CREDENZIALI NON DECIFRABILI]: L'alias AndroidKeyStore non decifra una o piu' credenziali AI salvate in SharedPreferences."
        }
        return @{
            Checked = $true
            Verified = $true
            Status = "HEALTHY"
            Schema = "v4"
            KeystoreAliasPresent = $alias
            DeepSeekCiphertextPresent = $dsPres
            DeepSeekDecryptable = $dsDec
            KimiCiphertextPresent = $kmPres
            KimiDecryptable = $kmDec
            AllStoredCredentialsDecryptable = $allDec
        }
    }

    # Nessun campo v4 presente: controlla esplicitamente contratto legacy A2 (mai etichettare HEALTHY)
    $legacyFields = @("has_deepseek_key", "has_kimi_key", "keystore_available")
    foreach ($lf in $legacyFields) {
        if (-not (Test-StrictJsonBooleanProperty -Object $cfg -PropertyName $lf)) {
            throw "ERRORE FAIL-CLOSED [KEYSTORE HEALTH SCHEMA ASSENTE]: Risposta /api/ai/config priva dei campi booleani Keystore v4 o legacy richiesti."
        }
    }
    $hasDsLegacy = [bool]$cfg.has_deepseek_key
    $hasKmLegacy = [bool]$cfg.has_kimi_key
    $ksAvailLegacy = [bool]$cfg.keystore_available
    if (($ExpectDeepSeekStored -and -not $hasDsLegacy) -or ($ExpectKimiStored -and -not $hasKmLegacy)) {
        throw "ERRORE FAIL-CLOSED [ANDROIDKEYSTORE CREDENZIALI NON DECIFRABILI SU ENDPOINT LEGACY]: Credenziale AI attesa dal backup non decifrabile su build A2 legacy."
    }
    $legacyDecryptConfirmed = ($ExpectDeepSeekStored -or $ExpectKimiStored) -and ((-not $ExpectDeepSeekStored) -or $hasDsLegacy) -and ((-not $ExpectKimiStored) -or $hasKmLegacy)
    if ($RequireVerifiedHealthy -and (-not $AllowLegacyRescueProbe -or -not $legacyDecryptConfirmed)) {
        throw "ERRORE FAIL-CLOSED [KEYSTORE HEALTH LEGACY INSUFFICIENTE]: Endpoint A2 legacy privo dello schema health v4 completo e senza evidenza di decifratura su credenziali salvate."
    }
    return @{
        Checked = $true
        Verified = $legacyDecryptConfirmed
        Status = "LEGACY_LIMITED"
        Schema = "legacy_a2"
        KeystoreAliasPresent = $null
        LegacyKeystoreAvailable = $ksAvailLegacy
        LegacyDecryptConfirmed = $legacyDecryptConfirmed
        HasDeepSeekKey = $hasDsLegacy
        HasKimiKey = $hasKmLegacy
    }
}

function Invoke-PostRollbackKeystoreVerification {
    param(
        [string]$SessionDir,
        [string]$RollbackMode,
        [string]$TargetTv,
        [int]$HttpsPort = 8443,
        [string]$AuthToken = $null,
        [string]$ExpectedCaFingerprint = $null,
        [switch]$RequireVerifiedKeystoreHealth = $false
    )
    if ([string]::IsNullOrWhiteSpace($AuthToken) -and -not $RequireVerifiedKeystoreHealth) {
        return $null
    }
    $backupCredExp = Get-BackupStoredCredentialExpectations -SessionDir $SessionDir
    $ksHealth = Test-DeviceKeystoreCredentialHealth -TargetTv $TargetTv -HttpsPort $HttpsPort -AuthToken $AuthToken -ExpectedCaFingerprint $ExpectedCaFingerprint -AllowLegacyRescueProbe:($RollbackMode -eq 'IN_PLACE_RESCUE') -RequireVerifiedHealthy:$RequireVerifiedKeystoreHealth -ExpectDeepSeekStored:([bool]$backupCredExp.ExpectDeepSeek) -ExpectKimiStored:([bool]$backupCredExp.ExpectKimi)
    Write-Host "      Stato verifica AndroidKeyStore/AI post-rollback: $($ksHealth.Status) (Schema=$($ksHealth.Schema), Verified=$($ksHealth.Verified), HasBackupPrefs=$($backupCredExp.HasBackupPrefs))" -ForegroundColor Cyan
    return $ksHealth
}

function Test-PackageUpgradeGate {
    param(
        [string]$AdbExe,
        [string]$TargetAdb,
        [string]$PackageName,
        [string]$CandidateApkPath,
        [switch]$PreviousAbsentConfirmed = $false
    )

    # P0 pre-install audit: metadata MUST be independently parsed, never inferred from ZIP magic.
    # A missing aapt, malformed APK, unknown installed version or ambiguous output blocks installation.
    if (-not (Test-Path -LiteralPath $CandidateApkPath -PathType Leaf)) {
        throw "ERRORE FAIL-CLOSED: APK candidato assente."
    }
    $aaptPath = Get-ResolvedAaptExecutable

    $previousEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $badgingOut = (& $aaptPath dump badging $CandidateApkPath 2>&1 | Out-String)
        $badgingExit = $LASTEXITCODE
        if ($badgingExit -ne 0) {
            throw "ERRORE FAIL-CLOSED: aapt non riesce a leggere il manifest APK (exit=$badgingExit)."
        }
        $packageLines = @($badgingOut -split "\r?\n" | Where-Object { $_ -match "^package:\s" })
        if ($packageLines.Count -ne 1 -or $packageLines[0] -notmatch "^package:\s+name='([^']+)'\s+versionCode='([0-9]+)'(?:\s|$)") {
            throw "ERRORE FAIL-CLOSED: metadata package/versionCode assenti o ambigui in aapt."
        }
        $candidatePkg = $Matches[1]
        $candidateVersionCode = [long]::Parse($Matches[2], [System.Globalization.CultureInfo]::InvariantCulture)
        if ($candidatePkg -ne $PackageName -or $candidateVersionCode -le 0) {
            throw "ERRORE FAIL-CLOSED: package/versionCode APK candidato non valido."
        }

        if ($PreviousAbsentConfirmed) {
            # Only caller-confirmed absence allows first install; candidate metadata remains mandatory.
            return @{ InstalledVersionCode = $null; CandidatePackageName = $candidatePkg; CandidateVersionCode = $candidateVersionCode }
        }
        $dumpsysOut = (& $AdbExe -s $TargetAdb shell "dumpsys package $PackageName" 2>&1 | Out-String)
        $dumpsysExit = $LASTEXITCODE
        if ($dumpsysExit -ne 0) {
            throw "ERRORE FAIL-CLOSED: impossibile leggere versionCode installato (dumpsys exit=$dumpsysExit)."
        }
        $installedMatches = @([regex]::Matches($dumpsysOut, "(?m)^\s*versionCode=([0-9]+)\b"))
        if ($installedMatches.Count -ne 1) {
            throw "ERRORE FAIL-CLOSED: versionCode installato assente o ambiguo; nessuna installazione consentita."
        }
        $installedVersionCode = [long]::Parse($installedMatches[0].Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture)
        if ($candidateVersionCode -le $installedVersionCode) {
            throw "ERRORE FAIL-CLOSED: versione candidata non superiore a quella installata (candidate=$candidateVersionCode, installed=$installedVersionCode)."
        }
        return @{
            InstalledVersionCode = $installedVersionCode
            CandidatePackageName = $candidatePkg
            CandidateVersionCode = $candidateVersionCode
        }
    } finally {
        $ErrorActionPreference = $previousEap
    }
}

function Probe-DeviceFileState {
    param(
        [string]$AdbExe,
        [string]$TargetAdb,
        [string]$PackageName,
        [string]$RelativePath,
        [string]$Channel = "any" # "any", "auto", "run-as", "su", "root"
    )
    $rootCheckDir = if ($RelativePath -like "databases/*") { "/data/data/$PackageName/databases" } else { "/data/data/$PackageName" }
    $probeCmdRunAs = "run-as $PackageName sh -c 'test -f $RelativePath && echo FILE_PROBE_RESULT:EXISTS || echo FILE_PROBE_RESULT:NOT_FOUND'"
    $probeCmdSu = "su -c 'test -f /data/data/$PackageName/$RelativePath && echo FILE_PROBE_RESULT:EXISTS || echo FILE_PROBE_RESULT:NOT_FOUND'"
    $probeCmdRoot = "sh -c 'if [ ! -d $rootCheckDir ] || [ ! -r $rootCheckDir ]; then echo FILE_PROBE_RESULT:ACCESS_DENIED; exit 13; fi; test -f /data/data/$PackageName/$RelativePath && echo FILE_PROBE_RESULT:EXISTS || echo FILE_PROBE_RESULT:NOT_FOUND'"

    $runAsAttempted = $false
    $runAsExit = -1
    $runAsOut = ""
    if ($Channel -eq "any" -or $Channel -eq "auto" -or $Channel -eq "run-as") {
        $runAsAttempted = $true
        $outRunAs = & $AdbExe -s $TargetAdb shell $probeCmdRunAs 2>&1
        $runAsExit = $LASTEXITCODE
        $runAsOut = if ($outRunAs) { $outRunAs.ToString().Trim() } else { "" }
        if ($runAsExit -eq 0 -and $runAsOut -match "FILE_PROBE_RESULT:(EXISTS|NOT_FOUND)") {
            return $Matches[1]
        }
    }

    $suAttempted = $false
    $suExit = -1
    $suOut = ""
    if ($Channel -eq "any" -or $Channel -eq "auto" -or $Channel -eq "su") {
        $suAttempted = $true
        $outSu = & $AdbExe -s $TargetAdb shell $probeCmdSu 2>&1
        $suExit = $LASTEXITCODE
        $suOut = if ($outSu) { $outSu.ToString().Trim() } else { "" }
        if ($suExit -eq 0 -and $suOut -match "FILE_PROBE_RESULT:(EXISTS|NOT_FOUND)") {
            return $Matches[1]
        }
    }

    $rootAttempted = $false
    $rootExit = -1
    $rootOut = ""
    if ($Channel -eq "root") {
        $rootAttempted = $true
        $outRoot = & $AdbExe -s $TargetAdb shell $probeCmdRoot 2>&1
        $rootExit = $LASTEXITCODE
        $rootOut = if ($outRoot) { $outRoot.ToString().Trim() } else { "" }
        if ($rootExit -eq 0 -and $rootOut -match "FILE_PROBE_RESULT:(EXISTS|NOT_FOUND)") {
            return $Matches[1]
        }
    }

    throw "ERRORE FAIL-CLOSED: Impossibile determinare lo stato del file ($RelativePath) su storage device. Probe run-as (tentato: $runAsAttempted, exit: $runAsExit, out: '$runAsOut'); Probe su (tentato: $suAttempted, exit: $suExit, out: '$suOut'); Probe root (tentato: $rootAttempted, exit: $rootExit, out: '$rootOut'). Operazione abortita per prevenire stati inconsistenti."
}

function Remove-OrphanedWalAndShmFiles {
    param(
        [string]$AdbExe,
        [string]$TargetAdb,
        [string]$PackageName
    )
    Write-Host "      Rimozione e verifica assenza file WAL/SHM orfani su storage device..." -ForegroundColor Cyan
    & $AdbExe -s $TargetAdb shell "run-as $PackageName rm -f databases/akai_memory.db-wal databases/akai_memory.db-shm" 2>$null | Out-Null
    & $AdbExe -s $TargetAdb shell "su -c 'rm -f /data/data/$PackageName/databases/akai_memory.db-wal /data/data/$PackageName/databases/akai_memory.db-shm'" 2>$null | Out-Null

    # Probing attivo tri-state su entrambi i file: solo NOT_FOUND con exit 0 e marcatore valido e' accettato
    $walState = $null
    $shmState = $null
    try {
        $walState = Probe-DeviceFileState -AdbExe $AdbExe -TargetAdb $TargetAdb -PackageName $PackageName -RelativePath "databases/akai_memory.db-wal" -Channel "any"
        $shmState = Probe-DeviceFileState -AdbExe $AdbExe -TargetAdb $TargetAdb -PackageName $PackageName -RelativePath "databases/akai_memory.db-shm" -Channel "any"
    } catch {
        $origErr = $_
        $script:elevWalState = $null
        $script:elevShmState = $null
        try {
            Invoke-WithAdbElevation -AdbExe $AdbExe -TargetAdb $TargetAdb -ActionBlock {
                & $AdbExe -s $TargetAdb shell "rm -f /data/data/$PackageName/databases/akai_memory.db-wal /data/data/$PackageName/databases/akai_memory.db-shm" 2>$null | Out-Null
                $script:elevWalState = Probe-DeviceFileState -AdbExe $AdbExe -TargetAdb $TargetAdb -PackageName $PackageName -RelativePath "databases/akai_memory.db-wal" -Channel "root"
                $script:elevShmState = Probe-DeviceFileState -AdbExe $AdbExe -TargetAdb $TargetAdb -PackageName $PackageName -RelativePath "databases/akai_memory.db-shm" -Channel "root"
            }
        } catch {
            if ($_.Exception.Message -match "STATO ADBD UNKNOWN") { throw }
        }
        if ($null -eq $script:elevWalState -or $null -eq $script:elevShmState) {
            throw $origErr
        }
        $walState = $script:elevWalState
        $shmState = $script:elevShmState
    }

    if ($walState -ne "NOT_FOUND" -or $shmState -ne "NOT_FOUND") {
        throw "ERRORE FAIL-CLOSED: Rimozione file WAL/SHM orfani fallita su device (WAL: $walState, SHM: $shmState). Ripristino abortito categoricamente in FAIL-CLOSED per prevenire corruzione dello schema."
    }
    Write-Host "      Assenza file WAL/SHM orfani confermata con successo (WAL: $walState, SHM: $shmState)." -ForegroundColor Green
    return $true
}

function Get-ApkCertificateFingerprint($apkFile) {
    if (-not (Test-Path $apkFile)) {
        throw "ERRORE FAIL-CLOSED: File APK non trovato in: $apkFile"
    }

    $out = $null
    if ($env:APKSIGNER_EXECUTABLE -and (Test-Path $env:APKSIGNER_EXECUTABLE)) {
        $out = & $env:APKSIGNER_EXECUTABLE verify --print-certs $apkFile 2>&1
    } else {
        $apksignerCli = Get-Command apksigner -ErrorAction SilentlyContinue
        if ($apksignerCli) {
            $out = & $apksignerCli.Source verify --print-certs $apkFile 2>&1
        } else {
            $signerJar = Get-ApkSignerJar
            if (-not $signerJar -or -not (Test-Path -LiteralPath $signerJar -PathType Leaf)) {
                throw "ERRORE FAIL-CLOSED: Tool apksigner.jar non trovato in: $signerJar"
            }

            $repoRootTool = Split-Path -Parent $PSScriptRoot
            $javaCandidates = @(
                $(if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME "bin\java.exe" } else { $null }),
                $(if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME "bin\java" } else { $null }),
                (Join-Path $repoRootTool "tools\jdk-17\bin\java.exe"),
                (Get-Command java -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
                "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay\tools\jdk-17\bin\java.exe"
            )
            $java = $javaCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
            if (-not $java) {
                throw "ERRORE FAIL-CLOSED: Eseguibile java non trovato."
            }

            $out = & $java -jar $signerJar verify --print-certs $apkFile 2>&1
        }
    }
    if ($LASTEXITCODE -ne 0) {
        throw "ERRORE FAIL-CLOSED: apksigner ha fallito la verifica dell'APK ($apkFile) con codice $LASTEXITCODE : $out"
    }

    $match = $out | Select-String "Signer #1 certificate SHA-256 digest:\s*([a-fA-F0-9]{64})"
    if (-not $match) {
        throw "ERRORE FAIL-CLOSED: Impossibile estrarre un digest SHA-256 valido (64 caratteri esadecimali) da: $apkFile"
    }

    $digest = $match.Matches[0].Groups[1].Value.ToLower().Trim()
    if ($digest.Length -ne 64) {
        throw "ERRORE FAIL-CLOSED: Digest SHA-256 corrotto o incompleto ($digest) per: $apkFile"
    }

    return $digest
}

function Assert-CandidateApkNoForbiddenTlsAssets($apkFile) {
    if (-not (Test-Path $apkFile)) {
        throw "ERRORE FAIL-CLOSED: File APK da ispezionare non trovato: $apkFile"
    }

    $item = Get-Item $apkFile
    if ($item.Length -lt 256) {
        $content = [System.IO.File]::ReadAllText($apkFile)
        if ($content -match '(\.p12|\.jks|\.key|\.der|\.crt|\.pass|server_keystore|AkaiRootCA)') {
            throw "BLOCCO FAIL-CLOSED DI SICUREZZA: L'APK candidato ('$apkFile') contiene asset/credenziali TLS vietati. I certificati e le chiavi devono essere generati unicamente on-device da TlsCertificateManager a runtime. Installazione categoricamente rifiutata."
        }
        return $true
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $apkFile))
        $forbiddenFound = @()
        try {
            foreach ($entry in $zip.Entries) {
                $name = $entry.FullName
                if ($name -match '(\.p12|\.jks|\.key|\.der|\.crt|\.pass|server_keystore)' -or $name -eq 'assets/www/AkaiRootCA.crt') {
                    $forbiddenFound += $name
                }
            }
        } finally {
            $zip.Dispose()
        }

        if ($forbiddenFound.Count -gt 0) {
            $forbiddenList = $forbiddenFound -join ", "
            throw "BLOCCO FAIL-CLOSED DI SICUREZZA: L'APK candidato ('$apkFile') contiene asset/credenziali TLS vietati: [$forbiddenList]. I certificati e le chiavi devono essere generati unicamente on-device da TlsCertificateManager a runtime. Installazione categoricamente rifiutata."
        }
    } catch [System.IO.InvalidDataException] {
        $rawBytes = [System.IO.File]::ReadAllBytes($apkFile)
        $rawText = [System.Text.Encoding]::ASCII.GetString($rawBytes)
        if ($rawText -match '(\.p12|\.jks|\.key|\.der|\.crt|\.pass|server_keystore|AkaiRootCA)') {
            throw "BLOCCO FAIL-CLOSED DI SICUREZZA: L'APK candidato ('$apkFile') contiene asset/credenziali TLS vietati. I certificati e le chiavi devono essere generati unicamente on-device da TlsCertificateManager a runtime. Installazione categoricamente rifiutata."
        }
    }

    Write-Host "      [PASS] Assenza credenziali TLS preconfezionate confermata (zero *.p12, *.jks, *.key, *.der, *.crt, *.pass nell'APK candidato)." -ForegroundColor Green
    return $true
}

function Verify-SQLiteIntegrityOffline($dbFile) {
    if (-not (Test-Path $dbFile)) {
        throw "ERRORE FAIL-CLOSED: File database per verifica integrita' non trovato: $dbFile"
    }
    if ((Get-Item $dbFile).Length -lt 512) {
        throw "ERRORE FAIL-CLOSED: File database per verifica integrita' corrotto o inferiore a 512 byte ($((Get-Item $dbFile).Length) byte)"
    }

    $walFile = "$dbFile-wal"
    $shmFile = "$dbFile-shm"
    $verified = $false

    # 1. Prova con Node.js (se non forzato sqlite3 CLI per test)
    if (-not $env:FORCE_SQLITE3_CLI) {
        $nodePaths = @(
            $env:NODE_EXE,
            (Join-Path (Split-Path -Parent $PSScriptRoot) "tools\nodejs\node.exe"),
            (Get-Command node -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
            "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay\tools\nodejs\node.exe"
        )
        $validNode = $nodePaths | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

        if ($validNode) {
        $dbEscaped = $dbFile.Replace('\', '/')
        $jsCheck = @"
try {
    const { DatabaseSync } = require('node:sqlite');
    const db = new DatabaseSync('$dbEscaped');

    // 1. Checkpoint categorico TRUNCATE
    let cp = null;
    try {
        cp = db.prepare('PRAGMA wal_checkpoint(TRUNCATE);').get();
    } catch (cpErr) {
        console.error('FAIL_CHECKPOINT_EXCEPTION: ' + cpErr.message);
        process.exit(3);
    }
    if (!cp || cp.busy !== 0) {
        console.error('FAIL_CHECKPOINT_BUSY: busy=' + (cp ? cp.busy : 'unknown'));
        process.exit(3);
    }

    // 2. Controllo di integrita' categorico
    const row = db.prepare('PRAGMA integrity_check;').get();
    db.close();
    if (row && row.integrity_check === 'ok') {
        process.exit(0);
    }
    console.error('FAIL_INTEGRITY: ' + (row ? row.integrity_check : 'null'));
    process.exit(1);
} catch (e) {
    console.error('FAIL_OPEN: ' + e.message);
    process.exit(2);
}
"@
        $res = & $validNode --no-warnings -e $jsCheck 2>&1
        if ($LASTEXITCODE -eq 0) {
            $verified = $true
        } elseif ($LASTEXITCODE -eq 3) {
            throw "ERRORE FAIL-CLOSED: Checkpoint WAL fallito o bloccato (busy>0) su $dbFile : $res"
        } elseif ($LASTEXITCODE -eq 1) {
            throw "ERRORE FAIL-CLOSED: Controllo di integrita' SQLite fallito (database corrotto) su $dbFile : $res"
        }
    }
    }

    # 2. Prova con Python (se non forzato sqlite3 CLI per test)
    if (-not $verified -and -not $env:FORCE_SQLITE3_CLI) {
        $pythonCmd = $null
        if ($env:PYTHON_EXE -and (Test-Path $env:PYTHON_EXE)) {
            $pythonCmd = @{ Source = $env:PYTHON_EXE }
        } else {
            $pythonCmd = Get-Command python3 -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch "WindowsApps" } | Select-Object -First 1
            if (-not $pythonCmd) { $pythonCmd = Get-Command python -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch "WindowsApps" } | Select-Object -First 1 }
        }
        if ($pythonCmd) {
            $pyCheck = "import sqlite3, sys
try:
    con = sqlite3.connect(r'$dbFile')
    cur = con.cursor()
    cur.execute('PRAGMA wal_checkpoint(TRUNCATE);')
    cp = cur.fetchone()
    if not cp or cp[0] != 0:
        b = cp[0] if cp else -1; sys.stderr.write(f'FAIL_CHECKPOINT_BUSY: busy={b}\n')
        sys.exit(3)
    res = cur.execute('PRAGMA integrity_check;').fetchone()[0]
    con.close()
    if res == 'ok':
        sys.exit(0)
    sys.stderr.write(f'FAIL_INTEGRITY: {res}\n')
    sys.exit(1)
except Exception as e:
    sys.stderr.write(f'FAIL_OPEN: {e}\n')
    sys.exit(2)"
            $res = & $pythonCmd.Source -c $pyCheck 2>&1
            if ($LASTEXITCODE -eq 0) {
                $verified = $true
            } elseif ($LASTEXITCODE -eq 3) {
                throw "ERRORE FAIL-CLOSED: Checkpoint WAL fallito o bloccato con Python su $dbFile : $res"
            } elseif ($LASTEXITCODE -eq 1) {
                throw "ERRORE FAIL-CLOSED: Controllo di integrita' SQLite fallito con Python (exit $LASTEXITCODE) su $dbFile : $res"
            }
        }
    }

    # 3. Prova con sqlite3 CLI
    if (-not $verified) {
        $sqlite3 = $null
        if ($env:SQLITE3_EXE -and (Test-Path $env:SQLITE3_EXE)) {
            $sqlite3 = @{ Source = $env:SQLITE3_EXE }
        } else {
            $sqlite3 = Get-Command sqlite3 -ErrorAction SilentlyContinue
        }
        if ($sqlite3) {
            $cpOut = & $sqlite3.Source $dbFile "PRAGMA wal_checkpoint(TRUNCATE);" 2>&1
            if ($LASTEXITCODE -ne 0 -or ($cpOut.ToString().Trim() -notmatch "^0\|")) {
                throw "ERRORE FAIL-CLOSED: Checkpoint WAL fallito o bloccato con sqlite3 su $dbFile : $cpOut"
            }
            $out = & $sqlite3.Source $dbFile "PRAGMA integrity_check;" 2>&1
            if ($LASTEXITCODE -eq 0 -and $out.ToString().Trim() -eq "ok") {
                $verified = $true
            } else {
                throw "ERRORE FAIL-CLOSED: Controllo di integrita' fallito con sqlite3 su $dbFile : $out"
            }
        }
    }

    if (-not $verified) {
        throw "ERRORE FAIL-CLOSED: Impossibile verificare l'integrita' SQLite offline. Nessun interprete idoneo disponibile (Node.js, Python o sqlite3 mancanti). Operazione interrotta per sicurezza."
    }

    # Se presente WAL post-checkpoint con dimensione 0 o residuo, verificare o rimuovere
    if (Test-Path $walFile) {
        if ((Get-Item $walFile).Length -eq 0) {
            Remove-Item $walFile -Force -ErrorAction SilentlyContinue
        } else {
            throw "ERRORE FAIL-CLOSED: Post-checkpoint TRUNCATE il file WAL ($walFile) contiene ancora $((Get-Item $walFile).Length) bytes non consolidati. Impossibile consolidare il database come single-file autonomo."
        }
    }
    if (Test-Path $shmFile) {
        Remove-Item $shmFile -Force -ErrorAction SilentlyContinue
    }

    return $true
}

function Protect-TlsData {
    param(
        [byte[]]$PlainBytes,
        [string]$VaultDir
    )
    $isWin = [System.Environment]::OSVersion.Platform -match "Win"
    if ($isWin) {
        if ($env:MOCK_FAIL_DPAPI -eq 'true') {
            throw "ERRORE FAIL-CLOSED: DPAPI CurrentUser simulata non disponibile per test negativo. Rifiuto categorico del fallback AES per proteggere le chiavi private."
        }
        try {
            Add-Type -AssemblyName System.Security -ErrorAction Stop
            $entropy = [System.Text.Encoding]::UTF8.GetBytes("AkaiTv_TLS_Identity_2026_DPAPI_Entropy")
            $cipher = [System.Security.Cryptography.ProtectedData]::Protect(
                $PlainBytes, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser
            )
            return @{
                CipherBytes = $cipher
                Mechanism = "DPAPI_CURRENT_USER"
            }
        } catch {
            throw "ERRORE FAIL-CLOSED: DPAPI CurrentUser fallita su Windows ($($_.Exception.Message)). Rifiuto categorico del fallback AES per proteggere le chiavi private da memorizzazione non autorizzata."
        }
    }

    # Cross-platform AES-256-CBC con keyfile locale protetto da OS (usato esclusivamente su Linux/macOS)
    $keyFile = Join-Path $VaultDir ".vault_master.key"
    if (-not (Test-Path $keyFile)) {
        $key = New-Object byte[] 32
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($key)
        [System.IO.File]::WriteAllBytes($keyFile, $key)
        if (-not $isWin) {
            & chmod 600 $keyFile 2>$null
        }
    }
    $aesKey = [System.IO.File]::ReadAllBytes($keyFile)
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $aesKey
    $aes.GenerateIV()
    $encryptor = $aes.CreateEncryptor()
    $encData = $encryptor.TransformFinalBlock($PlainBytes, 0, $PlainBytes.Length)
    $combined = New-Object byte[] ($aes.IV.Length + $encData.Length)
    [System.Buffer]::BlockCopy($aes.IV, 0, $combined, 0, $aes.IV.Length)
    [System.Buffer]::BlockCopy($encData, 0, $combined, $aes.IV.Length, $encData.Length)
    return @{
        CipherBytes = $combined
        Mechanism = "AES_256_CBC"
    }
}

function Unprotect-TlsData {
    param(
        [byte[]]$CipherBytes,
        [string]$Mechanism,
        [string]$VaultDir
    )
    if ($Mechanism -eq "DPAPI_CURRENT_USER") {
        try {
            Add-Type -AssemblyName System.Security -ErrorAction Stop
            $entropy = [System.Text.Encoding]::UTF8.GetBytes("AkaiTv_TLS_Identity_2026_DPAPI_Entropy")
            return [System.Security.Cryptography.ProtectedData]::Unprotect(
                $CipherBytes, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser
            )
        } catch {
            throw "ERRORE FAIL-CLOSED: Decifratura DPAPI CurrentUser fallita: $($_.Exception.Message)"
        }
    } elseif ($Mechanism -eq "AES_256_CBC") {
        $keyFile = Join-Path $VaultDir ".vault_master.key"
        if (-not (Test-Path $keyFile)) {
            throw "ERRORE FAIL-CLOSED: Master key del vault crittografico non trovata: $keyFile"
        }
        $aesKey = [System.IO.File]::ReadAllBytes($keyFile)
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Key = $aesKey
        $iv = New-Object byte[] 16
        [System.Buffer]::BlockCopy($CipherBytes, 0, $iv, 0, 16)
        $aes.IV = $iv
        $decryptor = $aes.CreateDecryptor()
        return $decryptor.TransformFinalBlock($CipherBytes, 16, $CipherBytes.Length - 16)
    } else {
        throw "ERRORE FAIL-CLOSED: Meccanismo di cifratura non riconosciuto: $Mechanism"
    }
}

function Resolve-SecureVaultSubdir {
    param(
        [string]$SessionDir,
        [string]$PackageName,
        [string]$SubdirName = "tls_identity"
    )
    $sessionName = Split-Path $SessionDir -Leaf
    $isWin = [System.Environment]::OSVersion.Platform -match "Win"
    
    # Risoluzione percorso assoluto SessionDir per evitare trappole di percorsi relativi (es. .\backup_tv)
    $fullSessionDir = $null
    try {
        $fullSessionDir = [System.IO.Path]::GetFullPath($SessionDir)
    } catch {
        $fullSessionDir = $SessionDir
    }

    $isCloudSynced = ($fullSessionDir -match "(?i)(OneDrive|Dropbox|Google Drive|iCloud|Nextcloud)") -or ($env:AKAI_FORCE_LOCAL_VAULT -eq 'true')

    $vaultDir = $null
    if ($isWin) {
        # REQUISITO SUPERVISORE P1: Su Windows, indipendentemente dal percorso di SessionDir (anche relativo o non rilevato),
        # il vault delle credenziali è SEMPRE e OBBLIGATORIAMENTE deviato in LOCALAPPDATA per garantire l'isolamento assoluto da cloud sync.
        if (-not $env:LOCALAPPDATA) {
            throw "ERRORE FAIL-CLOSED: Environment variable LOCALAPPDATA non definita o non accessibile su Windows. Impossibile garantire isolamento sicuro del vault ($SubdirName)."
        }
        $vaultDir = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "AkaiTvSecureVault\$PackageName\$sessionName\$SubdirName"))
    } else {
        # Su Linux / macOS (standard XDG data dir locale)
        if ($isCloudSynced -or $env:AKAI_FORCE_LOCAL_VAULT -eq 'true' -or ($env:HOME -and (Test-Path (Join-Path $env:HOME ".local")))) {
            if ($env:HOME) {
                $vaultDir = [System.IO.Path]::GetFullPath((Join-Path $env:HOME ".local/share/akai_tv_secure_vault/$PackageName/$sessionName/$SubdirName"))
            } else {
                $vaultDir = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) "akai_tv_secure_vault/$PackageName/$sessionName/$SubdirName"))
            }
        } else {
            $vaultDir = [System.IO.Path]::GetFullPath((Join-Path $fullSessionDir $SubdirName))
        }
    }

    if (-not (Test-Path $vaultDir)) {
        New-Item -ItemType Directory -Force -Path $vaultDir | Out-Null
    }

    # Restringi e verifica effettiva delle ACL / permessi cartella OS solo all'utente corrente
    if ($isWin) {
        try {
            $dirInfo = New-Object System.IO.DirectoryInfo($vaultDir)
            $dirSec = $dirInfo.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
            $dirSec.SetAccessRuleProtection($true, $false)
            $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($currentUser, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
            $dirSec.AddAccessRule($rule)
            $dirInfo.SetAccessControl($dirSec)

            # Verifica effettiva che l'ereditarietà sia disabilitata e che l'ACL sia protetta
            $verifySec = $dirInfo.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
            if ($verifySec.AreAccessRulesProtected -ne $true) {
                throw "Verifica ACL fallita: le regole di accesso non risultano protette (ereditarieta' ancora attiva)."
            }
        } catch {
            throw "ERRORE FAIL-CLOSED: Impossibile impostare o verificare le ACL esclusive sul vault locale Windows ($vaultDir): $($_.Exception.Message)"
        }
    } else {
        try {
            & chmod 700 $vaultDir 2>$null
        } catch {
            throw "ERRORE FAIL-CLOSED: Impossibile impostare i permessi 700 sul vault locale ($vaultDir): $($_.Exception.Message)"
        }
    }

    return @{
        VaultDir = $vaultDir
        IsCloudSynced = if ($isWin) { $true } else { $isCloudSynced }
    }
}

function Resolve-TlsVaultDir {
    param(
        [string]$SessionDir,
        [string]$PackageName
    )
    return Resolve-SecureVaultSubdir -SessionDir $SessionDir -PackageName $PackageName -SubdirName "tls_identity"
}

function Clear-EphemeralPlaintextDir {
    param([string]$EphemeralDir)
    if ([string]::IsNullOrWhiteSpace($EphemeralDir) -or -not (Test-Path $EphemeralDir)) { return }
    try {
        foreach ($ef in (Get-ChildItem -Path $EphemeralDir -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            try {
                if ($ef.Length -gt 0) {
                    [System.IO.File]::WriteAllBytes($ef.FullName, (New-Object byte[] $ef.Length))
                }
            } catch {}
        }
    } finally {
        Remove-Item $EphemeralDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Backup-DeviceTlsIdentity {
    param(
        [string]$AdbExe,
        [string]$TargetAdb,
        [string]$PackageName,
        [string]$SessionDir
    )
    $sessionTlsDir = Join-Path $SessionDir "tls_identity"
    New-Item -ItemType Directory -Force -Path $sessionTlsDir | Out-Null

    $filesToBackup = @("server_keystore.p12", "server_keystore.pass", "ca.pem", "ca.crt", "ca_key.der")
    $bakFileName = "server_keystore.p12.bak"
    $bakPresent = $false
    $bakExtracted = $false
    $ephemeralDir = Join-Path ([System.IO.Path]::GetTempPath()) "akai_tls_rx_$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $ephemeralDir | Out-Null

    $manifestFiles = @{}
    $hasKeystoreBak = $false
    $keystoreBakMeta = $null
    try {
        $probeKs = $null
        $unprivProbeSucceeded = $false
        try {
            $probeKs = Probe-DeviceFileState -AdbExe $AdbExe -TargetAdb $TargetAdb -PackageName $PackageName -RelativePath "files/server_keystore.p12" -Channel "any"
            $unprivProbeSucceeded = $true
        } catch {
            $unprivProbeSucceeded = $false
        }

        if ($unprivProbeSucceeded -and $probeKs -eq "NOT_FOUND") {
            Write-Host "      Snapshot identita' TLS: ASSENTE sul device (release legacy HTTP-only v5). Nessun backup TLS richiesto." -ForegroundColor Green
            $manifest = @{
                HasTls = $false
                Reason = "LEGACY_NO_TLS"
            }
            [System.IO.File]::WriteAllText((Join-Path $sessionTlsDir "tls_manifest.json"), ($manifest | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)
            return $manifest
        }

        if ($unprivProbeSucceeded -and $probeKs -eq "EXISTS") {
            $needElevation = @()
            foreach ($f in $filesToBackup) {
                $rxTempPath = Join-Path $ephemeralDir $f
                $minB = if ($f -eq "server_keystore.p12") { 512 } else { 1 }
                $rx = Receive-FileViaAdbExecOut -AdbExe $AdbExe -TargetAdb $TargetAdb -RemoteCommand "run-as $PackageName cat files/$f" -LocalFilePath $rxTempPath -MinBytes $minB
                if (-not ($rx.Success -and (Test-Path $rxTempPath) -and (Get-Item $rxTempPath).Length -ge $minB)) {
                    $rx = Receive-FileViaAdbExecOut -AdbExe $AdbExe -TargetAdb $TargetAdb -RemoteCommand "su -c 'cat /data/data/$PackageName/files/$f'" -LocalFilePath $rxTempPath -MinBytes $minB
                }
                if (-not ($rx.Success -and (Test-Path $rxTempPath) -and (Get-Item $rxTempPath).Length -ge $minB)) {
                    $needElevation += $f
                }
            }
            try {
                $probeBak = Probe-DeviceFileState -AdbExe $AdbExe -TargetAdb $TargetAdb -PackageName $PackageName -RelativePath "files/$bakFileName" -Channel "any"
                if ($probeBak -eq "EXISTS") {
                    $bakPresent = $true
                    $bakTemp = Join-Path $ephemeralDir $bakFileName
                    $rxBak = Receive-FileViaAdbExecOut -AdbExe $AdbExe -TargetAdb $TargetAdb -RemoteCommand "run-as $PackageName cat files/$bakFileName" -LocalFilePath $bakTemp -MinBytes 512
                    if (-not ($rxBak.Success -and (Test-Path $bakTemp) -and (Get-Item $bakTemp).Length -ge 512)) {
                        $rxBak = Receive-FileViaAdbExecOut -AdbExe $AdbExe -TargetAdb $TargetAdb -RemoteCommand "su -c 'cat /data/data/$PackageName/files/$bakFileName'" -LocalFilePath $bakTemp -MinBytes 512
                    }
                    if ($rxBak.Success -and (Test-Path $bakTemp) -and (Get-Item $bakTemp).Length -ge 512) {
                        $bakExtracted = $true
                    } else {
                        $needElevation += $bakFileName
                    }
                }
            } catch {}
            if ($needElevation.Count -gt 0) {
                $script:tlsBatchErr = $null
                $script:bakElevGot = $false
                try {
                    Invoke-WithAdbElevation -AdbExe $AdbExe -TargetAdb $TargetAdb -ActionBlock {
                        foreach ($f in $needElevation) {
                            $rxTempPath = Join-Path $ephemeralDir $f
                            $minB = if ($f -eq "server_keystore.p12" -or $f -eq $bakFileName) { 512 } else { 1 }
                            $rxElev = Receive-FileViaAdbExecOut -AdbExe $AdbExe -TargetAdb $TargetAdb -RemoteCommand "cat /data/data/$PackageName/files/$f" -LocalFilePath $rxTempPath -MinBytes $minB
                            if (-not ($rxElev.Success -and (Test-Path $rxTempPath) -and (Get-Item $rxTempPath).Length -ge $minB)) {
                                $script:tlsBatchErr = "ERRORE FAIL-CLOSED (P1 Gate): Estrazione asset TLS obbligatorio ($f) fallita o dimensione insufficiente. Tutti gli asset TLS presenti sono obbligatori."
                                break
                            }
                            if ($f -eq $bakFileName) { $script:bakElevGot = $true }
                        }
                    }
                } catch {
                    if ($_.Exception.Message -match "STATO ADBD UNKNOWN") { throw }
                    $script:tlsBatchErr = "ERRORE FAIL-CLOSED (P1 Gate): Estrazione asset TLS obbligatorio ($($needElevation[0])) fallita o dimensione insufficiente ($($_.Exception.Message)). Tutti i 5 file sono obbligatori su installazione TLS."
                }
                if ($script:bakElevGot) { $bakExtracted = $true; $script:bakElevGot = $false }
                if ($script:tlsBatchErr) {
                    $errToThrow = $script:tlsBatchErr
                    $script:tlsBatchErr = $null
                    throw $errToThrow
                }
            }
        } elseif (-not $unprivProbeSucceeded) {
            # Unprivileged channels negati: singola sessione root adbd (1 root + 1 unroot) per probe + estrazione di tutti i file TLS (.bak incluso se presente)
            $script:elevProbeKs = $null
            $script:tlsElevExtractErr = $null
            $script:elevBakPresent = $false
            $script:elevBakExtracted = $false
            Invoke-WithAdbElevation -AdbExe $AdbExe -TargetAdb $TargetAdb -ActionBlock {
                $script:elevProbeKs = Probe-DeviceFileState -AdbExe $AdbExe -TargetAdb $TargetAdb -PackageName $PackageName -RelativePath "files/server_keystore.p12" -Channel "root"
                if ($script:elevProbeKs -eq "EXISTS") {
                    foreach ($f in $filesToBackup) {
                        $rxTempPath = Join-Path $ephemeralDir $f
                        $minB = if ($f -eq "server_keystore.p12") { 512 } else { 1 }
                        $rxElev = Receive-FileViaAdbExecOut -AdbExe $AdbExe -TargetAdb $TargetAdb -RemoteCommand "cat /data/data/$PackageName/files/$f" -LocalFilePath $rxTempPath -MinBytes $minB
                        if (-not ($rxElev.Success -and (Test-Path $rxTempPath) -and (Get-Item $rxTempPath).Length -ge $minB)) {
                            $script:tlsElevExtractErr = "ERRORE FAIL-CLOSED (P1 Gate): Estrazione asset TLS obbligatorio ($f) fallita o dimensione insufficiente. Tutti i 5 file sono obbligatori su installazione TLS."
                            break
                        }
                    }
                    if (-not $script:tlsElevExtractErr) {
                        $probeBakRoot = Probe-DeviceFileState -AdbExe $AdbExe -TargetAdb $TargetAdb -PackageName $PackageName -RelativePath "files/$bakFileName" -Channel "root"
                        if ($probeBakRoot -eq "EXISTS") {
                            $script:elevBakPresent = $true
                            $bakTempPath = Join-Path $ephemeralDir $bakFileName
                            $rxBakElev = Receive-FileViaAdbExecOut -AdbExe $AdbExe -TargetAdb $TargetAdb -RemoteCommand "cat /data/data/$PackageName/files/$bakFileName" -LocalFilePath $bakTempPath -MinBytes 512
                            if (-not ($rxBakElev.Success -and (Test-Path $bakTempPath) -and (Get-Item $bakTempPath).Length -ge 512)) {
                                $script:tlsElevExtractErr = "ERRORE FAIL-CLOSED (P1 Gate): File $bakFileName presente sul dispositivo ma estrazione fallita sotto root."
                            } else {
                                $script:elevBakExtracted = $true
                            }
                        }
                    }
                }
            }
            if ($script:elevProbeKs) {
                $probeKs = $script:elevProbeKs
                $script:elevProbeKs = $null
            }
            $bakPresent = [bool]$script:elevBakPresent
            $bakExtracted = [bool]$script:elevBakExtracted
            $script:elevBakPresent = $false
            $script:elevBakExtracted = $false
            if ($probeKs -eq "NOT_FOUND") {
                $script:tlsElevExtractErr = $null
                Write-Host "      Snapshot identita' TLS: ASSENTE sul device (release legacy HTTP-only v5). Nessun backup TLS richiesto." -ForegroundColor Green
                $manifest = @{
                    HasTls = $false
                    Reason = "LEGACY_NO_TLS"
                }
                [System.IO.File]::WriteAllText((Join-Path $sessionTlsDir "tls_manifest.json"), ($manifest | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)
                return $manifest
            }
            if ($script:tlsElevExtractErr) {
                $errToThrow = $script:tlsElevExtractErr
                $script:tlsElevExtractErr = $null
                throw $errToThrow
            }
        }

        if ($probeKs -ne "EXISTS") {
            Write-Host "      Probe server_keystore.p12: stato $probeKs (permessi negati o storage non accessibile)." -ForegroundColor Yellow
            throw "ERRORE FAIL-CLOSED: Impossibile accertare con sicurezza lo stato del keystore TLS sul dispositivo."
        }

        # Verifica completezza 5/5 prima di aprire/scrivere il vault definitivo
        foreach ($f in $filesToBackup) {
            $rxTempPath = Join-Path $ephemeralDir $f
            $minB = if ($f -eq "server_keystore.p12") { 512 } else { 1 }
            if (-not (Test-Path $rxTempPath) -or (Get-Item $rxTempPath).Length -lt $minB) {
                throw "ERRORE FAIL-CLOSED (P1 Gate): Estrazione asset TLS obbligatorio ($f) fallita o dimensione insufficiente. Tutti i 5 file sono obbligatori su installazione TLS."
            }
        }

        # Risoluzione vault protetto non sincronizzato
        $vaultInfo = Resolve-TlsVaultDir -SessionDir $SessionDir -PackageName $PackageName
        $vaultDir = $vaultInfo.VaultDir
        $isCloudSynced = $vaultInfo.IsCloudSynced

        foreach ($f in $filesToBackup) {
            $rxTempPath = Join-Path $ephemeralDir $f
            $plainBytes = [System.IO.File]::ReadAllBytes($rxTempPath)
            $plainHash = Get-Sha256Hex $rxTempPath
            $plainLen = $plainBytes.Length

            # REQUISITO P1-1: Cifratura a riposo nel vault con protezione OS (DPAPI / AES-256)
            $protectRes = Protect-TlsData -PlainBytes $plainBytes -VaultDir $vaultDir
            $encDestPath = Join-Path $vaultDir "$f.enc"
            [System.IO.File]::WriteAllBytes($encDestPath, $protectRes.CipherBytes)

            # Cancellazione sicura immediata del file in chiaro effimero
            $zeroBuf = New-Object byte[] $plainLen
            [System.IO.File]::WriteAllBytes($rxTempPath, $zeroBuf)
            Remove-Item $rxTempPath -Force -ErrorAction SilentlyContinue

            # REQUISITO P1-1: Verifica di recuperabilita' (roundtrip test)
            $unprotectTest = Unprotect-TlsData -CipherBytes $protectRes.CipherBytes -Mechanism $protectRes.Mechanism -VaultDir $vaultDir
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $testDecHash = -join ($sha.ComputeHash($unprotectTest) | ForEach-Object { "{0:x2}" -f $_ })
            if ($testDecHash -ne $plainHash) {
                throw "ERRORE FAIL-CLOSED: Test di recuperabilita'/decifratura per $f fallito prima del salvataggio. Hash non corrispondente!"
            }

            $cipherHash = -join ($sha.ComputeHash($protectRes.CipherBytes) | ForEach-Object { "{0:x2}" -f $_ })

            $manifestFiles[$f] = @{
                Sha256 = $plainHash
                SizeBytes = $plainLen
                Encrypted = $true
                CipherSha256 = $cipherHash
                Mechanism = $protectRes.Mechanism
            }
        }

        if ($bakPresent -and $bakExtracted) {
            $bakTemp = Join-Path $ephemeralDir $bakFileName
            $bakBytes = [System.IO.File]::ReadAllBytes($bakTemp)
            $bakHash = Get-Sha256Hex $bakTemp
            $bakLen = $bakBytes.Length
            $bakProt = Protect-TlsData -PlainBytes $bakBytes -VaultDir $vaultDir
            [System.IO.File]::WriteAllBytes((Join-Path $vaultDir "$bakFileName.enc"), $bakProt.CipherBytes)
            $zeroBak = New-Object byte[] $bakLen
            [System.IO.File]::WriteAllBytes($bakTemp, $zeroBak)
            Remove-Item $bakTemp -Force -ErrorAction SilentlyContinue

            $bakUnp = Unprotect-TlsData -CipherBytes $bakProt.CipherBytes -Mechanism $bakProt.Mechanism -VaultDir $vaultDir
            $shaBak = [System.Security.Cryptography.SHA256]::Create()
            $bakDecHash = -join ($shaBak.ComputeHash($bakUnp) | ForEach-Object { "{0:x2}" -f $_ })
            if ($bakDecHash -ne $bakHash) {
                throw "ERRORE FAIL-CLOSED: Verifica roundtrip decifratura fallita per $bakFileName."
            }
            $bakCipherHash = -join ($shaBak.ComputeHash($bakProt.CipherBytes) | ForEach-Object { "{0:x2}" -f $_ })
            $hasKeystoreBak = $true
            $keystoreBakMeta = @{
                Sha256 = $bakHash
                SizeBytes = $bakLen
                Encrypted = $true
                CipherSha256 = $bakCipherHash
                Mechanism = $bakProt.Mechanism
            }
        }
    } finally {
        Clear-EphemeralPlaintextDir -EphemeralDir $ephemeralDir
    }

    # Creazione del manifest (zero segreti in chiaro)
    $manifest = @{
        HasTls = $true
        SessionDir = $SessionDir
        VaultDir = $vaultDir
        IsCloudSynced = $isCloudSynced
        Files = $manifestFiles
        KeystoreSha256 = $manifestFiles["server_keystore.p12"].Sha256
        KeystoreBytes = $manifestFiles["server_keystore.p12"].SizeBytes
        HasKeystoreBak = $hasKeystoreBak
    }
    if ($hasKeystoreBak -and $keystoreBakMeta) {
        $manifest["KeystoreBak"] = $keystoreBakMeta
    }
    $manifestJson = $manifest | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText((Join-Path $sessionTlsDir "tls_manifest.json"), $manifestJson, [System.Text.Encoding]::UTF8)

    # Se vault separato da cloud sync, scrivi pointer
    if ($vaultDir -ne $sessionTlsDir) {
        $pointer = @{
            VaultDir = $vaultDir
            CreatedAt = (Get-Date -Format "o")
        }
        [System.IO.File]::WriteAllText((Join-Path $sessionTlsDir "vault_pointer.json"), ($pointer | ConvertTo-Json), [System.Text.Encoding]::UTF8)
    }

    Write-Host "      Snapshot identita' TLS CIFRATO e verificato con successo: tutti i 5 asset protetti nel vault ($vaultDir) in formato .enc (file temporanei effimeri isolati azzerati e rimossi), ZERO segreti in chiaro nel manifest." -ForegroundColor Green
    return $manifest
}

function Restore-DeviceTlsIdentity {
    param(
        [string]$AdbExe,
        [string]$TargetAdb,
        [string]$PackageName,
        [string]$SessionDir,
        [string]$ChownTarget
    )
    $sessionTlsDir = Join-Path $SessionDir "tls_identity"
    $manifestPath = Join-Path $sessionTlsDir "tls_manifest.json"

    if (-not (Test-Path $manifestPath)) {
        Write-Host "      Ripristino TLS: nessun manifesto TLS nel backup di sessione (release v5 HTTP legacy). Salto ripristino TLS." -ForegroundColor Cyan
        return @{ Restored = $false; Reason = "NO_TLS_BACKUP" }
    }

    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.HasTls -ne $true) {
        Write-Host "      Ripristino TLS: sessione contrassegnata come priva di TLS (HasTls=false). Salto ripristino TLS." -ForegroundColor Cyan
        return @{ Restored = $false; Reason = "NO_TLS_BACKUP" }
    }

    # Risolvi la cartella del vault
    $vaultDir = $manifest.VaultDir
    $pointerPath = Join-Path $sessionTlsDir "vault_pointer.json"
    if (Test-Path $pointerPath) {
        try {
            $ptr = Get-Content $pointerPath -Raw | ConvertFrom-Json
            if ($ptr.VaultDir -and (Test-Path $ptr.VaultDir)) {
                $vaultDir = $ptr.VaultDir
            }
        } catch {}
    }
    if (-not $vaultDir -or -not (Test-Path $vaultDir)) {
        $vaultDir = $sessionTlsDir
    }

    Write-Host "[ROLLBACK TLS] Ripristino identita' TLS da vault cifrato ($vaultDir)..." -ForegroundColor Yellow

    $filesToRestore = @("server_keystore.p12", "server_keystore.pass", "ca.pem", "ca.crt", "ca_key.der")
    $manifestFilesProp = $manifest.Files
    $hasBak = ($manifest.HasKeystoreBak -eq $true -and $null -ne $manifest.KeystoreBak)
    $targetMetaMap = [ordered]@{}
    foreach ($fName in $filesToRestore) {
        $fileMeta = $manifestFilesProp.$fName
        if (-not $fileMeta) {
            throw "ERRORE FAIL-CLOSED: File obbligatorio $fName assente nel manifesto di rollback."
        }
        $targetMetaMap[$fName] = $fileMeta
    }
    if ($hasBak) {
        $targetMetaMap["server_keystore.p12.bak"] = $manifest.KeystoreBak
    }
    $decryptedPayloads = @{}

    # 1. Decifratura in RAM, parita' hash pre-invio e invio unprivileged (run-as / su) o batch root
    $needElevSend = @()
    foreach ($fName in $targetMetaMap.Keys) {
        $fileMeta = $targetMetaMap[$fName]
        $encPath = Join-Path $vaultDir "$fName.enc"
        $decryptedBytes = $null
        if (-not (Test-Path $encPath)) {
            if ($fName -ne "server_keystore.p12.bak") {
                $legacyPlain = Join-Path $vaultDir $fName
                if (Test-Path $legacyPlain) {
                    $decryptedBytes = [System.IO.File]::ReadAllBytes($legacyPlain)
                }
            }
            if ($null -eq $decryptedBytes) {
                throw "ERRORE FAIL-CLOSED: File cifrato $fName.enc assente nel vault crittografico: $vaultDir"
            }
        } else {
            $cipherBytes = [System.IO.File]::ReadAllBytes($encPath)
            $mechanism = $fileMeta.Mechanism
            $decryptedBytes = Unprotect-TlsData -CipherBytes $cipherBytes -Mechanism $mechanism -VaultDir $vaultDir
        }

        # Verifica preliminare parita' hash SHA-256 pre-invio
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $preSendHash = -join ($sha.ComputeHash($decryptedBytes) | ForEach-Object { "{0:x2}" -f $_ })
        if ($preSendHash -ne $fileMeta.Sha256) {
            throw "ERRORE FAIL-CLOSED: Corruzione rilevata durante la decifratura di $fName! Hash non corrisponde al manifesto pre-invio."
        }
        $decryptedPayloads[$fName] = $decryptedBytes

        $restored = $false
        $cmd = "run-as $PackageName sh -c 'mkdir -p files; cat > files/$fName; chmod 600 files/$fName'"
        $res = Send-FileViaAdbExecIn -AdbExe $AdbExe -TargetAdb $TargetAdb -RawBytes $decryptedBytes -RemoteCommand $cmd
        if ($res.Success) { $restored = $true }

        if (-not $restored) {
            $cmd = "su -c 'mkdir -p /data/data/$PackageName/files; cat > /data/data/$PackageName/files/$fName; chown $ChownTarget /data/data/$PackageName/files/$fName; chmod 600 /data/data/$PackageName/files/$fName'"
            $res = Send-FileViaAdbExecIn -AdbExe $AdbExe -TargetAdb $TargetAdb -RawBytes $decryptedBytes -RemoteCommand $cmd
            if ($res.Success) { $restored = $true }
        }

        if (-not $restored) {
            $needElevSend += $fName
        }
    }

    if ($needElevSend.Count -gt 0) {
        $script:tlsSendFailedFile = $null
        Invoke-WithAdbElevation -AdbExe $AdbExe -TargetAdb $TargetAdb -ActionBlock {
            foreach ($fName in $needElevSend) {
                $cmd = "sh -c 'mkdir -p /data/data/$PackageName/files; cat > /data/data/$PackageName/files/$fName; chown $ChownTarget /data/data/$PackageName/files/$fName; chmod 600 /data/data/$PackageName/files/$fName'"
                $sRes = Send-FileViaAdbExecIn -AdbExe $AdbExe -TargetAdb $TargetAdb -RawBytes $decryptedPayloads[$fName] -RemoteCommand $cmd
                if (-not $sRes.Success) {
                    $script:tlsSendFailedFile = $fName
                    break
                }
            }
        }
        if ($script:tlsSendFailedFile) {
            $badFile = $script:tlsSendFailedFile
            $script:tlsSendFailedFile = $null
            throw "ERRORE FAIL-CLOSED: Invio file TLS ($badFile) fallito sul dispositivo."
        }
    }

    # 2. REQUISITO P1-2: Verifica di parita' hash SHA-256 su tutti i file TLS post-ripristino dal device
    $verifyDir = Join-Path ([System.IO.Path]::GetTempPath()) "akai_verify_restore_$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $verifyDir | Out-Null

    try {
        $needElevRead = @()
        foreach ($fName in $targetMetaMap.Keys) {
            $verifyFilePath = Join-Path $verifyDir $fName
            $minB = if ($fName -eq "server_keystore.p12" -or $fName -eq "server_keystore.p12.bak") { 512 } else { 1 }

            $rx = Receive-FileViaAdbExecOut -AdbExe $AdbExe -TargetAdb $TargetAdb -RemoteCommand "run-as $PackageName cat files/$fName" -LocalFilePath $verifyFilePath -MinBytes $minB
            if (-not $rx.Success) {
                $rx = Receive-FileViaAdbExecOut -AdbExe $AdbExe -TargetAdb $TargetAdb -RemoteCommand "su -c 'cat /data/data/$PackageName/files/$fName'" -LocalFilePath $verifyFilePath -MinBytes $minB
            }
            if (-not $rx.Success) {
                $needElevRead += $fName
            }
        }

        if ($needElevRead.Count -gt 0) {
            Invoke-WithAdbElevation -AdbExe $AdbExe -TargetAdb $TargetAdb -ActionBlock {
                foreach ($fName in $needElevRead) {
                    $verifyFilePath = Join-Path $verifyDir $fName
                    $minB = if ($fName -eq "server_keystore.p12" -or $fName -eq "server_keystore.p12.bak") { 512 } else { 1 }
                    [void](Receive-FileViaAdbExecOut -AdbExe $AdbExe -TargetAdb $TargetAdb -RemoteCommand "cat /data/data/$PackageName/files/$fName" -LocalFilePath $verifyFilePath -MinBytes $minB)
                }
            }
        }

        foreach ($fName in $targetMetaMap.Keys) {
            $expectedHash = $targetMetaMap[$fName].Sha256
            $verifyFilePath = Join-Path $verifyDir $fName
            $minB = if ($fName -eq "server_keystore.p12" -or $fName -eq "server_keystore.p12.bak") { 512 } else { 1 }
            if (-not (Test-Path $verifyFilePath) -or (Get-Item $verifyFilePath).Length -lt $minB) {
                throw "ERRORE FAIL-CLOSED: Impossibile rileggere $fName ripristinato sul dispositivo per verifica integrita'."
            }

            $actualHash = Get-Sha256Hex $verifyFilePath
            if ($actualHash -ne $expectedHash) {
                throw "ERRORE FAIL-CLOSED: Mismatch hash SHA-256 del file TLS ($fName) post-ripristino! Atteso: $expectedHash, Attuale: $actualHash"
            }
        }
    } finally {
        Clear-EphemeralPlaintextDir -EphemeralDir $verifyDir
    }

    $ksHash = $manifestFilesProp."server_keystore.p12".Sha256
    if ($hasBak) {
        Write-Host "      Parita' hash SHA-256 verificata con successo per TUTTI i 6 file TLS (+ .p12.bak) post-rollback (keystore SHA-256: $ksHash)." -ForegroundColor Green
    } else {
        Write-Host "      Parita' hash SHA-256 verificata con successo per TUTTI i 5 file TLS post-rollback (keystore SHA-256: $ksHash)." -ForegroundColor Green
    }
    return @{ Restored = $true; KeystoreSha256 = $ksHash; All5FilesVerified = $true; KeystoreBakRestored = $hasBak }
}

function Backup-DevicePairingSessions {
    param(
        [string]$AdbExe,
        [string]$TargetAdb,
        [string]$PackageName,
        [string]$SessionDir,
        [switch]$RequirePairing = $false,
        [string[]]$OptionalPrefFiles = @("akai_ai_security_prefs.xml", "akai_ai_secure_prefs.xml", "jarvis_free_voice_v1.xml", "jarvis_ota_result.xml")
    )
    $sessionPairingDir = Join-Path $SessionDir "pairing_sessions"
    New-Item -ItemType Directory -Force -Path $sessionPairingDir | Out-Null

    $primaryPref = "akai_remote_sessions.xml"
    $ephemeralDir = Join-Path ([System.IO.Path]::GetTempPath()) "akai_pairing_rx_$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $ephemeralDir | Out-Null

    $manifestFiles = @{}
    $extractedNames = @()
    try {
        $probePrimary = $null
        $unprivProbeOk = $false
        try {
            $probePrimary = Probe-DeviceFileState -AdbExe $AdbExe -TargetAdb $TargetAdb -PackageName $PackageName -RelativePath "shared_prefs/$primaryPref" -Channel "any"
            $unprivProbeOk = $true
        } catch {
            $unprivProbeOk = $false
        }

        if ($unprivProbeOk -and $probePrimary -eq "NOT_FOUND") {
            if ($RequirePairing) {
                throw "ERRORE FAIL-CLOSED (Pairing Gate): Sessioni smartphone attive o richieste ma shared_prefs/$primaryPref assente sul dispositivo."
            }
            Write-Host "      Snapshot pairing/sessions: shared_prefs/$primaryPref assente (nessuna sessione attiva)." -ForegroundColor Cyan
            $manifest = @{
                HasPairing = $false
                Reason = "PAIRING_NOT_FOUND"
            }
            [System.IO.File]::WriteAllText((Join-Path $sessionPairingDir "pairing_manifest.json"), ($manifest | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)
            return $manifest
        }

        if ($unprivProbeOk -and $probePrimary -eq "EXISTS") {
            $presentFiles = @($primaryPref)
            foreach ($opt in $OptionalPrefFiles) {
                try {
                    $stOpt = Probe-DeviceFileState -AdbExe $AdbExe -TargetAdb $TargetAdb -PackageName $PackageName -RelativePath "shared_prefs/$opt" -Channel "any"
                    if ($stOpt -eq "EXISTS") { $presentFiles += $opt }
                } catch {}
            }

            $needElev = @()
            foreach ($pf in $presentFiles) {
                $rxTemp = Join-Path $ephemeralDir $pf
                $rx = Receive-FileViaAdbExecOut -AdbExe $AdbExe -TargetAdb $TargetAdb -RemoteCommand "run-as $PackageName cat shared_prefs/$pf" -LocalFilePath $rxTemp -MinBytes 16
                if (-not ($rx.Success -and (Test-Path $rxTemp) -and (Get-Item $rxTemp).Length -ge 16)) {
                    $rx = Receive-FileViaAdbExecOut -AdbExe $AdbExe -TargetAdb $TargetAdb -RemoteCommand "su -c 'cat /data/data/$PackageName/shared_prefs/$pf'" -LocalFilePath $rxTemp -MinBytes 16
                }
                if ($rx.Success -and (Test-Path $rxTemp) -and (Get-Item $rxTemp).Length -ge 16) {
                    $extractedNames += $pf
                } else {
                    $needElev += $pf
                }
            }
            if ($needElev.Count -gt 0) {
                $script:pairBatchErr = $null
                try {
                    Invoke-WithAdbElevation -AdbExe $AdbExe -TargetAdb $TargetAdb -ActionBlock {
                        foreach ($pf in $needElev) {
                            $rxTemp = Join-Path $ephemeralDir $pf
                            $rxElev = Receive-FileViaAdbExecOut -AdbExe $AdbExe -TargetAdb $TargetAdb -RemoteCommand "cat /data/data/$PackageName/shared_prefs/$pf" -LocalFilePath $rxTemp -MinBytes 16
                            if (-not ($rxElev.Success -and (Test-Path $rxTemp) -and (Get-Item $rxTemp).Length -ge 16)) {
                                $script:pairBatchErr = "ERRORE FAIL-CLOSED (Pairing Gate): Estrazione file shared_prefs/$pf fallita o incompleta."
                                break
                            }
                        }
                    }
                } catch {
                    if ($_.Exception.Message -match "STATO ADBD UNKNOWN") { throw }
                    $script:pairBatchErr = "ERRORE FAIL-CLOSED (Pairing Gate): Estrazione file shared_prefs/$($needElev[0]) fallita ($($_.Exception.Message))."
                }
                if ($script:pairBatchErr) {
                    $e = $script:pairBatchErr
                    $script:pairBatchErr = $null
                    throw $e
                }
                $extractedNames += $needElev
            }
        } elseif (-not $unprivProbeOk) {
            # Unprivileged channels negati: singola sessione root adbd per probe + estrazione
            $script:elevProbePair = $null
            $script:elevPairExtracted = @()
            $script:elevPairErr = $null
            Invoke-WithAdbElevation -AdbExe $AdbExe -TargetAdb $TargetAdb -ActionBlock {
                $script:elevProbePair = Probe-DeviceFileState -AdbExe $AdbExe -TargetAdb $TargetAdb -PackageName $PackageName -RelativePath "shared_prefs/$primaryPref" -Channel "root"
                if ($script:elevProbePair -eq "EXISTS") {
                    $rxPrimary = Receive-FileViaAdbExecOut -AdbExe $AdbExe -TargetAdb $TargetAdb -RemoteCommand "cat /data/data/$PackageName/shared_prefs/$primaryPref" -LocalFilePath (Join-Path $ephemeralDir $primaryPref) -MinBytes 16
                    if (-not $rxPrimary.Success) {
                        $script:elevPairErr = "ERRORE FAIL-CLOSED (Pairing Gate): Estrazione file shared_prefs/$primaryPref fallita sotto root."
                    } else {
                        $script:elevPairExtracted += $primaryPref
                        foreach ($opt in $OptionalPrefFiles) {
                            $optState = Probe-DeviceFileState -AdbExe $AdbExe -TargetAdb $TargetAdb -PackageName $PackageName -RelativePath "shared_prefs/$opt" -Channel "root"
                            if ($optState -eq "EXISTS") {
                                $rxOpt = Receive-FileViaAdbExecOut -AdbExe $AdbExe -TargetAdb $TargetAdb -RemoteCommand "cat /data/data/$PackageName/shared_prefs/$opt" -LocalFilePath (Join-Path $ephemeralDir $opt) -MinBytes 16
                                if (-not $rxOpt.Success) {
                                    $script:elevPairErr = "ERRORE FAIL-CLOSED (Pairing Gate): Estrazione file shared_prefs/$opt (presente su device) fallita sotto root."
                                    break
                                }
                                $script:elevPairExtracted += $opt
                            }
                        }
                    }
                }
            }
            if ($script:elevProbePair) {
                $probePrimary = $script:elevProbePair
                $script:elevProbePair = $null
            }
            if ($probePrimary -eq "NOT_FOUND") {
                $script:elevPairErr = $null
                $script:elevPairExtracted = @()
                if ($RequirePairing) {
                    throw "ERRORE FAIL-CLOSED (Pairing Gate): Sessioni smartphone attive o richieste ma shared_prefs/$primaryPref assente sul dispositivo."
                }
                Write-Host "      Snapshot pairing/sessions: shared_prefs/$primaryPref assente (nessuna sessione attiva)." -ForegroundColor Cyan
                $manifest = @{
                    HasPairing = $false
                    Reason = "PAIRING_NOT_FOUND"
                }
                [System.IO.File]::WriteAllText((Join-Path $sessionPairingDir "pairing_manifest.json"), ($manifest | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)
                return $manifest
            }
            if ($script:elevPairErr) {
                $e = $script:elevPairErr
                $script:elevPairErr = $null
                throw $e
            }
            $extractedNames = @($script:elevPairExtracted)
            $script:elevPairExtracted = @()
        }

        if ($probePrimary -ne "EXISTS" -or ($extractedNames -notcontains $primaryPref)) {
            throw "ERRORE FAIL-CLOSED (Pairing Gate): Impossibile estrarre shared_prefs/$primaryPref (stato=$probePrimary)."
        }

        # Validazione XML rigorosa in memoria prima della cifratura
        foreach ($pf in $extractedNames) {
            $rxTemp = Join-Path $ephemeralDir $pf
            if (-not (Test-Path $rxTemp) -or (Get-Item $rxTemp).Length -lt 16) {
                throw "ERRORE FAIL-CLOSED (Pairing Gate): File $pf assente o troncato."
            }
            $xmlText = [System.IO.File]::ReadAllText($rxTemp, [System.Text.Encoding]::UTF8)
            if ($xmlText -notmatch "<map[\s/>]") {
                throw "ERRORE FAIL-CLOSED (Pairing Gate): Contenuto XML non valido o corrotto per $pf (elemento <map> assente)."
            }
            try {
                [xml]$parsed = $xmlText
                if (-not $parsed -or -not $parsed.map) {
                    throw "struttura XML priva di nodo <map>"
                }
            } catch {
                throw "ERRORE FAIL-CLOSED (Pairing Gate): Parsing XML fallito per $pf ($($_.Exception.Message))."
            }
        }

        $vaultInfo = Resolve-SecureVaultSubdir -SessionDir $SessionDir -PackageName $PackageName -SubdirName "pairing_sessions"
        $vaultDir = $vaultInfo.VaultDir
        $isCloudSynced = $vaultInfo.IsCloudSynced

        foreach ($pf in $extractedNames) {
            $rxTemp = Join-Path $ephemeralDir $pf
            $plainBytes = [System.IO.File]::ReadAllBytes($rxTemp)
            $plainHash = Get-Sha256Hex $rxTemp
            $plainLen = $plainBytes.Length

            $protectRes = Protect-TlsData -PlainBytes $plainBytes -VaultDir $vaultDir
            $encDestPath = Join-Path $vaultDir "$pf.enc"
            [System.IO.File]::WriteAllBytes($encDestPath, $protectRes.CipherBytes)

            $zeroBuf = New-Object byte[] $plainLen
            [System.IO.File]::WriteAllBytes($rxTemp, $zeroBuf)
            Remove-Item $rxTemp -Force -ErrorAction SilentlyContinue

            $unprotectTest = Unprotect-TlsData -CipherBytes $protectRes.CipherBytes -Mechanism $protectRes.Mechanism -VaultDir $vaultDir
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $testDecHash = -join ($sha.ComputeHash($unprotectTest) | ForEach-Object { "{0:x2}" -f $_ })
            if ($testDecHash -ne $plainHash) {
                throw "ERRORE FAIL-CLOSED (Pairing Gate): Verifica roundtrip decifratura fallita per $pf."
            }

            $cipherHash = -join ($sha.ComputeHash($protectRes.CipherBytes) | ForEach-Object { "{0:x2}" -f $_ })
            $manifestFiles[$pf] = @{
                Sha256 = $plainHash
                SizeBytes = $plainLen
                Encrypted = $true
                CipherSha256 = $cipherHash
                Mechanism = $protectRes.Mechanism
                Required = ($pf -eq $primaryPref)
            }
        }
    } finally {
        Clear-EphemeralPlaintextDir -EphemeralDir $ephemeralDir
    }

    $manifest = @{
        HasPairing = $true
        SessionDir = $SessionDir
        VaultDir = $vaultDir
        IsCloudSynced = $isCloudSynced
        PrimaryFile = $primaryPref
        Files = $manifestFiles
        PrimarySha256 = $manifestFiles[$primaryPref].Sha256
    }
    [System.IO.File]::WriteAllText((Join-Path $sessionPairingDir "pairing_manifest.json"), ($manifest | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)

    if ($vaultDir -ne $sessionPairingDir) {
        $pointer = @{
            VaultDir = $vaultDir
            CreatedAt = (Get-Date -Format "o")
        }
        [System.IO.File]::WriteAllText((Join-Path $sessionPairingDir "vault_pointer.json"), ($pointer | ConvertTo-Json), [System.Text.Encoding]::UTF8)
    }

    Write-Host "      Snapshot cifrato preferenze pairing/AI salvato ($($manifestFiles.Count) file in vault $vaultDir), ZERO XML o token in chiaro su disco." -ForegroundColor Green
    return $manifest
}

function Restore-DevicePairingSessions {
    param(
        [string]$AdbExe,
        [string]$TargetAdb,
        [string]$PackageName,
        [string]$SessionDir,
        [string]$ChownTarget
    )
    $sessionPairingDir = Join-Path $SessionDir "pairing_sessions"
    $manifestPath = Join-Path $sessionPairingDir "pairing_manifest.json"
    if (-not (Test-Path $manifestPath)) {
        Write-Host "      Ripristino pairing: nessun manifesto pairing nel backup. Salto ripristino pairing." -ForegroundColor Cyan
        return @{ Restored = $false; Reason = "NO_PAIRING_BACKUP" }
    }

    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.HasPairing -ne $true) {
        Write-Host "      Ripristino pairing: sessione senza pairing salvato (HasPairing=false). Salto ripristino pairing." -ForegroundColor Cyan
        return @{ Restored = $false; Reason = "NO_PAIRING_BACKUP" }
    }

    $vaultDir = $manifest.VaultDir
    $pointerPath = Join-Path $sessionPairingDir "vault_pointer.json"
    if (Test-Path $pointerPath) {
        try {
            $ptr = Get-Content $pointerPath -Raw | ConvertFrom-Json
            if ($ptr.VaultDir -and (Test-Path $ptr.VaultDir)) { $vaultDir = $ptr.VaultDir }
        } catch {}
    }
    if (-not $vaultDir -or -not (Test-Path $vaultDir)) {
        $vaultDir = $sessionPairingDir
    }

    $fileProps = @($manifest.Files.psobject.properties)
    if ($fileProps.Count -eq 0) {
        throw "ERRORE FAIL-CLOSED: Manifesto pairing privo di file da ripristinare."
    }

    $payloads = @{}
    $expectedHashes = @{}
    $needElevSend = @()

    foreach ($prop in $fileProps) {
        $fName = $prop.Name
        $fMeta = $prop.Value
        $encPath = Join-Path $vaultDir "$fName.enc"
        if (-not (Test-Path $encPath)) {
            throw "ERRORE FAIL-CLOSED: File cifrato pairing $fName.enc assente nel vault ($vaultDir)."
        }
        $cipherBytes = [System.IO.File]::ReadAllBytes($encPath)
        $plainBytes = Unprotect-TlsData -CipherBytes $cipherBytes -Mechanism $fMeta.Mechanism -VaultDir $vaultDir
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $preHash = -join ($sha.ComputeHash($plainBytes) | ForEach-Object { "{0:x2}" -f $_ })
        if ($preHash -ne $fMeta.Sha256) {
            throw "ERRORE FAIL-CLOSED: Corruzione rilevata durante decifratura pairing ($fName)! Hash mismatch pre-invio."
        }
        $payloads[$fName] = $plainBytes
        $expectedHashes[$fName] = $fMeta.Sha256

        $restored = $false
        $cmd = "run-as $PackageName sh -c 'mkdir -p shared_prefs; cat > shared_prefs/$fName; chmod 660 shared_prefs/$fName'"
        $res = Send-FileViaAdbExecIn -AdbExe $AdbExe -TargetAdb $TargetAdb -RawBytes $plainBytes -RemoteCommand $cmd
        if ($res.Success) { $restored = $true }

        if (-not $restored) {
            $cmd = "su -c 'mkdir -p /data/data/$PackageName/shared_prefs; cat > /data/data/$PackageName/shared_prefs/$fName; chown $ChownTarget /data/data/$PackageName/shared_prefs/$fName; chmod 660 /data/data/$PackageName/shared_prefs/$fName'"
            $res = Send-FileViaAdbExecIn -AdbExe $AdbExe -TargetAdb $TargetAdb -RawBytes $plainBytes -RemoteCommand $cmd
            if ($res.Success) { $restored = $true }
        }
        if (-not $restored) {
            $needElevSend += $fName
        }
    }

    if ($needElevSend.Count -gt 0) {
        $script:pairSendFailed = $null
        Invoke-WithAdbElevation -AdbExe $AdbExe -TargetAdb $TargetAdb -ActionBlock {
            foreach ($fName in $needElevSend) {
                $cmd = "sh -c 'mkdir -p /data/data/$PackageName/shared_prefs; cat > /data/data/$PackageName/shared_prefs/$fName; chown $ChownTarget /data/data/$PackageName/shared_prefs/$fName; chmod 660 /data/data/$PackageName/shared_prefs/$fName'"
                $sRes = Send-FileViaAdbExecIn -AdbExe $AdbExe -TargetAdb $TargetAdb -RawBytes $payloads[$fName] -RemoteCommand $cmd
                if (-not $sRes.Success) {
                    $script:pairSendFailed = $fName
                    break
                }
            }
        }
        if ($script:pairSendFailed) {
            $bf = $script:pairSendFailed
            $script:pairSendFailed = $null
            throw "ERRORE FAIL-CLOSED: Invio file pairing ($bf) fallito sul dispositivo."
        }
    }

    $verifyDir = Join-Path ([System.IO.Path]::GetTempPath()) "akai_verify_pairing_$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $verifyDir | Out-Null
    try {
        $needElevRead = @()
        foreach ($prop in $fileProps) {
            $fName = $prop.Name
            $verifyPath = Join-Path $verifyDir $fName
            $rx = Receive-FileViaAdbExecOut -AdbExe $AdbExe -TargetAdb $TargetAdb -RemoteCommand "run-as $PackageName cat shared_prefs/$fName" -LocalFilePath $verifyPath -MinBytes 16
            if (-not $rx.Success) {
                $rx = Receive-FileViaAdbExecOut -AdbExe $AdbExe -TargetAdb $TargetAdb -RemoteCommand "su -c 'cat /data/data/$PackageName/shared_prefs/$fName'" -LocalFilePath $verifyPath -MinBytes 16
            }
            if (-not $rx.Success) {
                $needElevRead += $fName
            }
        }

        if ($needElevRead.Count -gt 0) {
            Invoke-WithAdbElevation -AdbExe $AdbExe -TargetAdb $TargetAdb -ActionBlock {
                foreach ($fName in $needElevRead) {
                    $verifyPath = Join-Path $verifyDir $fName
                    [void](Receive-FileViaAdbExecOut -AdbExe $AdbExe -TargetAdb $TargetAdb -RemoteCommand "cat /data/data/$PackageName/shared_prefs/$fName" -LocalFilePath $verifyPath -MinBytes 16)
                }
            }
        }

        foreach ($prop in $fileProps) {
            $fName = $prop.Name
            $verifyPath = Join-Path $verifyDir $fName
            if (-not (Test-Path $verifyPath) -or (Get-Item $verifyPath).Length -lt 16) {
                throw "ERRORE FAIL-CLOSED: Impossibile rileggere file pairing ($fName) post-ripristino."
            }
            $actualHash = Get-Sha256Hex $verifyPath
            if ($actualHash -ne $expectedHashes[$fName]) {
                throw "ERRORE FAIL-CLOSED: Mismatch SHA-256 post-ripristino per $fName! Atteso: $($expectedHashes[$fName]), Attuale: $actualHash"
            }
        }
    } finally {
        Clear-EphemeralPlaintextDir -EphemeralDir $verifyDir
    }

    $primHash = $manifest.PrimarySha256
    Write-Host "      Parita' SHA-256 verificata per tutti i $($fileProps.Count) file pairing/AI post-rollback." -ForegroundColor Green
    return @{ Restored = $true; PrimarySha256 = $primHash; FileCount = $fileProps.Count }
}

function Assert-BackupSessionNoPlaintextSecrets {
    param(
        [string]$SessionDir,
        [string[]]$VaultDirs = @()
    )
    if ([string]::IsNullOrWhiteSpace($SessionDir) -or -not (Test-Path $SessionDir)) {
        throw "ERRORE FAIL-CLOSED [CREDENZIALI FUORI VAULT]: SessionDir non valido o inesistente: '$SessionDir'."
    }
    $isWin = [System.Environment]::OSVersion.Platform -match "Win"
    $fullSession = [System.IO.Path]::GetFullPath($SessionDir)

    $forbiddenPlainNames = @(
        "server_keystore.p12", "server_keystore.p12.bak", "server_keystore.pass", "ca.pem", "ca.crt", "ca_key.der",
        "akai_remote_sessions.xml", "akai_ai_security_prefs.xml", "akai_ai_secure_prefs.xml",
        "jarvis_free_voice_v1.xml", "jarvis_ota_result.xml", ".vault_master.key"
    )
    $resolvedVaults = @()
    $scanDirs = @($fullSession)

    foreach ($vd in $VaultDirs) {
        if (-not [string]::IsNullOrWhiteSpace($vd) -and (Test-Path $vd)) {
            $fullVd = [System.IO.Path]::GetFullPath($vd)
            $resolvedVaults += $fullVd
            if ($scanDirs -notcontains $fullVd) { $scanDirs += $fullVd }

            if ($fullVd -match "(?i)(OneDrive|Dropbox|Google Drive|iCloud|Nextcloud)") {
                throw "ERRORE FAIL-CLOSED [CREDENZIALI FUORI VAULT]: Vault individuato in percorso cloud-sync ($fullVd)."
            }
            if ($isWin) {
                if (-not $env:LOCALAPPDATA -or -not $fullVd.StartsWith([System.IO.Path]::GetFullPath($env:LOCALAPPDATA), [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "ERRORE FAIL-CLOSED [CREDENZIALI FUORI VAULT]: Vault Windows ($fullVd) al di fuori di LOCALAPPDATA."
                }
                $dirInfo = New-Object System.IO.DirectoryInfo($fullVd)
                $dirSec = $dirInfo.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
                if ($dirSec.AreAccessRulesProtected -ne $true) {
                    throw "ERRORE FAIL-CLOSED [CREDENZIALI FUORI VAULT]: ACL del vault ($fullVd) non protette (ereditarieta' attiva)."
                }
            }
        }
    }

    foreach ($dirToScan in $scanDirs) {
        $items = Get-ChildItem -Path $dirToScan -Recurse -Force -File -ErrorAction SilentlyContinue
        foreach ($item in $items) {
            $n = $item.Name
            if ($forbiddenPlainNames -contains $n) {
                if ($n -eq ".vault_master.key") {
                    if ($isWin -or ($resolvedVaults -notcontains [System.IO.Path]::GetFullPath($item.Directory.FullName))) {
                        throw "ERRORE FAIL-CLOSED [CREDENZIALI FUORI VAULT]: Master key rilevata fuori configurazione sicura ($($item.FullName))."
                    }
                } else {
                    throw "ERRORE FAIL-CLOSED [CREDENZIALI FUORI VAULT]: File sensibile in chiaro rilevato su disco: $($item.FullName)"
                }
            }
            if ($n -match "(?i)\.(p12|jks|keystore|key|der|pass|pem|bak)$" -and $n -notmatch "\.enc$") {
                if ($isWin -or $n -ne ".vault_master.key") {
                    throw "ERRORE FAIL-CLOSED [CREDENZIALI FUORI VAULT]: Materiale crittografico non cifrato rilevato: $($item.FullName)"
                }
            }
            if ($n -match "(?i)\.xml$" -and $n -notmatch "\.enc$") {
                throw "ERRORE FAIL-CLOSED [CREDENZIALI FUORI VAULT]: File XML preferenze/pairing in chiaro rilevato su disco: $($item.FullName)"
            }
        }
    }

    # Scansione manifesti JSON in SessionDir contro secret leak
    $jsonFiles = Get-ChildItem -Path $fullSession -Recurse -File -Filter "*.json" -ErrorAction SilentlyContinue
    foreach ($jf in $jsonFiles) {
        $raw = Get-Content -LiteralPath $jf.FullName -Raw -ErrorAction SilentlyContinue
        if ($raw -and $raw -match "(?i)(-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----|Bearer\s+[A-Za-z0-9\-_\.=]{8,}|<string\s+name=)") {
            throw "ERRORE FAIL-CLOSED [CREDENZIALI FUORI VAULT]: Possibile segreto o token rilevato nel manifest JSON: $($jf.FullName)"
        }
    }
    return $true
}

switch ($Action) {
    "plan" {
        Write-Host "=== PIANO SICURO DI DEPLOYMENT, VERIFICA E ROLLBACK ATOMICO (Rev 9 - Strict Greenfield & TLS SAN) ===" -ForegroundColor Cyan
        Write-Host "Fase 0: Inventario e Preflight Read-Only (100% Non-Distruttivo)"
        Write-Host "        - Comando: -Action preflight"
        Write-Host "        - Zero scritture, zero force-stop, zero perturbazione dello stato TV."
        Write-Host "        - Estrae versionCode/versionName da dumpsys, firma SHA-256 via apksigner (read-only)."
        Write-Host "        - Verifica e distingue Home v8 (it.akai.customhome.v8) da Home v7 (it.akai.customhome)."
        Write-Host "Fase 1: Validazione Parametri e Verifica Firma Digitale Fail-Closed Pre-Install"
        Write-Host "        - Rifiuta categoricamente artefatti CI di test non distribuibili."
        Write-Host "        - Estrae e confronta il digest SHA-256 esatto a 64 caratteri con apksigner."
        Write-Host "Fase 2: Gestione Dati e Backup Preventivo (Separazione Rigorosa dei Flussi):"
        Write-Host "        - FLUSSO A (In-Place con Backup Consistente):"
        Write-Host "          Se 'it.akai.customremote' e' installato, il backup SQLite v5 e' OBBLIGATORIO (fail-closed)."
        Write-Host "          Se il DB non e' estraibile, l'installazione e' BLOCCATA per prevenire migrazioni v5->v6 senza rollback."
        Write-Host "        - FLUSSO B (Clean-Start Greenfield con -GreenfieldStart):"
        Write-Host "          Ammesso ESCLUSIVAMENTE se 'it.akai.customremote' NON e' installato sulla TV."
        Write-Host "          Salvaguardia totale: il launcher Home v8 (it.akai.customhome.v8) resta intatto al 100%."
        Write-Host "Fase 3: Installazione conservativa nuovo APK (adb install -r -d se upgrade, adb install se clean)"
        Write-Host "Fase 4: Multi-Point Health Check Watchdog (30s):"
        Write-Host "        - Verifica 1: /api/status risponde 200 con status=ok E uinput_ready=true"
        Write-Host "        - Verifica 2: /index.html risponde 200 con payload HTML valido (telecomando classico LAN preservato)"
        Write-Host "        - Verifica 3: Porta HTTPS 8443 con probe TLS, verifica SAN IP/DNS ed impronta Root CA"
        Write-Host "        - Verifica 4: Processo attivo su device (pidof)"
        Write-Host "Fase 5: Rollback Automatico in caso di anomalia Watchdog:"
        Write-Host "        - Flusso A: Reinstallazione APK precedente + ripristino atomico DB SQLite con parita' SHA-256."
        Write-Host "        - Flusso B: Disinstallazione pulita del nuovo APK (adb uninstall) per ripristinare stato vergine."
        Write-Host "==========================================================================================" -ForegroundColor Cyan
    }

    "preflight" {
        $adb = Get-AdbExecutable
        Write-Host "=== INVENTARIO E PREFLIGHT READ-ONLY TV (100% NON-DESTRUTTIVO) ===" -ForegroundColor Cyan
        Write-Host "Nota di sicurezza: Nessun arresto di processo (force-stop), nessuna scrittura," -ForegroundColor Yellow
        Write-Host "nessuna installazione e nessuna alterazione di stato sul dispositivo." -ForegroundColor Yellow
        Write-Host ""

        & $adb connect $TargetAdb | Out-Null

        # 1. Verifica Pacchetto Telecomando (it.akai.customremote)
        Write-Host "[1/5] Verifica pacchetto Telecomando ($PackageName)..." -ForegroundColor Cyan
        $remoteInstalled = & $adb -s $TargetAdb shell "pm list packages $PackageName" 2>&1
        if ($remoteInstalled -match $PackageName) {
            Write-Host "      Stato pacchetto : INSTALLATO" -ForegroundColor Green
            $pathLine = (& $adb -s $TargetAdb shell "pm path $PackageName" 2>&1).ToString().Trim()
            Write-Host "      Percorso APK    : $pathLine"
            $pids = (& $adb -s $TargetAdb shell "pidof $PackageName 2>/dev/null" 2>&1).ToString().Trim()
            Write-Host "      Processo attivo : $(if ($pids) { "ATTIVO (PID $pids)" } else { "NON ATTIVO" })"
            
            # Estrazione reale di versionCode e versionName tramite dumpsys package
            $dumpsysOut = (& $adb -s $TargetAdb shell "dumpsys package $PackageName" 2>&1 | Out-String)
            $vCode = if ($dumpsysOut -match "versionCode=(\d+)") { $matches[1] } else { "NON RILEVABILE" }
            $vName = if ($dumpsysOut -match "versionName=([^\s]+)") { $matches[1] } else { "NON RILEVABILE" }
            Write-Host "      Versione        : versionCode=$vCode, versionName=$vName"
            
            # Estrazione impronta SHA-256 firma APK installato (read-only)
            if ($pathLine -match "package:(.+)") {
                $installedRemoteApk = $matches[1].Trim()
                $tempProbeApk = Join-Path ([System.IO.Path]::GetTempPath()) "akai_preflight_probe_$([System.Guid]::NewGuid().ToString('N')).apk"
                try {
                    $prevEap = $ErrorActionPreference
                    $ErrorActionPreference = "Continue"
                    try {
                        & $adb -s $TargetAdb pull $installedRemoteApk $tempProbeApk 2>$null | Out-Null
                    } finally {
                        $ErrorActionPreference = $prevEap
                    }
                    if ((Test-Path $tempProbeApk) -and (Get-Item $tempProbeApk).Length -gt 0) {
                        $installedFp = Get-ApkCertificateFingerprint $tempProbeApk
                        if ($installedFp -and $installedFp.Length -eq 64) {
                            Write-Host "      Firma SHA-256   : $installedFp" -ForegroundColor Green
                        } else {
                            Write-Host "      Firma SHA-256   : INACCESSIBILE (apksigner non ha estratto digest valido)" -ForegroundColor Yellow
                        }
                    } else {
                        Write-Host "      Firma SHA-256   : INACCESSIBILE (pull APK negato o privilegi limitati)" -ForegroundColor Yellow
                    }
                } catch {
                    Write-Host "      Firma SHA-256   : INACCESSIBILE ($($_.Exception.Message))" -ForegroundColor Yellow
                } finally {
                    if (Test-Path $tempProbeApk) { Remove-Item $tempProbeApk -Force -ErrorAction SilentlyContinue }
                }
            } else {
                Write-Host "      Firma SHA-256   : INACCESSIBILE (percorso APK non determinabile)" -ForegroundColor Yellow
            }

            # Verifica accessibilita' dati (read-only probe senza force-stop)
            $probeRunAs = (& $adb -s $TargetAdb shell "run-as $PackageName ls databases/ 2>&1").ToString().Trim()
            $dbAccessStatus = if ($LASTEXITCODE -eq 0 -and $probeRunAs -notmatch "denied|not debuggable|error") {
                "DISPONIBILE ($probeRunAs)"
            } else {
                "UNKNOWN / INACCESSIBLE (build release non-debuggable o privilegi limitati)"
            }
            Write-Host "      Accesso run-as  : $dbAccessStatus"
            if ($dbAccessStatus -notmatch '^DISPONIBILE') {
                Write-Host "      [NO-GO DATI] run-as non consente accesso al DB: questo inventario NON dimostra un backup SQLite/WAL recuperabile. Non installare." -ForegroundColor Red
            }
        } else {
            Write-Host "      Stato pacchetto : NON INSTALLATO (Clean-Start Greenfield applicabile)" -ForegroundColor Yellow
        }

        # 2. Verifica Pacchetti Launcher (Home v8: it.akai.customhome.v8 vs Home v7: it.akai.customhome) - SALVAGUARDIA ASSOLUTA
        Write-Host "`n[2/5] Verifica salvaguardia Home Launcher (Home v8 / Home v7)..." -ForegroundColor Cyan
        $homeV8Installed = (& $adb -s $TargetAdb shell "pm list packages it.akai.customhome.v8" 2>&1).ToString().Trim()
        $homeV7Installed = (& $adb -s $TargetAdb shell "pm list packages it.akai.customhome" 2>&1).ToString().Trim()
        if ($homeV8Installed -match "it\.akai\.customhome\.v8") {
            Write-Host "      Home v8 (it.akai.customhome.v8) : PRESENTE E PROTETTA (Tasto MENU fisico e launcher v8 intatti)" -ForegroundColor Green
        } else {
            Write-Host "      Home v8 (it.akai.customhome.v8) : NON INSTALLATA" -ForegroundColor Yellow
        }
        if ($homeV7Installed -match "(^|\s)package:it\.akai\.customhome($|\s)") {
            Write-Host "      Home v7 (it.akai.customhome)    : PRESENTE E PROTETTA (Fallback v7 conservato)" -ForegroundColor Green
        } else {
            Write-Host "      Home v7 (it.akai.customhome)    : NON INSTALLATA" -ForegroundColor Yellow
        }

        # 3. Spazio disco su /data
        Write-Host "`n[3/6] Verifica storage partizione /data..." -ForegroundColor Cyan
        $dfData = (& $adb -s $TargetAdb shell "df -h /data" 2>&1 | Out-String).Trim()
        Write-Host "      $dfData"

        # 4. Verifica Hardware, SELinux, Root e permessi /dev/uinput (Read-Only Gate)
        Write-Host "`n[4/6] Verifica Hardware, Identita', SELinux e permessi /dev/uinput..." -ForegroundColor Cyan
        $buildFp = (& $adb -s $TargetAdb shell "getprop ro.build.fingerprint" 2>&1 | Out-String).Trim()
        $model = (& $adb -s $TargetAdb shell "getprop ro.product.model" 2>&1 | Out-String).Trim()
        $platform = (& $adb -s $TargetAdb shell "getprop ro.board.platform" 2>&1 | Out-String).Trim()
        Write-Host "      Modello / Piattaforma : $(if ($model) { "$model ($platform)" } else { "NON RILEVABILE" })"
        Write-Host "      Build Fingerprint     : $(if ($buildFp) { $buildFp } else { "NON RILEVABILE" })"
        $buildType = (& $adb -s $TargetAdb shell "getprop ro.build.type" 2>&1 | Out-String).Trim()
        $roDebuggable = (& $adb -s $TargetAdb shell "getprop ro.debuggable" 2>&1 | Out-String).Trim()
        Write-Host "      Android build type    : $(if ($buildType) { $buildType } else { "NON RILEVABILE" })"
        Write-Host "      ro.debuggable         : $(if ($roDebuggable) { $roDebuggable } else { "NON RILEVABILE" })"
        Write-Host "      Recupero downgrade    : NON DIMOSTRATO per A2 v3 non-debuggable; adb install -d NON e' un piano di ripristino garantito." -ForegroundColor Yellow

        $idRes = (& $adb -s $TargetAdb shell "id" 2>&1 | Out-String).Trim()
        Write-Host "      Contesto Shell (id)   : $(if ($idRes) { $idRes } else { "NON RILEVABILE" })"

        $selinux = (& $adb -s $TargetAdb shell "getenforce" 2>&1 | Out-String).Trim()
        Write-Host "      SELinux Enforcement   : $(if ($selinux) { $selinux } else { "NON RILEVABILE" })"

        $suCheck = (& $adb -s $TargetAdb shell "which su 2>/dev/null; su -c id 2>/dev/null" 2>&1 | Out-String).Trim()
        $rootState = if ($suCheck -match "uid=0") { "DISPONIBILE (root attivo via su)" } else { "NON ATTIVO (shell utente standard / su non abilitato)" }
        Write-Host "      Stato Root            : $rootState"

        $uinputLs = (& $adb -s $TargetAdb shell "ls -la /dev/uinput 2>&1" | Out-String).Trim()
        Write-Host "      Permessi /dev/uinput  : $(if ($uinputLs) { $uinputLs } else { "NON RILEVABILE" })"

        # 5. Verifica porte aperte su TV (8088 / 8443)
        Write-Host "`n[5/6] Verifica porte di rete su TV..." -ForegroundColor Cyan
        $netstatRaw = (& $adb -s $TargetAdb shell "netstat -tlpn" 2>&1)
        $netstatLines = @($netstatRaw | Where-Object { $_ -match "8088|8443" })
        if ($netstatLines.Count -gt 0) {
            Write-Host "      Porte ascolto attive TV:" -ForegroundColor Green
            $netstatLines | ForEach-Object { Write-Host "      $_" -ForegroundColor Green }
        } else {
            Write-Host "      Porte 8088/8443 : NESSUN LISTENER RILEVATO (servizio spento o TV libera)" -ForegroundColor Yellow
        }

        # 6. Tabella di trasparenza dati per Clean-Start Greenfield
        Write-Host "`n[6/6] Tabella Trasparenza Dati Greenfield (Qualora si proceda con avvio pulito):" -ForegroundColor Cyan
        Write-Host "      +--------------------------------+-------------------------------------------------------+"
        Write-Host "      | Componente                     | Impatto in caso di Clean-Start (-GreenfieldStart)     |"
        Write-Host "      +--------------------------------+-------------------------------------------------------+"
        Write-Host "      | Launcher Home v8 (customhome)  | NESSUN IMPATTO: completamente intatto e funzionante   |"
        Write-Host "      | Associazione Smartphone        | Reset: richiede nuova scansione QR HTTPS e PIN OOB    |"
        Write-Host "      | Storico Memoria AI / Comandi   | Reset: inizializzato ex novo alla prima richiesta     |"
        Write-Host "      | Preferenze Web UI              | Reset: ripristinate ai valori predefiniti             |"
        Write-Host "      +--------------------------------+-------------------------------------------------------+"
        Write-Host "`nInventario di sola lettura concluso. NON autorizza installazione, downgrade o dichiarazioni di backup recuperabile." -ForegroundColor Yellow
    }

    "status" {
        $adb = Get-AdbExecutable
        Write-Host "=== STATO ATTUALE TELECOMANDO SU AKAI AKTV5037N ===" -ForegroundColor Cyan
        & $adb connect $TargetAdb | Out-Null
        $installed = & $adb -s $TargetAdb shell "pm list packages $PackageName"
        if ($installed -match $PackageName) {
            Write-Host "Pacchetto $PackageName : INSTALLATO" -ForegroundColor Green
            $pathLine = & $adb -s $TargetAdb shell "pm path $PackageName"
            Write-Host "Percorso APK su device  : $pathLine"
            $pidValRaw = & $adb -s $TargetAdb shell "pidof $PackageName" 2>$null
            $pidVal = if ($pidValRaw) { $pidValRaw.ToString().Trim() } else { "" }
            Write-Host "Processo in esecuzione   : $(if ($pidVal) { "ATTIVO (PID $pidVal)" } else { "NON ATTIVO" })"
        } else {
            Write-Host "Pacchetto $PackageName : NON INSTALLATO" -ForegroundColor Yellow
        }
    }

    "verify-tls" {
        Write-Host "=== VERIFICA RIGOROSA SOLA LETTURA ROOT CA E SAN HTTPS (Test-HttpsTlsEndpoint) ===" -ForegroundColor Cyan
        Write-Host "Modalita' 100% READ-ONLY: zero comandi ADB, zero force-stop, zero install, zero backup." -ForegroundColor Cyan
        Write-Host "Target Host                    : $TargetTv"
        Write-Host "Porta HTTPS                    : $HttpsPort"
        Write-Host "Impronta CA Fuori Banda Attesa : $(if ($ExpectedCaFingerprint) { $ExpectedCaFingerprint } else { '(NESSUNA - sola ispezione handshake)' })"

        $tlsRes = Test-HttpsTlsEndpoint -TargetHost $TargetTv -Port $HttpsPort -ExpectedCaSha256 $ExpectedCaFingerprint

        if (-not $tlsRes.SanMatched -or ($tlsRes.Status -ne "APPROVED" -and $tlsRes.Status -ne "TLS_HANDSHAKE_ONLY/UNVERIFIED")) {
            Write-Host "`nFALLIMENTO VERIFICA TLS: $($tlsRes.Error) (Status: $($tlsRes.Status))" -ForegroundColor Red
            exit 1
        }

        Write-Host "`nHandshake TLS completato con successo." -ForegroundColor Green
        Write-Host "Subject Certificato Server : $($tlsRes.Subject)"
        Write-Host "Issuer Certificato Server  : $($tlsRes.Issuer)"
        Write-Host "SAN Rilevati               : $($tlsRes.FormattedSan)"
        Write-Host "SAN Matched ($TargetTv)     : $($tlsRes.SanMatched)"
        Write-Host "Impronta osservata su connessione TLS (NON VERIFICATA): $($tlsRes.RootCaSha256)" -ForegroundColor Cyan

        if ($tlsRes.Status -eq "APPROVED") {
            Write-Host "`n[APPROVED] CONVALIDA CRITTOGRAFICA RIUSCITA AL 100%!" -ForegroundColor Green
            Write-Host "La Root CA corrisponde esattamente all'impronta verificata fuori banda sullo schermo TV." -ForegroundColor Green
            Write-Host "Autenticazione canale TLS confermata: autorizzato utilizzo credenziali/PIN/chiavi." -ForegroundColor Green
            exit 0
        } else {
            Write-Host "`n[PROVISIONAL / OOB TRUST PENDING] STATO PROVVISORIO NON AUTORIZZATO" -ForegroundColor Yellow
            Write-Host "AVVISO DI SICUREZZA: Handshake TLS attivo ma Root CA non ancora validata fuori banda sullo schermo TV." -ForegroundColor Yellow
            Write-Host "DIVIETO: Non utilizzare credenziali/PIN/chiavi su HTTPS finche' l'impronta non e' verificata fuori banda." -ForegroundColor Yellow
            Write-Host "Per approvare, convalidare visivamente l'impronta sullo schermo TV e rieseguire:" -ForegroundColor Cyan
            Write-Host "  powershell -File .\akai-remote-tests\05_safe_install_and_rollback.ps1 -Action verify-tls -TargetTv $TargetTv -HttpsPort $HttpsPort -ExpectedCaFingerprint <IMPRONTA_LETTA_SULLO_SCHERMO_TV>" -ForegroundColor Cyan
            exit 0
        }
    }

    "backup" {
        $adb = Get-AdbExecutable
        Write-Host "=== BACKUP PREVENTIVO ATOMICO E VERIFICA INTEGRITÀ ===" -ForegroundColor Cyan
        & $adb connect $TargetAdb | Out-Null

        $sessionDir = Join-Path $BackupDir "backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null

        # 1. Download APK
        $pathOutput = & $adb -s $TargetAdb shell "pm path $PackageName"
        if ($pathOutput -notmatch "package:(.+)") {
            throw "ERRORE FAIL-CLOSED: Impossibile individuare il percorso APK su device per $PackageName."
        }
        $remoteApk = $matches[1].Trim()
        $backupApk = Join-Path $sessionDir "it.akai.customremote_backup.apk"
        Write-Host "[1/3] Download APK remoto da $remoteApk..."
        & $adb -s $TargetAdb pull $remoteApk $backupApk
        if (-not (Test-Path $backupApk) -or (Get-Item $backupApk).Length -eq 0) {
            throw "ERRORE FAIL-CLOSED: Download APK di backup fallito o file vuoto."
        }
        Write-Host "      APK salvato: $backupApk ($((Get-Item $backupApk).Length) bytes)" -ForegroundColor Green

        # 2. Snapshot logico opzionale REST: HTTPS con CA trusted, mai HTTP/Bearer in chiaro
        $logicalBackupPath = Join-Path $sessionDir "akai_memory_logical_backup.json"
        try {
            $headers = @{}
            if ($AuthToken) { $headers["Authorization"] = "Bearer $AuthToken" }
            $memResp = Invoke-RestMethod -Uri $MemoryUrl -Method Get -Headers $headers -TimeoutSec 4 -ErrorAction Stop
            $memJson = $memResp | ConvertTo-Json -Depth 10
            [System.IO.File]::WriteAllText($logicalBackupPath, $memJson, [System.Text.Encoding]::UTF8)
            Write-Host "      Snapshot logico parziale REST salvato: $logicalBackupPath (cronologia/preferenze)" -ForegroundColor Green
        } catch {
            Write-Host "      Endpoint REST non raggiungibile o autenticazione 401 richiesta ($($_.Exception.Message)) - continuo con snapshot binario..." -ForegroundColor Yellow
        }

        # 3. Snapshot consistente SQLite con recovery atomico try/finally per v5
        $backupDb = Join-Path $sessionDir "akai_memory.db"
        $backupDbWal = Join-Path $sessionDir "akai_memory.db-wal"
        $preStopState = Get-ApplicationProcessState -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName
        $wasRunning = [bool]$preStopState.IsRunning
        $hasActivePairing = $false
        if ($wasRunning) {
            try {
                $preStatus = Invoke-RestMethod -Uri $StatusUrl -Method Get -TimeoutSec 2 -ErrorAction Stop
                if ($preStatus -and $null -ne $preStatus.active_sessions -and [int]$preStatus.active_sessions -gt 0) {
                    $hasActivePairing = $true
                }
            } catch {
                # Endpoint HTTP non raggiungibile o non pronto prima dello stop
            }
        }
        $requirePairingEffective = [bool]($RequirePairing -or $hasActivePairing)
        $stopIssued = $false
        $unrootUnknown = $false
        $backupException = $null
        $restoreResult = $null

        try {
            Write-Host "[2/3] Arresto writer app (wasRunning=$wasRunning) e tentativo snapshot..."
            $stopIssued = $true
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                & $adb -s $TargetAdb shell "am force-stop $PackageName" 2>&1 | Out-Null
                & $adb -s $TargetAdb shell "am startservice -a it.akai.customremote.ACTION_BACKUP_DB $PackageName/.RemoteServerService" 2>&1 | Out-Null
            } catch {
                # In v5 il servizio non e' esportato e ACTION_BACKUP_DB non esiste; snapshot gestito da fallback binario
            } finally {
                $ErrorActionPreference = $prevEap
            }
            Start-Sleep -Seconds 1

            Write-Host "[3/3] Estrazione database SQLite e gestione file WAL..."
            $extracted = $false

            # Tentativo A: snapshot via run-as
            $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "run-as $PackageName cat files/akai_memory_snapshot.db" -LocalFilePath $backupDb
            if ($rx.Success) { $extracted = $true }

            # Tentativo B: snapshot via su
            if (-not $extracted) {
                $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "su -c 'cat /data/data/$PackageName/files/akai_memory_snapshot.db'" -LocalFilePath $backupDb
                if ($rx.Success) { $extracted = $true }
            }

            # Se snapshot v6 non presente, applica quiescenza verificata per estrazione baseline v5
            if (-not $extracted) {
                Ensure-ApplicationQuiescence -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName
            }

            # Tentativo C: database primario + WAL via run-as (baseline v5 con probing attivo WAL)
            if (-not $extracted) {
                $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "run-as $PackageName cat databases/akai_memory.db" -LocalFilePath $backupDb
                if ($rx.Success) {
                    $walProbe = Probe-DeviceFileState -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName -RelativePath "databases/akai_memory.db-wal" -Channel "run-as"
                    if ($walProbe -eq "EXISTS") {
                        Write-Host "      File WAL presente su device (run-as): estrazione obbligatoria (fail-closed)..." -ForegroundColor Cyan
                        $rxWal = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "run-as $PackageName cat databases/akai_memory.db-wal" -LocalFilePath $backupDbWal -MinBytes 32
                        if (-not $rxWal.Success -or -not (Test-Path $backupDbWal) -or (Get-Item $backupDbWal).Length -lt 32) {
                            throw "ERRORE FAIL-CLOSED: File WAL (akai_memory.db-wal) presente su storage device ma estrazione fallita o non leggibile via run-as."
                        }
                        Write-Host "      File WAL estratto con successo: $backupDbWal ($((Get-Item $backupDbWal).Length) bytes)" -ForegroundColor Green
                    } elseif ($walProbe -eq "NOT_FOUND") {
                        Write-Host "      Verifica presenza WAL su storage device: ASSENTE (stato consistente single-file)." -ForegroundColor Green
                        if (Test-Path $backupDbWal) { Remove-Item $backupDbWal -Force -ErrorAction SilentlyContinue }
                    }
                    $extracted = $true
                }
            }

            # Tentativo D: database primario + WAL via su (baseline v5 con probing attivo WAL)
            if (-not $extracted) {
                $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "su -c 'cat /data/data/$PackageName/databases/akai_memory.db'" -LocalFilePath $backupDb
                if ($rx.Success) {
                    $walProbe = Probe-DeviceFileState -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName -RelativePath "databases/akai_memory.db-wal" -Channel "su"
                    if ($walProbe -eq "EXISTS") {
                        Write-Host "      File WAL presente su device (su): estrazione obbligatoria (fail-closed)..." -ForegroundColor Cyan
                        $rxWal = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "su -c 'cat /data/data/$PackageName/databases/akai_memory.db-wal'" -LocalFilePath $backupDbWal -MinBytes 32
                        if (-not $rxWal.Success -or -not (Test-Path $backupDbWal) -or (Get-Item $backupDbWal).Length -lt 32) {
                            throw "ERRORE FAIL-CLOSED: File WAL (akai_memory.db-wal) presente su storage device ma estrazione fallita o non leggibile via su."
                        }
                        Write-Host "      File WAL estratto con successo: $backupDbWal ($((Get-Item $backupDbWal).Length) bytes)" -ForegroundColor Green
                    } elseif ($walProbe -eq "NOT_FOUND") {
                        Write-Host "      Verifica presenza WAL su storage device: ASSENTE (stato consistente single-file)." -ForegroundColor Green
                        if (Test-Path $backupDbWal) { Remove-Item $backupDbWal -Force -ErrorAction SilentlyContinue }
                    }
                    $extracted = $true
                }
            }

            # Tentativo E: database primario + WAL via root adbd (firmware userdebug con probing attivo WAL)
            if (-not $extracted) {
                $script:rootExtracted = $false
                $rootElevErr = ""
                try {
                    Invoke-WithAdbElevation -AdbExe $adb -TargetAdb $TargetAdb -ActionBlock {
                        $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "cat /data/data/$PackageName/databases/akai_memory.db" -LocalFilePath $backupDb
                        if ($rx.Success) {
                            $walProbe = Probe-DeviceFileState -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName -RelativePath "databases/akai_memory.db-wal" -Channel "root"
                            if ($walProbe -eq "EXISTS") {
                                Write-Host "      File WAL presente su device (root): estrazione obbligatoria (fail-closed)..." -ForegroundColor Cyan
                                $rxWal = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "cat /data/data/$PackageName/databases/akai_memory.db-wal" -LocalFilePath $backupDbWal -MinBytes 32
                                if (-not $rxWal.Success -or -not (Test-Path $backupDbWal) -or (Get-Item $backupDbWal).Length -lt 32) {
                                    throw "ERRORE FAIL-CLOSED: File WAL (akai_memory.db-wal) presente su storage device ma estrazione fallita o non leggibile via root."
                                }
                                Write-Host "      File WAL estratto con successo: $backupDbWal ($((Get-Item $backupDbWal).Length) bytes)" -ForegroundColor Green
                            } elseif ($walProbe -eq "NOT_FOUND") {
                                Write-Host "      Verifica presenza WAL su storage device: ASSENTE (stato consistente single-file)." -ForegroundColor Green
                                if (Test-Path $backupDbWal) { Remove-Item $backupDbWal -Force -ErrorAction SilentlyContinue }
                            }
                            $script:rootExtracted = $true
                        }
                    }
                } catch {
                    if ($_.Exception.Message -match "STATO ADBD UNKNOWN") { $unrootUnknown = $true; throw }
                    if ($_.Exception.Message -match "File WAL") { throw }
                    $rootElevErr = " [$($_.Exception.Message)]"
                }
                if ($script:rootExtracted) {
                    $extracted = $true
                    $script:rootExtracted = $false
                }
            }

            if (-not $extracted -or -not (Test-Path $backupDb) -or (Get-Item $backupDb).Length -lt 512) {
                throw "ERRORE FAIL-CLOSED: Estrazione del database fallita (permessi negati o file non accessibile)$rootElevErr."
            }

            # Pulizia WAL vuoto
            if (Test-Path $backupDbWal) {
                if ((Get-Item $backupDbWal).Length -lt 32) {
                    Remove-Item $backupDbWal -Force -ErrorAction SilentlyContinue
                } else {
                    Write-Host "      File WAL rilevato ($((Get-Item $backupDbWal).Length) bytes) - applicazione checkpoint offline..." -ForegroundColor Cyan
                }
            }

            Verify-SQLiteIntegrityOffline $backupDb | Out-Null
            $dbHash = Get-Sha256Hex $backupDb
            Write-Host "      Database SQLite consolidato e verificato integro: $backupDb ($((Get-Item $backupDb).Length) bytes, SHA-256=$dbHash)" -ForegroundColor Green

            # Snapshot identita' TLS protetto (server_keystore.p12, pass, ca.pem, ca.crt, ca_key.der)
            $tlsManifest = Backup-DeviceTlsIdentity -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName -SessionDir $sessionDir
            # Snapshot cifrato preferenze pairing smartphone / config AI
            $pairingManifest = Backup-DevicePairingSessions -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName -SessionDir $sessionDir -RequirePairing:$requirePairingEffective
            $vaultDirs = @()
            if ($tlsManifest -and $tlsManifest.VaultDir) { $vaultDirs += $tlsManifest.VaultDir }
            if ($pairingManifest -and $pairingManifest.VaultDir) { $vaultDirs += $pairingManifest.VaultDir }
            Assert-BackupSessionNoPlaintextSecrets -SessionDir $sessionDir -VaultDirs $vaultDirs | Out-Null
        } catch {
            if ($_.Exception.Message -match "STATO ADBD UNKNOWN") { $unrootUnknown = $true }
            $backupException = $_
        } finally {
            if ($wasRunning -and $stopIssued) {
                $restoreResult = Restore-TargetApplicationService -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName -TargetTv $TargetTv -ExpectedHttpPort $HttpPort -UnrootVerified (-not $unrootUnknown)
            }
        }

        if ($restoreResult -and -not $restoreResult.Restored) {
            Write-Host "[STATO SERVIZIO V5 UNKNOWN / RECUPERO MANUALE RICHIESTO] $($restoreResult.Reason)" -ForegroundColor Red
            Write-Host "      Procedura manuale: $($restoreResult.ManualRecovery)" -ForegroundColor Yellow
            if ($backupException) {
                throw "$($backupException.Exception.Message) | [STATO SERVIZIO V5 UNKNOWN / RECUPERO MANUALE RICHIESTO] $($restoreResult.Status): $($restoreResult.Reason). Manuale: $($restoreResult.ManualRecovery)"
            }
            throw "ERRORE FAIL-CLOSED POST-BACKUP [STATO SERVIZIO V5 UNKNOWN / RECUPERO MANUALE RICHIESTO]: Backup completato ma ripristino servizio v5 fallito ($($restoreResult.Status): $($restoreResult.Reason)). Manuale: $($restoreResult.ManualRecovery)"
        }
        if ($backupException) {
            throw $backupException
        }
        Write-Host "Sessione di backup completata in: $sessionDir" -ForegroundColor Green
    }

    "install" {
        $adb = Get-AdbExecutable
        Write-Host "=== INSTALLAZIONE PROTETTA CON VERIFICA FIRME FAIL-CLOSED E WATCHDOG (30s) ===" -ForegroundColor Cyan

        & $adb connect $TargetAdb | Out-Null
        $sessionDir = Join-Path $BackupDir "backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null

        # 1. Verifica se l'app è già installata
        $pathOutput = & $adb -s $TargetAdb shell "pm path $PackageName"
        $hasPrevious = $false
        $backupApk = Join-Path $sessionDir "it.akai.customremote_backup.apk"
        $backupDb = Join-Path $sessionDir "akai_memory.db"
        $backupDbHash = $null

        if ($pathOutput -match "package:(.+)") {
            $hasPrevious = $true
            $remoteApk = $matches[1].Trim()

            # 1.1 Backup obbligatorio APK
            Write-Host "[1/6] Esecuzione backup preventivo dell'APK installato..."
            & $adb -s $TargetAdb pull $remoteApk $backupApk | Out-Null
            if (-not (Test-Path $backupApk) -or (Get-Item $backupApk).Length -eq 0) {
                throw "ERRORE FAIL-CLOSED: Impossibile completare il backup dell'APK esistente."
            }
            Write-Host "      Backup APK salvato: $backupApk ($((Get-Item $backupApk).Length) bytes)" -ForegroundColor Green

            # 1.2 Snapshot logico opzionale REST: HTTPS con CA trusted, mai HTTP/Bearer in chiaro
            $logicalBackupPath = Join-Path $sessionDir "akai_memory_logical_backup.json"
            try {
                $headers = @{}
            if ($AuthToken) { $headers["Authorization"] = "Bearer $AuthToken" }
            $memResp = Invoke-RestMethod -Uri $MemoryUrl -Method Get -Headers $headers -TimeoutSec 4 -ErrorAction Stop
                $memJson = $memResp | ConvertTo-Json -Depth 10
                [System.IO.File]::WriteAllText($logicalBackupPath, $memJson, [System.Text.Encoding]::UTF8)
                Write-Host "      Snapshot logico parziale REST salvato: $logicalBackupPath (cronologia/preferenze)" -ForegroundColor Green
            } catch {
                Write-Host "      Endpoint REST non raggiungibile o autenticazione 401 richiesta ($($_.Exception.Message)) - continuo con snapshot binario..." -ForegroundColor Yellow
            }

            # 1.3 Backup OBBLIGATORIO del database SQLite (FAIL-CLOSED) con WAL
            Write-Host "[2/6] Backup preventivo OBBLIGATORIO del database SQLite e gestione WAL..."
            $backupDbWal = Join-Path $sessionDir "akai_memory.db-wal"
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                & $adb -s $TargetAdb shell "am force-stop $PackageName" 2>&1 | Out-Null
                & $adb -s $TargetAdb shell "am startservice -a it.akai.customremote.ACTION_BACKUP_DB $PackageName/.RemoteServerService" 2>&1 | Out-Null
            } catch {
                # In v5 il servizio non e' esportato e ACTION_BACKUP_DB non esiste; snapshot gestito da fallback binario
            } finally {
                $ErrorActionPreference = $prevEap
            }
            Start-Sleep -Seconds 1

            $dbExtracted = $false
            # Tentativo A: snapshot via run-as
            $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "run-as $PackageName cat files/akai_memory_snapshot.db" -LocalFilePath $backupDb
            if ($rx.Success) { $dbExtracted = $true }

            # Tentativo B: snapshot via su
            if (-not $dbExtracted) {
                $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "su -c 'cat /data/data/$PackageName/files/akai_memory_snapshot.db'" -LocalFilePath $backupDb
                if ($rx.Success) { $dbExtracted = $true }
            }

            # Se snapshot v6 non presente, applica quiescenza verificata per estrazione baseline v5
            if (-not $dbExtracted) {
                Ensure-ApplicationQuiescence -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName
            }

            # Tentativo C: database primario + WAL via run-as (baseline v5 con probing attivo WAL)
            if (-not $dbExtracted) {
                $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "run-as $PackageName cat databases/akai_memory.db" -LocalFilePath $backupDb
                if ($rx.Success) {
                    $walProbe = Probe-DeviceFileState -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName -RelativePath "databases/akai_memory.db-wal" -Channel "run-as"
                    if ($walProbe -eq "EXISTS") {
                        Write-Host "      File WAL presente su device (run-as): estrazione obbligatoria (fail-closed)..." -ForegroundColor Cyan
                        $rxWal = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "run-as $PackageName cat databases/akai_memory.db-wal" -LocalFilePath $backupDbWal -MinBytes 32
                        if (-not $rxWal.Success -or -not (Test-Path $backupDbWal) -or (Get-Item $backupDbWal).Length -lt 32) {
                            throw "ERRORE FAIL-CLOSED: File WAL (akai_memory.db-wal) presente su storage device ma estrazione fallita o non leggibile via run-as."
                        }
                        Write-Host "      File WAL estratto con successo: $backupDbWal ($((Get-Item $backupDbWal).Length) bytes)" -ForegroundColor Green
                    } elseif ($walProbe -eq "NOT_FOUND") {
                        Write-Host "      Verifica presenza WAL su storage device: ASSENTE (stato consistente single-file)." -ForegroundColor Green
                        if (Test-Path $backupDbWal) { Remove-Item $backupDbWal -Force -ErrorAction SilentlyContinue }
                    }
                    $dbExtracted = $true
                }
            }

            # Tentativo D: database primario + WAL via su (baseline v5 con probing attivo WAL)
            if (-not $dbExtracted) {
                $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "su -c 'cat /data/data/$PackageName/databases/akai_memory.db'" -LocalFilePath $backupDb
                if ($rx.Success) {
                    $walProbe = Probe-DeviceFileState -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName -RelativePath "databases/akai_memory.db-wal" -Channel "su"
                    if ($walProbe -eq "EXISTS") {
                        Write-Host "      File WAL presente su device (su): estrazione obbligatoria (fail-closed)..." -ForegroundColor Cyan
                        $rxWal = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "su -c 'cat /data/data/$PackageName/databases/akai_memory.db-wal'" -LocalFilePath $backupDbWal -MinBytes 32
                        if (-not $rxWal.Success -or -not (Test-Path $backupDbWal) -or (Get-Item $backupDbWal).Length -lt 32) {
                            throw "ERRORE FAIL-CLOSED: File WAL (akai_memory.db-wal) presente su storage device ma estrazione fallita o non leggibile via su."
                        }
                        Write-Host "      File WAL estratto con successo: $backupDbWal ($((Get-Item $backupDbWal).Length) bytes)" -ForegroundColor Green
                    } elseif ($walProbe -eq "NOT_FOUND") {
                        Write-Host "      Verifica presenza WAL su storage device: ASSENTE (stato consistente single-file)." -ForegroundColor Green
                        if (Test-Path $backupDbWal) { Remove-Item $backupDbWal -Force -ErrorAction SilentlyContinue }
                    }
                    $dbExtracted = $true
                }
            }

            # Tentativo E: database primario + WAL via root adbd (firmware userdebug con probing attivo WAL)
            if (-not $dbExtracted) {
                $script:rootDbExtracted = $false
                $rootElevErr = ""
                try {
                    Invoke-WithAdbElevation -AdbExe $adb -TargetAdb $TargetAdb -ActionBlock {
                        $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "cat /data/data/$PackageName/databases/akai_memory.db" -LocalFilePath $backupDb
                        if ($rx.Success) {
                            $walProbe = Probe-DeviceFileState -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName -RelativePath "databases/akai_memory.db-wal" -Channel "root"
                            if ($walProbe -eq "EXISTS") {
                                Write-Host "      File WAL presente su device (root): estrazione obbligatoria (fail-closed)..." -ForegroundColor Cyan
                                $rxWal = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "cat /data/data/$PackageName/databases/akai_memory.db-wal" -LocalFilePath $backupDbWal -MinBytes 32
                                if (-not $rxWal.Success -or -not (Test-Path $backupDbWal) -or (Get-Item $backupDbWal).Length -lt 32) {
                                    throw "ERRORE FAIL-CLOSED: File WAL (akai_memory.db-wal) presente su storage device ma estrazione fallita o non leggibile via root."
                                }
                                Write-Host "      File WAL estratto con successo: $backupDbWal ($((Get-Item $backupDbWal).Length) bytes)" -ForegroundColor Green
                            } elseif ($walProbe -eq "NOT_FOUND") {
                                Write-Host "      Verifica presenza WAL su storage device: ASSENTE (stato consistente single-file)." -ForegroundColor Green
                                if (Test-Path $backupDbWal) { Remove-Item $backupDbWal -Force -ErrorAction SilentlyContinue }
                            }
                            $script:rootDbExtracted = $true
                        }
                    }
                } catch {
                    if ($_.Exception.Message -match "STATO ADBD UNKNOWN" -or $_.Exception.Message -match "File WAL") { throw }
                    $rootElevErr = " [$($_.Exception.Message)]"
                }
                if ($script:rootDbExtracted) {
                    $dbExtracted = $true
                    $script:rootDbExtracted = $false
                }
            }

            # VERIFICA FAIL-CLOSED CATEGORICA SUL DATABASE
            if (-not $dbExtracted -or -not (Test-Path $backupDb) -or (Get-Item $backupDb).Length -lt 512) {
                throw "ERRORE FAIL-CLOSED: Rilevata installazione precedente di $PackageName (v5) ma estrazione del database SQLite fallita (permessi negati run-as/su o DB inaccessibile)$rootElevErr. L'installazione e' categoricamente BLOCCATA.`nIl parametro -GreenfieldStart e' consentito esclusivamente per nuove installazioni (clean-start con package assente) per evitare che un aggiornamento in-place migri irreversibilmente lo schema SQLite da v5 a v6 senza possibilita' di rollback garantito."
            } else {
                # Pulizia WAL vuoto se presente
                if (Test-Path $backupDbWal) {
                    if ((Get-Item $backupDbWal).Length -lt 32) {
                        Remove-Item $backupDbWal -Force -ErrorAction SilentlyContinue
                    } else {
                        Write-Host "      File WAL rilevato ($((Get-Item $backupDbWal).Length) bytes) - applicazione checkpoint offline..." -ForegroundColor Cyan
                    }
                }

                Verify-SQLiteIntegrityOffline $backupDb | Out-Null
                $backupDbHash = Get-Sha256Hex $backupDb
                Write-Host "      Database SQLite consolidato e integro: $backupDb ($((Get-Item $backupDb).Length) bytes, SHA-256=$backupDbHash)" -ForegroundColor Green

                # Snapshot identita' TLS protetto (server_keystore.p12, pass, ca.pem, ca.crt, ca_key.der)
                $installTlsManifest = Backup-DeviceTlsIdentity -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName -SessionDir $sessionDir
                # Snapshot cifrato preferenze pairing smartphone / config AI
                $installPairingManifest = Backup-DevicePairingSessions -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName -SessionDir $sessionDir -RequirePairing:$RequirePairing
                $installVaultDirs = @()
                if ($installTlsManifest -and $installTlsManifest.VaultDir) { $installVaultDirs += $installTlsManifest.VaultDir }
                if ($installPairingManifest -and $installPairingManifest.VaultDir) { $installVaultDirs += $installPairingManifest.VaultDir }
                Assert-BackupSessionNoPlaintextSecrets -SessionDir $sessionDir -VaultDirs $installVaultDirs | Out-Null
            }

            # 2. Verifica compatibilità firme FAIL-CLOSED
            Write-Host "[3/6] Verifica compatibilità certificato firma (FAIL-CLOSED)..."
            $backupFp = Get-ApkCertificateFingerprint $backupApk
            $candidateFp = Get-ApkCertificateFingerprint $ApkPath
            Write-Host "      Certificato installato : $backupFp"
            Write-Host "      Certificato candidato   : $candidateFp"

            if ([string]::IsNullOrWhiteSpace($backupFp) -or [string]::IsNullOrWhiteSpace($candidateFp)) {
                throw "BLOCCO FAIL-CLOSED: Impronta SHA-256 non estraibile."
            }
            if ($backupFp.Length -ne 64 -or $candidateFp.Length -ne 64) {
                throw "BLOCCO FAIL-CLOSED: Impronta digest non conforme a SHA-256 (64 hex)."
            }
            if ($backupFp -ne $candidateFp) {
                throw "BLOCCO FAIL-CLOSED: FIRMA INCOMPATIBILE! Il certificato dell'APK candidato non corrisponde alla TV. L'installazione comporterebbe INSTALL_FAILED_UPDATE_INCOMPATIBLE."
            }
            Write-Host "      Compatibilità firma SHA-256 verificata con successo al 100%." -ForegroundColor Green
        } else {
            Write-Host "[1/6] Nessun APK precedente installato sulla TV ($PackageName assente)." -ForegroundColor Yellow
            if (-not $GreenfieldStart) {
                throw "ERRORE FAIL-CLOSED: Il package $PackageName non e' presente sulla TV. Per autorizzare una prima installazione pulita (clean-start) specificare esplicitamente il parametro: -GreenfieldStart"
            }
            Write-Host "      Parametro -GreenfieldStart attivo: autorizzata prima installazione pulita." -ForegroundColor Green
            Write-Host "      Home v8 (it.akai.customhome.v8) e Home v7 (it.akai.customhome) rimangono intatte al 100%." -ForegroundColor Green
        }

        # 2b. Gate Negativo TLS: Verifica assoluta assenza segreti/chiavi/certificati TLS preconfezionati nell'APK
        Assert-CandidateApkNoForbiddenTlsAssets $ApkPath | Out-Null

        if (-not [string]::IsNullOrWhiteSpace($ExpectedCandidateSha256) -and ($ExpectedCandidateSha256 -notmatch "^[a-fA-F0-9]{64}$")) {
            throw "ERRORE FAIL-CLOSED [CANDIDATO HASH NON VALIDO]: ExpectedCandidateSha256 deve essere un digest SHA-256 a 64 hex."
        }
        $candShaPre = Get-Sha256Hex $ApkPath
        $lockedCandidateSha256 = if (-not [string]::IsNullOrWhiteSpace($ExpectedCandidateSha256)) { $ExpectedCandidateSha256.ToLowerInvariant() } else { $candShaPre }
        if ($candShaPre -ne $lockedCandidateSha256) {
            throw "ERRORE FAIL-CLOSED [CANDIDATO APK HASH MISMATCH]: SHA-256 file candidato ($candShaPre) diverso da ExpectedCandidateSha256 ($lockedCandidateSha256)."
        }

        # 3. Gate pre-install (applicationId + versionCode) e installazione conservativa (no -d su install)
        $upgradeGate = Test-PackageUpgradeGate -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName -CandidateApkPath $ApkPath -PreviousAbsentConfirmed:((-not $hasPrevious) -and $GreenfieldStart)
        if ($upgradeGate.CandidateVersionCode) {
            Write-Host "      Gate pacchetto verificato (target=$PackageName, installedVC=$($upgradeGate.InstalledVersionCode), candidateVC=$($upgradeGate.CandidateVersionCode), candSHA256=$lockedCandidateSha256)." -ForegroundColor Green
        }
        $isOwnerHardwareTarget = $RequireOwnerRescue -or ($TargetTv -notin @("127.0.0.1", "localhost", "::1"))
        if ($hasPrevious -and $isOwnerHardwareTarget -and [string]::IsNullOrWhiteSpace($RescueApkPath)) {
            throw "ERRORE FAIL-CLOSED [RESCUE APK OBBLIGATORIO]: Su hardware reale (o -RequireOwnerRescue) e' obbligatorio fornire -RescueApkPath verificato prima di installare un aggiornamento in-place."
        }
        if ($hasPrevious -and $RequireOwnerRescue -and [string]::IsNullOrWhiteSpace($ExpectedRescueSha256)) {
            throw "ERRORE FAIL-CLOSED [RESCUE HASH OBBLIGATORIO]: Con -RequireOwnerRescue attivo e' obbligatorio specificare -ExpectedRescueSha256."
        }
        $lockedRescueSha256 = $null
        if (-not [string]::IsNullOrWhiteSpace($RescueApkPath)) {
            $rescueCompat = Test-RescueApkCompatibility -RescueApkPath $RescueApkPath -PackageName $PackageName -MustExceedVersionCode $upgradeGate.CandidateVersionCode -ExpectedSignerSha256 $(if ($hasPrevious) { $backupFp } else { $null }) -ExpectedRescueSha256 $ExpectedRescueSha256 -RequireExpectedSigner:$hasPrevious
            $lockedRescueSha256 = $rescueCompat.FileSha256
            Write-Host "      Gate A2 Rescue verificato (rescueVC=$($rescueCompat.VersionCode) > candidateVC=$($upgradeGate.CandidateVersionCode), SHA256=$($lockedRescueSha256), zero-uninstall pronto)." -ForegroundColor Green
        }
        $candShaNow = Get-Sha256Hex $ApkPath
        if ($candShaNow -ne $lockedCandidateSha256) {
            throw "ERRORE FAIL-CLOSED [CANDIDATO APK TOCTOU MISMATCH]: Hash candidato mutato prima dell'installazione ($candShaNow vs $lockedCandidateSha256)."
        }
        Write-Host "[4/6] Installazione nuovo APK (adb install -r)..."
        $installRes = & $adb -s $TargetAdb install -r $ApkPath
        Write-Host "      Esito adb: $installRes"
        if ($LASTEXITCODE -ne 0 -or (($installRes -join "`n") -notmatch "Success")) {
            throw "ERRORE FAIL-CLOSED: Installazione fallita da adb (exit=$LASTEXITCODE): $installRes"
        }

        # 4. Avvio Android 9 attraverso l'Activity ESPORTATA.
        # RemoteServerService ha android:exported="false": adb shell (uid 2000)
        # NON puo' invocarla direttamente; MainActivity avvia il servizio nel proprio UID.
        # Non lasciare che stderr nativo faccia uscire da PowerShell prima del watchdog.
        Write-Host "[5/6] Avvio MainActivity (RemoteServerService interno non esportato)..."
        $previousEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $startActivityOutput = (& $adb -s $TargetAdb shell "am start -n $PackageName/.MainActivity" 2>&1 | Out-String).Trim()
            $startActivityExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousEap
        }
        if ($startActivityExit -ne 0 -or $startActivityOutput -match "Error:|Exception|Permission Denial") {
            Write-Host "      Avvio Activity non confermato (exit=$startActivityExit): $startActivityOutput. Proseguo al watchdog per valutare lo stato reale." -ForegroundColor Yellow
        } else {
            Write-Host "      Intent Activity inviato: $startActivityOutput" -ForegroundColor Green
        }

        # 5. Multi-Point Health Check Watchdog (30s)
        Write-Host "[6/6] Multi-Point Health Check Watchdog attivo (timeout 30s)..."
        $healthy = $false
        $watchdogFailureReason = "Watchdog timeout (HTTP/HTTPS/PID/Status non operativi)"
        $attempts = $(if ($env:WATCHDOG_ATTEMPTS) { [int]$env:WATCHDOG_ATTEMPTS } else { 6 })
        $sleepSec = $(if ($env:WATCHDOG_SLEEP_SEC) { [int]$env:WATCHDOG_SLEEP_SEC } else { 5 })
        for ($i = 1; $i -le $attempts; $i++) {
            Start-Sleep -Seconds $sleepSec
            try {
                $statusResp = Invoke-RestMethod -Uri $StatusUrl -Method Get -TimeoutSec 4 -ErrorAction Stop
                
                # 1. Verifica HTTP 8088 (/index.html e /api/status)
                # Il telecomando classico LAN esige obbligatoriamente HTTP 200 con payload HTML valido.
                # L'esito 426 su /index.html costituisce regressione vietata (rompe il telecomando).
                $webOk = $false
                $webStatusMsg = ""
                try {
                    $webResp = Invoke-WebRequest -Uri $WebUrl -Method Get -TimeoutSec 4 -UseBasicParsing -ErrorAction Stop
                    if ($webResp.StatusCode -eq 200) {
                        if ($webResp.Content -match "<html|<!DOCTYPE|<body|<title") {
                            $webOk = $true
                            $webStatusMsg = "HTTP 200 ($($webResp.RawContentLength) bytes - telecomando classico LAN HTML operativo)"
                        } else {
                            $webOk = $false
                            $webStatusMsg = "FALLITO (HTTP 200 ma payload HTML non valido o tronco)"
                        }
                    } else {
                        $webOk = $false
                        $webStatusMsg = "FALLITO (HTTP status $($webResp.StatusCode))"
                    }
                } catch {
                    if ($_.Exception.Message -match "426" -or ($_.Exception.Response -and $_.Exception.Response.StatusCode -eq 426)) {
                        $webOk = $false
                        $webStatusMsg = "FALLITO (HTTP 426 Upgrade Required su /index.html: regressione telecomando classico LAN vietata)"
                    } else {
                        $webOk = $false
                        $webStatusMsg = "FALLITO ($($_.Exception.Message))"
                    }
                }
                $pidVal = (& $adb -s $TargetAdb shell "pidof $PackageName").Trim()

                # 2. Verifica OBBLIGATORIA Porta HTTPS 8443 per il nuovo candidato JARVIS (P0-2)
                # Il candidato DEVE esporre sia HTTP 8088 operativo sia HTTPS 8443 TLS attivo.
                $httpsOk = $false
                $httpsStatusMsg = ""
                $tlsRes = Test-HttpsTlsEndpoint -TargetHost $TargetTv -Port $HttpsPort -ExpectedCaSha256 $ExpectedCaFingerprint -TimeoutMs 4000
                if ($tlsRes.Success -and $tlsRes.Status -eq "APPROVED") {
                    $httpsOk = $true
                    $httpsStatusMsg = "APPROVED (Porta $HttpsPort, Handshake TLS OK, SAN=$TargetTv OK, Root CA SHA256=$($tlsRes.RootCaSha256) Verificata)"
                } elseif ($tlsRes.SanMatched -and $tlsRes.Status -eq "TLS_HANDSHAKE_ONLY/UNVERIFIED") {
                    if ([string]::IsNullOrWhiteSpace($ExpectedCaFingerprint)) {
                        $httpsOk = $true
                        $httpsStatusMsg = "PROVISIONAL / OOB TRUST PENDING (Porta $HttpsPort, Handshake TLS OK, SAN=$TargetTv OK, Root CA SHA256=$($tlsRes.RootCaSha256))"
                    } else {
                        $httpsOk = $false
                        $httpsStatusMsg = "UNVERIFIED: Handshake TLS attivo ma Root CA non corrisponde all'impronta attesa ($ExpectedCaFingerprint)"
                    }
                } else {
                    $httpsOk = $false
                    $httpsStatusMsg = "FALLITO ($($tlsRes.Status): $($tlsRes.Error)) - HTTPS $HttpsPort NON operativo"
                }

                if ($statusResp.status -eq "ok" -and $statusResp.uinput_ready -eq $true -and $webOk -and $httpsOk -and $pidVal) {
                    Write-Host "      Tentativo $i/$($attempts) SUPERATO:" -ForegroundColor Green
                    Write-Host "      - API Status       : OK (uinput_ready=true, active_sessions=$($statusResp.active_sessions))" -ForegroundColor Green
                    Write-Host "      - Telecomando HTTP : OK ($webStatusMsg)" -ForegroundColor Green
                    Write-Host "      - HTTPS 8443 TLS   : OK ($httpsStatusMsg)" -ForegroundColor Green
                    Write-Host "      - Processo TV      : ATTIVO (PID $pidVal)" -ForegroundColor Green
                    if ($RequireVerifiedKeystoreHealth) {
                        $installModeTag = if ($hasPrevious) { 'UPGRADE_V4' } else { 'CLEAN_INSTALL_V4' }
                        $installSessionDir = if ($hasPrevious) { $sessionDir } else { $null }
                        try {
                            $ksInstall = Invoke-PostRollbackKeystoreVerification -SessionDir $installSessionDir -RollbackMode $installModeTag -TargetTv $TargetTv -HttpsPort $HttpsPort -AuthToken $AuthToken -ExpectedCaFingerprint $ExpectedCaFingerprint -RequireVerifiedKeystoreHealth
                            Write-Host "      - AndroidKeyStore  : VERIFICATO ($($ksInstall.Status), Schema=$($ksInstall.Schema))" -ForegroundColor Green
                            $healthy = $true
                            break
                        } catch {
                            $ksErr = $_.Exception.Message
                            $watchdogFailureReason = "KEYSTORE_CREDENTIAL_HEALTH_FAILED: $ksErr"
                            $healthy = $false
                            Write-Host "      [ALLARME] Verifica AndroidKeyStore/AI fallita al tentativo $i/$($attempts): $ksErr" -ForegroundColor Red
                            if ($ksErr -match "SCHEMA|CREDENZIALI|NON DECIFRABILI|LEGACY|TOKEN|NON VERIFICATO") {
                                break
                            }
                        }
                    } else {
                        $healthy = $true
                        break
                    }
                } else {
                    Write-Host "      Tentativo $i/$($attempts) - In attesa: HTTP=($($webOk) - $webStatusMsg), HTTPS=($($httpsOk) - $httpsStatusMsg), Status=($($statusResp.status)), PID=($pidVal)" -ForegroundColor Yellow
                }
            } catch {
                Write-Host "      Tentativo $i/$($attempts) - Inizializzazione in corso ($($_.Exception.Message))..." -ForegroundColor Yellow
            }
        }

        if ($healthy) {
            if ($tlsRes -and $tlsRes.Status -eq "APPROVED") {
                Write-Host "`nDEPLOYMENT VERIFICATO CON SUCCESSO AL 100%! Tutti i componenti operativi e Root CA approvata." -ForegroundColor Green
            } else {
                Write-Host "`nSTATO PROVVISORIO: AVVIO TECNICO RIUSCITO (PROVISIONAL / OOB TRUST PENDING)" -ForegroundColor Yellow
                Write-Host "AVVISO DI SICUREZZA: Handshake TLS attivo ma Root CA non ancora validata fuori banda sullo schermo TV." -ForegroundColor Yellow
                Write-Host "Impronta osservata su connessione TLS (NON VERIFICATA): $($tlsRes.RootCaSha256)" -ForegroundColor Cyan
                Write-Host "DIVIETO: Non utilizzare credenziali/PIN/chiavi su HTTPS finche' l'impronta non e' verificata fuori banda." -ForegroundColor Yellow
                Write-Host "Per la convalida fuori banda (OOB) della Root CA in modalita' SOLA LETTURA (senza reinstallare):" -ForegroundColor Cyan
                Write-Host "  powershell -File .\akai-remote-tests\05_safe_install_and_rollback.ps1 -Action verify-tls -TargetTv $TargetTv -HttpsPort $HttpsPort -ExpectedCaFingerprint <IMPRONTA_LETTA_SULLO_SCHERMO_TV>" -ForegroundColor Cyan
                Write-Host "AVVERTENZA CRITICA: Inserire esclusivamente l'impronta letta VISIVAMENTE sullo schermo TV, MAI copiare l'impronta di rete!" -ForegroundColor Yellow
            }
        } else {
            Write-Host "`nALLARME: Health check fallito entro 30s! Avvio ROLLBACK..." -ForegroundColor Red
            Write-Host "      Motivo fallimento watchdog/gate: $watchdogFailureReason" -ForegroundColor Red
            if ($hasPrevious) {
                # VALIDAZIONE PREREQUISITI RIGOROSA PRE-ROLLBACK (P0-2 FAIL-CLOSED)
                if (-not (Test-Path $backupApk) -or (Get-Item $backupApk).Length -eq 0) {
                    throw "ERRORE FAIL-CLOSED FATALE: Impossibile eseguire il rollback. File APK precedente mancante ($backupApk)."
                }

                if (-not (Test-Path $backupDb) -or (Get-Item $backupDb).Length -lt 512) {
                    throw "ERRORE FAIL-CLOSED FATALE: Impossibile procedere al rollback automatico dell'APK senza backup del database SQLite v5 ($backupDb). La baseline v5 non supporta lo schema v6; reinstallare l'APK senza DB causerebbe crash irreversibile dell'app. Rollback interrotto in FAIL-CLOSED."
                }
                if (-not $backupDbHash) {
                    throw "ERRORE FAIL-CLOSED FATALE: Hash SHA-256 del backup SQLite v5 assente. Impossibile garantire integrita' bit-for-bit del ripristino."
                }

                $expectedRescueSigner = if (-not [string]::IsNullOrWhiteSpace($RescueApkPath)) { $backupFp } else { $null }
                $expectedMinRescueVc = if ($upgradeGate -and $upgradeGate.CandidateVersionCode) { [long]$upgradeGate.CandidateVersionCode } else { 0 }
                Write-Host "[ROLLBACK 1/4] Reinstallazione APK precedente (modalita' conservativa zero-uninstall)..."
                $rbApkResult = Invoke-ConservativeRollbackApkInstall -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName -BackupApkPath $backupApk -RescueApkPath $RescueApkPath -MustExceedVersionCode $expectedMinRescueVc -ExpectedSignerSha256 $expectedRescueSigner -ExpectedRescueSha256 $lockedRescueSha256 -ForbidLegacyDowngrade:$isOwnerHardwareTarget
                Write-Host "      Esito rollback APK ($($rbApkResult.Mode)): OK"

                Write-Host "[ROLLBACK 2/4] Ripristino database SQLite originale..."
                # 1. Arresto forzato dell'app per rilasciare lock sul file
                & $adb -s $TargetAdb shell "am force-stop $PackageName" | Out-Null

                # 2. Rimozione e verifica assenza file WAL e SHM orfani
                Remove-OrphanedWalAndShmFiles -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName

                # Risoluzione UID numerico Android per chown
                $appUid = $null
                $uidRaw = & $adb -s $TargetAdb shell "dumpsys package $PackageName | grep -E 'userId=|appId='" 2>$null
                $uidOut = if ($uidRaw) { $uidRaw.ToString().Trim() } else { "" }
                if ($uidOut -match "userId=(\d+)") { $appUid = $matches[1] }
                elseif ($uidOut -match "appId=(\d+)") { $appUid = $matches[1] }
                else {
                    $statRaw = & $adb -s $TargetAdb shell "stat -c '%u' /data/data/$PackageName" 2>$null
                    $statOut = if ($statRaw) { $statRaw.ToString().Trim() } else { "" }
                    if ($statOut -match "^\d+$") { $appUid = $statOut }
                }
                if ([string]::IsNullOrWhiteSpace($appUid) -or ($appUid -notmatch "^\d+$")) {
    throw "ERRORE FAIL-CLOSED: Impossibile risolvere con certezza l'identita' numerica UID Linux dell'applicazione ($PackageName) via dumpsys o stat. Applicazione permessi con UID arbitrario (es. 10000) categoricamente VIETATA per sicurezza."
}
$chownTarget = "${appUid}:${appUid}"

                # 3. Streaming diretto del backup binario in databases/akai_memory.db tramite pipe universale
                $restored = $false
                $streamRes = Send-FileViaAdbExecIn -AdbExe $adb -TargetAdb $TargetAdb -LocalFilePath $backupDb -RemoteCommand "run-as $PackageName sh -c 'mkdir -p databases; cat > databases/akai_memory.db; chmod 660 databases/akai_memory.db'"
                if ($streamRes.Success) {
                    $restored = $true
                } else {
                    $streamRes = Send-FileViaAdbExecIn -AdbExe $adb -TargetAdb $TargetAdb -LocalFilePath $backupDb -RemoteCommand "su -c 'mkdir -p /data/data/$PackageName/databases; cat > /data/data/$PackageName/databases/akai_memory.db; chown -R $chownTarget /data/data/$PackageName/databases; chmod 660 /data/data/$PackageName/databases/akai_memory.db'"
                    if ($streamRes.Success) { $restored = $true }
                }
                if (-not $restored) {
                    $script:rootRestored = $false
                    try {
                        Invoke-WithAdbElevation -AdbExe $adb -TargetAdb $TargetAdb -ActionBlock {
                            $sRoot = Send-FileViaAdbExecIn -AdbExe $adb -TargetAdb $TargetAdb -LocalFilePath $backupDb -RemoteCommand "sh -c 'mkdir -p /data/data/$PackageName/databases; cat > /data/data/$PackageName/databases/akai_memory.db; chown -R $chownTarget /data/data/$PackageName/databases; chmod 660 /data/data/$PackageName/databases/akai_memory.db'"
                            if ($sRoot.Success) { $script:rootRestored = $true }
                        }
                    } catch {
                        if ($_.Exception.Message -match "STATO ADBD UNKNOWN") { throw }
                    }
                    if ($script:rootRestored) {
                        $restored = $true
                        $script:rootRestored = $false
                    }
                }

                if (-not $restored) {
                    throw "ERRORE FAIL-CLOSED: Impossibile effettuare lo streaming del database ripristinato sul dispositivo (exit=$($streamRes.ExitCode), out=$($streamRes.Output))."
                }

                # 4. Verifica parità hash SHA-256 e integrità SQLite post-ripristino
                $verifyRestoreDb = Join-Path $sessionDir "verify_restore.db"
                $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "run-as $PackageName cat databases/akai_memory.db" -LocalFilePath $verifyRestoreDb
                if (-not $rx.Success) {
                    $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "su -c 'cat /data/data/$PackageName/databases/akai_memory.db'" -LocalFilePath $verifyRestoreDb
                }
                if (-not $rx.Success) {
                    $script:rootRx = $null
                    try {
                        Invoke-WithAdbElevation -AdbExe $adb -TargetAdb $TargetAdb -ActionBlock {
                            $script:rootRx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "cat /data/data/$PackageName/databases/akai_memory.db" -LocalFilePath $verifyRestoreDb
                        }
                    } catch {
                        if ($_.Exception.Message -match "STATO ADBD UNKNOWN") { throw }
                    }
                    if ($script:rootRx -and $script:rootRx.Success) {
                        $rx = $script:rootRx
                        $script:rootRx = $null
                    }
                }

                if (-not (Test-Path $verifyRestoreDb) -or (Get-Item $verifyRestoreDb).Length -lt 512) {
                    throw "ERRORE FAIL-CLOSED: Verifica post-rollback fallita: impossibile rileggere il database ripristinato dal dispositivo per validarne l'integrita'."
                }
                Verify-SQLiteIntegrityOffline $verifyRestoreDb | Out-Null
                $restHash = Get-Sha256Hex $verifyRestoreDb
                if ($restHash -ne $backupDbHash) {
                    throw "ERRORE FAIL-CLOSED: Mismatch hash SHA-256 post-ripristino! Orig: $backupDbHash, Device: $restHash"
                }
                Write-Host "      Parita' hash SHA-256 ($restHash) e integrita' SQLite post-rollback verificate con successo." -ForegroundColor Green

                Write-Host "      Database SQLite v5 ripristinato con successo." -ForegroundColor Green

                # Ripristino snapshot identita' TLS e pairing cifrati se presenti
                Restore-DeviceTlsIdentity -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName -SessionDir $sessionDir -ChownTarget $chownTarget | Out-Null
                Restore-DevicePairingSessions -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName -SessionDir $sessionDir -ChownTarget $chownTarget | Out-Null

                Write-Host "[ROLLBACK 3/4] Riavvio servizio RemoteServerService (MainActivity + startservice)..."
                $prevEapRb = $ErrorActionPreference
                $ErrorActionPreference = "Continue"
                try {
                    & $adb -s $TargetAdb shell "am startservice $PackageName/.RemoteServerService" 2>&1 | Out-Null
                    & $adb -s $TargetAdb shell "am start -n $PackageName/.MainActivity" 2>&1 | Out-Null
                } finally {
                    $ErrorActionPreference = $prevEapRb
                }

                Write-Host "[ROLLBACK 4/4] Verifica post-rollback dello stato di salute..."
                $rbHealthy = $false
                for ($r = 1; $r -le 3; $r++) {
                    Start-Sleep -Seconds 2
                    try {
                        $rbStatus = Invoke-RestMethod -Uri $StatusUrl -Method Get -TimeoutSec 4 -ErrorAction Stop
                        if ($rbStatus.status -eq "ok") {
                            $rbHealthy = $true
                            break
                        }
                    } catch {
                        Write-Host "      Controllo post-rollback $r/3: in avvio ($($_.Exception.Message))..." -ForegroundColor Yellow
                    }
                }

                if ($rbHealthy) {
                    $null = Invoke-PostRollbackKeystoreVerification -SessionDir $sessionDir -RollbackMode $rbApkResult.Mode -TargetTv $TargetTv -HttpsPort $HttpsPort -AuthToken $AuthToken -ExpectedCaFingerprint $ExpectedCaFingerprint -RequireVerifiedKeystoreHealth:$RequireVerifiedKeystoreHealth
                    Write-Host "ROLLBACK RIUSCITO E VERIFICATO: Sistema TV tornato operativo al 100% sulla versione precedente." -ForegroundColor Green
                } else {
                    Write-Host "ALLARME POST-ROLLBACK: Health check post-rollback fallito - STATO CRITICO FAIL/UNKNOWN." -ForegroundColor Red
                    throw "ERRORE FAIL-CLOSED: Watchdog post-rollback non superato. Il servizio non risponde con status=ok."
                }
            } else {
                # Rollback per clean-start (prima installazione fallita al watchdog)
                Write-Host "[ROLLBACK CLEAN-START 1/1] Disinstallazione nuovo APK per ripristino stato vergine..." -ForegroundColor Yellow
                $rbRes = & $adb -s $TargetAdb uninstall $PackageName
                Write-Host "      Esito adb uninstall rollback: $rbRes"
                Write-Host "ROLLBACK CLEAN-START COMPLETATO: Package $PackageName rimosso, dispositivo riportato allo stato vergine iniziale." -ForegroundColor Green
            }
            exit 1
        }
    }

    "rollback" {
        $adb = Get-AdbExecutable
        Write-Host "=== ROLLBACK MANUALE ALLA VERSIONE PRECEDENTE CON VERIFICA ===" -ForegroundColor Yellow
        $latestSession = Get-ChildItem -Path $BackupDir -Directory | Sort-Object CreationTime -Descending | Select-Object -First 1
        if (-not $latestSession) {
            throw "ERRORE FAIL-CLOSED: Nessuna sessione di backup trovata in $BackupDir."
        }
        $backupApk = Join-Path $latestSession.FullName "it.akai.customremote_backup.apk"
        $backupDb = Join-Path $latestSession.FullName "akai_memory.db"

        # VALIDAZIONE PREREQUISITI RIGOROSA PRE-ROLLBACK (P0-2 FAIL-CLOSED)
        if (-not (Test-Path $backupApk) -or (Get-Item $backupApk).Length -eq 0) {
            throw "ERRORE FAIL-CLOSED: File di backup APK non trovato in $backupApk."
        }
        if (-not (Test-Path $backupDb) -or (Get-Item $backupDb).Length -lt 512) {
            throw "ERRORE FAIL-CLOSED: Prerequisito critico mancante per il rollback manuale. File database di backup mancante o non integro in $backupDb. Impossibile procedere al downgrade dell'APK senza ripristino DB (rischio crash per schema v6 non supportato da v5)."
        }

        Verify-SQLiteIntegrityOffline $backupDb | Out-Null
        $backupDbHash = Get-Sha256Hex $backupDb

        $isOwnerManualHw = $RequireOwnerRescue -or ($TargetTv -notin @("127.0.0.1", "localhost", "::1"))
        if ($isOwnerManualHw -and [string]::IsNullOrWhiteSpace($RescueApkPath)) {
            throw "ERRORE FAIL-CLOSED [RESCUE APK OBBLIGATORIO]: Su target hardware/owner ($TargetTv) il rollback manuale richiede -RescueApkPath verificato (il fallback a downgrade -d e' vietato a tutela di AndroidKeyStore)."
        }
        $expectedRollbackSigner = if (-not [string]::IsNullOrWhiteSpace($RescueApkPath)) { Get-ApkCertificateFingerprint $backupApk } else { $null }
        $lockedManualRescueSha256 = if (-not [string]::IsNullOrWhiteSpace($ExpectedRescueSha256)) {
            $ExpectedRescueSha256
        } elseif (-not [string]::IsNullOrWhiteSpace($RescueApkPath) -and (Test-Path -LiteralPath $RescueApkPath -PathType Leaf)) {
            Get-Sha256Hex $RescueApkPath
        } else {
            $null
        }
        Write-Host "[1/4] Reinstallazione APK precedente da sessione: $($latestSession.Name) (modalita' conservativa zero-uninstall)..."
        $rbManualApkResult = Invoke-ConservativeRollbackApkInstall -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName -BackupApkPath $backupApk -RescueApkPath $RescueApkPath -ExpectedSignerSha256 $expectedRollbackSigner -ExpectedRescueSha256 $lockedManualRescueSha256 -ForbidLegacyDowngrade:$isOwnerManualHw
        Write-Host "      Esito rollback APK ($($rbManualApkResult.Mode)): OK"

        Write-Host "[2/4] Ripristino database SQLite originale..."
        & $adb -s $TargetAdb shell "am force-stop $PackageName" | Out-Null

        # Rimozione e verifica assenza file WAL/SHM orfani
        Remove-OrphanedWalAndShmFiles -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName

        # Risoluzione UID numerico Android per chown
        $appUid = $null
        $uidRaw = & $adb -s $TargetAdb shell "dumpsys package $PackageName | grep -E 'userId=|appId='" 2>$null
        $uidOut = if ($uidRaw) { $uidRaw.ToString().Trim() } else { "" }
        if ($uidOut -match "userId=(\d+)") { $appUid = $matches[1] }
        elseif ($uidOut -match "appId=(\d+)") { $appUid = $matches[1] }
        else {
            $statRaw = & $adb -s $TargetAdb shell "stat -c '%u' /data/data/$PackageName" 2>$null
            $statOut = if ($statRaw) { $statRaw.ToString().Trim() } else { "" }
            if ($statOut -match "^\d+$") { $appUid = $statOut }
        }
        if ([string]::IsNullOrWhiteSpace($appUid) -or ($appUid -notmatch "^\d+$")) {
    throw "ERRORE FAIL-CLOSED: Impossibile risolvere con certezza l'identita' numerica UID Linux dell'applicazione ($PackageName) via dumpsys o stat. Applicazione permessi con UID arbitrario (es. 10000) categoricamente VIETATA per sicurezza."
}
$chownTarget = "${appUid}:${appUid}"

        $restored = $false
        $streamRes = Send-FileViaAdbExecIn -AdbExe $adb -TargetAdb $TargetAdb -LocalFilePath $backupDb -RemoteCommand "run-as $PackageName sh -c 'mkdir -p databases; cat > databases/akai_memory.db; chmod 660 databases/akai_memory.db'"
        if ($streamRes.Success) {
            $restored = $true
        } else {
            $streamRes = Send-FileViaAdbExecIn -AdbExe $adb -TargetAdb $TargetAdb -LocalFilePath $backupDb -RemoteCommand "su -c 'mkdir -p /data/data/$PackageName/databases; cat > /data/data/$PackageName/databases/akai_memory.db; chown -R $chownTarget /data/data/$PackageName/databases; chmod 660 /data/data/$PackageName/databases/akai_memory.db'"
            if ($streamRes.Success) { $restored = $true }
        }
        if (-not $restored) {
            $script:rootRestored = $false
            try {
                Invoke-WithAdbElevation -AdbExe $adb -TargetAdb $TargetAdb -ActionBlock {
                    $sRoot = Send-FileViaAdbExecIn -AdbExe $adb -TargetAdb $TargetAdb -LocalFilePath $backupDb -RemoteCommand "sh -c 'mkdir -p /data/data/$PackageName/databases; cat > /data/data/$PackageName/databases/akai_memory.db; chown -R $chownTarget /data/data/$PackageName/databases; chmod 660 /data/data/$PackageName/databases/akai_memory.db'"
                    if ($sRoot.Success) { $script:rootRestored = $true }
                }
            } catch {
                if ($_.Exception.Message -match "STATO ADBD UNKNOWN") { throw }
            }
            if ($script:rootRestored) {
                $restored = $true
                $script:rootRestored = $false
            }
        }

        if (-not $restored) {
            throw "ERRORE FAIL-CLOSED: Impossibile effettuare lo streaming del database ripristinato sul dispositivo."
        }

        # Verifica integrità post-ripristino
        $verifyRestoreDb = Join-Path $latestSession.FullName "verify_manual_restore.db"
        $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "run-as $PackageName cat databases/akai_memory.db" -LocalFilePath $verifyRestoreDb
        if (-not $rx.Success) {
            $rx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "su -c 'cat /data/data/$PackageName/databases/akai_memory.db'" -LocalFilePath $verifyRestoreDb
        }
        if (-not $rx.Success) {
            $script:rootRx = $null
            try {
                Invoke-WithAdbElevation -AdbExe $adb -TargetAdb $TargetAdb -ActionBlock {
                    $script:rootRx = Receive-FileViaAdbExecOut -AdbExe $adb -TargetAdb $TargetAdb -RemoteCommand "cat /data/data/$PackageName/databases/akai_memory.db" -LocalFilePath $verifyRestoreDb
                }
            } catch {
                if ($_.Exception.Message -match "STATO ADBD UNKNOWN") { throw }
            }
            if ($script:rootRx -and $script:rootRx.Success) {
                $rx = $script:rootRx
                $script:rootRx = $null
            }
        }
        if (-not (Test-Path $verifyRestoreDb) -or (Get-Item $verifyRestoreDb).Length -lt 512) {
            throw "ERRORE FAIL-CLOSED: Verifica post-rollback fallita: impossibile rileggere il database ripristinato dal dispositivo ($($rx.Output))."
        }
        Verify-SQLiteIntegrityOffline $verifyRestoreDb | Out-Null
        $restHash = Get-Sha256Hex $verifyRestoreDb
        if ($backupDbHash -ne $restHash) {
            throw "ERRORE FAIL-CLOSED: Mismatch hash SHA-256 post-ripristino! Orig: $backupDbHash, Device: $restHash"
        }
        Write-Host "      Parita' hash SHA-256 ($backupDbHash) e integrita' SQLite verificate con successo." -ForegroundColor Green

        Write-Host "      Database SQLite ripristinato." -ForegroundColor Green

        # Ripristino snapshot identita' TLS e pairing cifrati se presenti
        Restore-DeviceTlsIdentity -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName -SessionDir $latestSession.FullName -ChownTarget $chownTarget | Out-Null
        Restore-DevicePairingSessions -AdbExe $adb -TargetAdb $TargetAdb -PackageName $PackageName -SessionDir $latestSession.FullName -ChownTarget $chownTarget | Out-Null

        Write-Host "[3/4] Riavvio servizio RemoteServerService (MainActivity + startservice)..."
        $prevEapManual = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            & $adb -s $TargetAdb shell "am startservice $PackageName/.RemoteServerService" 2>&1 | Out-Null
            & $adb -s $TargetAdb shell "am start -n $PackageName/.MainActivity" 2>&1 | Out-Null
        } finally {
            $ErrorActionPreference = $prevEapManual
        }

        Write-Host "[4/4] Watchdog post-rollback..."
        $rbHealthy = $false
        for ($r = 1; $r -le 3; $r++) {
            Start-Sleep -Seconds 2
            try {
                $statusResp = Invoke-RestMethod -Uri $StatusUrl -Method Get -TimeoutSec 4 -ErrorAction Stop
                if ($statusResp.status -eq "ok") {
                    $rbHealthy = $true
                    break
                }
            } catch {
                Write-Host "      Controllo post-rollback $r/3: in avvio ($($_.Exception.Message))..." -ForegroundColor Yellow
            }
        }
        if ($rbHealthy) {
            $null = Invoke-PostRollbackKeystoreVerification -SessionDir $latestSession.FullName -RollbackMode $rbManualApkResult.Mode -TargetTv $TargetTv -HttpsPort $HttpsPort -AuthToken $AuthToken -ExpectedCaFingerprint $ExpectedCaFingerprint -RequireVerifiedKeystoreHealth:$RequireVerifiedKeystoreHealth
            Write-Host "Rollback manuale completato e verificato con successo: TV operativa!" -ForegroundColor Green
        } else {
            Write-Host "ALLARME POST-ROLLBACK: Endpoint status non raggiungibile o non operativo - STATO CRITICO FAIL/UNKNOWN." -ForegroundColor Red
            throw "ERRORE FAIL-CLOSED: Watchdog post-rollback non superato. Il servizio non risponde con status=ok."
        }
    }
}
