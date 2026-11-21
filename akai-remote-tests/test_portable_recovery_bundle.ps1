# ==============================================================================
# AKAI Custom TV - Test Portable Encrypted Recovery Bundle (Positive & Negative)
# Cross-platform (Windows PowerShell 5.1 / Linux pwsh CI). Usa solo dati dummy.
# ==============================================================================

$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
}
Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

$repoRoot = Split-Path -Parent $PSScriptRoot
$script16 = Join-Path $repoRoot "scripts\16_export_portable_recovery_bundle.ps1"
$script05 = Join-Path $repoRoot "akai-remote-tests\05_safe_install_and_rollback.ps1"
$psExe = (Get-Process -Id $PID).Path
$isWin = [Environment]::OSVersion.Platform -match "Win"

function Get-HexSha256([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (-join ($sha.ComputeHash($Bytes) | ForEach-Object { "{0:x2}" -f $_ })).ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Protect-TestVaultBytes([byte[]]$PlainBytes, [string]$VaultDir) {
    if ($isWin) {
        $entropy = [Text.Encoding]::UTF8.GetBytes("AkaiTv_TLS_Identity_2026_DPAPI_Entropy")
        $c = [System.Security.Cryptography.ProtectedData]::Protect($PlainBytes, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        return @{ Mechanism = "DPAPI_CURRENT_USER"; CipherBytes = $c }
    }
    $mkPath = Join-Path $VaultDir ".vault_master.key"
    if (-not (Test-Path -LiteralPath $mkPath)) {
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $key = New-Object byte[] 32
        $rng.GetBytes($key)
        $rng.Dispose()
        [IO.File]::WriteAllBytes($mkPath, $key)
    } else {
        $key = [IO.File]::ReadAllBytes($mkPath)
    }
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = $key
        $aes.GenerateIV()
        $enc = $aes.CreateEncryptor()
        try {
            $encData = $enc.TransformFinalBlock($PlainBytes, 0, $PlainBytes.Length)
        } finally { $enc.Dispose() }
        $out = New-Object byte[] ($aes.IV.Length + $encData.Length)
        [Buffer]::BlockCopy($aes.IV, 0, $out, 0, $aes.IV.Length)
        [Buffer]::BlockCopy($encData, 0, $out, $aes.IV.Length, $encData.Length)
        return @{ Mechanism = "AES_256_CBC"; CipherBytes = $out }
    } finally {
        $aes.Dispose()
    }
}

$workRoot = Join-Path ([IO.Path]::GetTempPath()) ("akai_bundle_test_" + [Guid]::NewGuid().ToString("N"))
$sessionDir = Join-Path $workRoot "session_01"
$vaultBase = if ($isWin -and $env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA ("AkaiTvSecureVault_TestBundle_" + [Guid]::NewGuid().ToString("N"))
} else {
    Join-Path $workRoot "vault_linux"
}
$tlsVault = Join-Path $vaultBase "tls"
$pairVault = Join-Path $vaultBase "pairing"
$verifyScratch = Join-Path $workRoot "verify_scratch"
New-Item -ItemType Directory -Force -Path $sessionDir, (Join-Path $sessionDir "tls_identity"), (Join-Path $sessionDir "pairing_sessions"), $tlsVault, $pairVault, $verifyScratch | Out-Null

$prevPass = $env:JARVIS_RECOVERY_PASSPHRASE
$passed = 0
$failed = 0

try {
    # 1. Costruisci sessione sintetica completa con APK ZIP, DB SQLite reale, PFX+.p12.bak+CA e XML pairing
    $apkPath = Join-Path $sessionDir "it.akai.customremote_backup.apk"
    $zipFs = [IO.File]::Open($apkPath, [IO.FileMode]::Create)
    try {
        $arch = New-Object System.IO.Compression.ZipArchive($zipFs, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            $apkRng = New-Object byte[] 1024
            (New-Object System.Random 7).NextBytes($apkRng)
            foreach ($entryName in @("AndroidManifest.xml", "classes.dex")) {
                $e = $arch.CreateEntry($entryName)
                $s = $e.Open()
                try {
                    $s.Write($apkRng, 0, $apkRng.Length)
                } finally { $s.Dispose() }
            }
        } finally { $arch.Dispose() }
    } finally { $zipFs.Dispose() }

    $dbPath = Join-Path $sessionDir "akai_memory.db"
    $pyCmd = $null
    foreach ($cand in @("python3", "python", "C:\Program Files\Image-Line\FL Studio 2025\Shared\Python\python.exe")) {
        $c = Get-Command $cand -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch "WindowsApps" } | Select-Object -First 1
        if ($c) { $pyCmd = $c.Source; break }
        if ([IO.Path]::IsPathRooted($cand) -and (Test-Path -LiteralPath $cand -PathType Leaf)) { $pyCmd = $cand; break }
    }
    if ($pyCmd) {
        $pyInitDb = @'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute('CREATE TABLE facts(id INTEGER PRIMARY KEY,k TEXT,v TEXT)')
c.execute('INSERT INTO facts(k,v) VALUES(?,?)', ('k1', 'dummy_v1'))
c.commit()
c.close()
'@
        & $pyCmd -c $pyInitDb $dbPath
        if ($LASTEXITCODE -ne 0) { throw "Creazione DB test python fallita" }
    } else {
        $nodeCmd = (Get-Command node -ErrorAction Stop).Source
        & $nodeCmd -e "const {DatabaseSync}=require('node:sqlite');const db=new DatabaseSync(process.argv[1]);db.exec(`"CREATE TABLE facts(id INTEGER PRIMARY KEY,k TEXT,v TEXT);INSERT INTO facts(k,v) VALUES('k1','dummy_v1');`");db.close();" $dbPath
        if ($LASTEXITCODE -ne 0) { throw "Creazione DB test node fallita" }
    }

    # PFX reale con private key + CA X.509 + .p12.bak
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    try {
        $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new("CN=AkaiSandboxTestCA", $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $cert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(30))
        $ksPassStr = "dummy_test_pfx_pass_999"
        $pfxBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $ksPassStr)
        $caCrtBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
        $caPemBytes = [Text.Encoding]::ASCII.GetBytes("-----BEGIN CERTIFICATE-----`n" + [Convert]::ToBase64String($caCrtBytes) + "`n-----END CERTIFICATE-----`n")
        $cert.Dispose()
    } finally { $rsa.Dispose() }

    $tlsPlain = [ordered]@{
        "server_keystore.p12"     = $pfxBytes
        "server_keystore.pass"    = [Text.Encoding]::UTF8.GetBytes($ksPassStr)
        "ca.pem"                  = $caPemBytes
        "ca.crt"                  = $caCrtBytes
        "ca_key.der"              = [byte[]](1..64)
        "server_keystore.p12.bak" = $pfxBytes
    }
    $tlsFilesMeta = [ordered]@{}
    $bakMeta = $null
    foreach ($fn in $tlsPlain.Keys) {
        $pb = $tlsPlain[$fn]
        $prot = Protect-TestVaultBytes -PlainBytes $pb -VaultDir $tlsVault
        [IO.File]::WriteAllBytes((Join-Path $tlsVault "$fn.enc"), $prot.CipherBytes)
        $meta = [ordered]@{
            Sha256 = (Get-HexSha256 $pb)
            SizeBytes = $pb.Length
            Encrypted = $true
            CipherSha256 = (Get-HexSha256 $prot.CipherBytes)
            Mechanism = $prot.Mechanism
        }
        if ($fn -eq "server_keystore.p12.bak") {
            $bakMeta = $meta
        } else {
            $tlsFilesMeta[$fn] = $meta
        }
    }
    $tlsManifest = [ordered]@{
        Version = 1
        Files = $tlsFilesMeta
        KeystoreSha256 = $tlsFilesMeta."server_keystore.p12".Sha256
        HasKeystoreBak = $true
        KeystoreBak = $bakMeta
    }
    [IO.File]::WriteAllText((Join-Path $sessionDir "tls_identity\tls_manifest.json"), ($tlsManifest | ConvertTo-Json -Depth 5))
    [IO.File]::WriteAllText((Join-Path $sessionDir "tls_identity\vault_pointer.json"), (@{ VaultDir = $tlsVault } | ConvertTo-Json))

    $pairPlain = [ordered]@{
        "akai_remote_sessions.xml"    = [Text.Encoding]::UTF8.GetBytes("<?xml version='1.0' encoding='utf-8' standalone='yes' ?><map><string name=`"dummy_tok`">dummy_session_val</string></map>")
        "akai_ai_security_prefs.xml"  = [Text.Encoding]::UTF8.GetBytes("<?xml version='1.0' encoding='utf-8' standalone='yes' ?><map><string name=`"sec_enc_deepseek_key`">ks:dummycipher</string></map>")
    }
    $pairFilesMeta = [ordered]@{}
    foreach ($pn in $pairPlain.Keys) {
        $pb = $pairPlain[$pn]
        $prot = Protect-TestVaultBytes -PlainBytes $pb -VaultDir $pairVault
        [IO.File]::WriteAllBytes((Join-Path $pairVault "$pn.enc"), $prot.CipherBytes)
        $pairFilesMeta[$pn] = [ordered]@{
            Sha256 = (Get-HexSha256 $pb)
            SizeBytes = $pb.Length
            Encrypted = $true
            CipherSha256 = (Get-HexSha256 $prot.CipherBytes)
            Mechanism = $prot.Mechanism
        }
    }
    [IO.File]::WriteAllText((Join-Path $sessionDir "pairing_sessions\pairing_manifest.json"), (@{ Version = 1; Files = $pairFilesMeta } | ConvertTo-Json -Depth 5))
    [IO.File]::WriteAllText((Join-Path $sessionDir "pairing_sessions\vault_pointer.json"), (@{ VaultDir = $pairVault } | ConvertTo-Json))

    $bundlePath = Join-Path $workRoot "recovery_bundle.akv.json"
    $env:JARVIS_RECOVERY_PASSPHRASE = "Correct_Test_Bundle_Passphrase_2026!"

    function Invoke-Script16([string[]]$ScriptArgs) {
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $psCallArgs = if ($isWin) { @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script16) } else { @("-NoProfile", "-File", $script16) }
            $out = (& $psExe @psCallArgs @ScriptArgs 2>&1 | Out-String)
            $norm = ($out -replace '\s+', ' ').Trim()
            return @{ ExitCode = $LASTEXITCODE; Output = $out; Normalized = $norm }
        } finally {
            $ErrorActionPreference = $prevEap
        }
    }

    # Test 1: Export + offline verify PASS + zero leftovers
    $expRes = Invoke-Script16 @("-Action", "export", "-BackupSessionDir", $sessionDir, "-OutputBundlePath", $bundlePath)
    if ($expRes.ExitCode -ne 0) { throw "Export fallito (exit=$($expRes.ExitCode)): $($expRes.Output)" }
    $bundleRaw = Get-Content -LiteralPath $bundlePath -Raw
    if ($bundleRaw -match "dummy_test_pfx_pass_999|dummy_session_val|ks:dummycipher") {
        throw "Plaintext secret trovato nel bundle JSON!"
    }
    $verRes = Invoke-Script16 @("-Action", "verify-restore-offline", "-BundlePath", $bundlePath, "-VerificationTempRoot", $verifyScratch)
    if ($verRes.ExitCode -ne 0) { throw "verify-restore-offline fallito (exit=$($verRes.ExitCode)): $($verRes.Output)" }
    $verObj = ($verRes.Output | ConvertFrom-Json)
    $leftovers = @(Get-ChildItem -LiteralPath $verifyScratch -Force)
    if ($verObj.status -eq "OFFLINE_RESTORE_VERIFIED" -and $verObj.sqliteIntegrity -eq "ok" -and $verObj.pkcs12HasPrivateKey -eq $true -and $verObj.keystoreBakVerified -eq $true -and $verObj.xmlFilesVerified -eq 2 -and $leftovers.Count -eq 0) {
        Write-Host "[PASS] Bundle Test 1: Export cifrato + verify-restore-offline (SQLite, PKCS#12+.bak, CA, XML) + zero leftovers OK" -ForegroundColor Green
        $passed++
    } else {
        throw "Output verify non conforme: $($verRes.Output) (leftovers=$($leftovers.Count))"
    }

    # Test 2: Wrong passphrase fails HMAC
    $env:JARVIS_RECOVERY_PASSPHRASE = "Wrong_Test_Bundle_Passphrase_2026!!"
    $wrongRes = Invoke-Script16 @("-Action", "verify-restore-offline", "-BundlePath", $bundlePath, "-VerificationTempRoot", $verifyScratch)
    if ($wrongRes.ExitCode -ne 0 -and $wrongRes.Normalized -match "Autenticazione HMAC fallita") {
        Write-Host "[PASS] Bundle Test 2: Passphrase errata bloccata in Fail-Closed" -ForegroundColor Green
        $passed++
    } else {
        throw "Passphrase errata non bloccata (exit=$($wrongRes.ExitCode)): $($wrongRes.Output)"
    }

    # Test 3: 1-bit tamper in ciphertext fails HMAC before decrypt
    $env:JARVIS_RECOVERY_PASSPHRASE = "Correct_Test_Bundle_Passphrase_2026!"
    $tamperedBundle = Join-Path $workRoot "tampered_bundle.akv.json"
    $envJson = Get-Content -LiteralPath $bundlePath -Raw | ConvertFrom-Json
    $cBytesTamper = [Convert]::FromBase64String($envJson.cipherB64)
    $cBytesTamper[0] = $cBytesTamper[0] -bxor 0x01
    $envJson.cipherB64 = [Convert]::ToBase64String($cBytesTamper)
    [IO.File]::WriteAllText($tamperedBundle, ($envJson | ConvertTo-Json -Depth 4))
    $tamperRes = Invoke-Script16 @("-Action", "verify-restore-offline", "-BundlePath", $tamperedBundle, "-VerificationTempRoot", $verifyScratch)
    if ($tamperRes.ExitCode -ne 0 -and $tamperRes.Normalized -match "Autenticazione HMAC fallita") {
        Write-Host "[PASS] Bundle Test 3: Bit-flip ciphertext bloccato pre-decifratura da HMAC" -ForegroundColor Green
        $passed++
    } else {
        throw "Bit-flip non bloccato (exit=$($tamperRes.ExitCode)): $($tamperRes.Output)"
    }

    # Test 4: Short passphrase rejected
    $env:JARVIS_RECOVERY_PASSPHRASE = "too_short_123"
    $shortRes = Invoke-Script16 @("-Action", "verify-restore-offline", "-BundlePath", $bundlePath)
    if ($shortRes.ExitCode -ne 0 -and $shortRes.Normalized -match "almeno 20 caratteri") {
        Write-Host "[PASS] Bundle Test 4: Passphrase < 20 caratteri bloccata" -ForegroundColor Green
        $passed++
    } else {
        throw "Passphrase corta non bloccata (exit=$($shortRes.ExitCode)): $($shortRes.Output)"
    }

    # Test 5: Repo path & Cloud-sync path rejected
    $env:JARVIS_RECOVERY_PASSPHRASE = "Correct_Test_Bundle_Passphrase_2026!"
    $repoRes = Invoke-Script16 @("-Action", "export", "-BackupSessionDir", $sessionDir, "-OutputBundlePath", (Join-Path $repoRoot "forbidden_bundle.akv.json"))
    $cloudTarget = Join-Path (Join-Path $workRoot "OneDrive") "forbidden_bundle.akv.json"
    $cloudRes = Invoke-Script16 @("-Action", "export", "-BackupSessionDir", $sessionDir, "-OutputBundlePath", $cloudTarget)
    if ($repoRes.ExitCode -ne 0 -and $repoRes.Normalized -match "dentro il repository Git vietato" -and $cloudRes.ExitCode -ne 0 -and $cloudRes.Normalized -match "cloud-sync vietato") {
        Write-Host "[PASS] Bundle Test 5: Percorsi in Git repo e cloud-sync bloccati" -ForegroundColor Green
        $passed++
    } else {
        throw "Guardie percorso non scattate: repo='$($repoRes.Output)' cloud='$($cloudRes.Output)'"
    }
} catch {
    Write-Host "[FAIL] Errore test portable recovery bundle: $($_.Exception.Message)" -ForegroundColor Red
    $failed++
} finally {
    if ($null -eq $prevPass) { Remove-Item Env:JARVIS_RECOVERY_PASSPHRASE -ErrorAction SilentlyContinue } else { $env:JARVIS_RECOVERY_PASSPHRASE = $prevPass }
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $vaultBase) { Remove-Item -LiteralPath $vaultBase -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "ESITO PORTABLE RECOVERY BUNDLE TESTS: PASS=$passed FAIL=$failed"
if ($failed -gt 0 -or $passed -ne 5) { exit 1 }
exit 0
