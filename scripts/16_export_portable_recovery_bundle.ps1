# ==============================================================================
# AKAI Custom TV - Script 16: PORTABLE ENCRYPTED RECOVERY BUNDLE & OFFLINE VERIFY
# Esporta una sessione di backup locale (incluso vault DPAPI/AES) in un archivio
# portatile cifrato Encrypt-then-MAC (PBKDF2-HMAC-SHA256 210k + AES-256-CBC + HMAC)
# e ne verifica offline il ripristino completo senza lasciare plaintext su disco.
# Zero comandi ADB; zero trasmissioni di rete; mai percorsi nel repo/cloud.
# ==============================================================================

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("export", "verify-restore-offline")]
    [string]$Action,
    [string]$BackupSessionDir = $null,
    [string]$OutputBundlePath = $null,
    [string]$BundlePath = $null,
    [string]$VerificationTempRoot = $null
)

$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
}
Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

$repoRoot = Split-Path -Parent $PSScriptRoot
$pbkdf2Iterations = 210000

function Resolve-PhysicalCanonicalPath {
    param([string]$CandidatePath)
    $full = [IO.Path]::GetFullPath($CandidatePath)
    $tailParts = New-Object System.Collections.Generic.List[string]
    $probe = $full
    while ($probe -and -not (Test-Path -LiteralPath $probe)) {
        $leaf = Split-Path -Leaf $probe
        $parent = Split-Path -Parent $probe
        if (-not $leaf -or $parent -eq $probe) { break }
        [void]$tailParts.Add($leaf)
        $probe = $parent
    }

    if ($probe -and (Test-Path -LiteralPath $probe)) {
        if ([Environment]::OSVersion.Platform -match "Win") {
            $typeDef = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class AkaiPortablePathHelper {
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
            if (-not ("AkaiPortablePathHelper" -as [type])) {
                Add-Type -TypeDefinition $typeDef -Language CSharp
            }
            $cur = $probe
            while (-not [string]::IsNullOrWhiteSpace($cur)) {
                $gi = Get-Item -LiteralPath $cur -Force -ErrorAction SilentlyContinue
                if ($gi -and ($gi.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    $repTarget = [AkaiPortablePathHelper]::GetFinalPath($cur)
                    if ($repTarget -match "(?i)(OneDrive|Dropbox|Google Drive|iCloud|Nextcloud)") {
                        throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Reparse point verso cloud-sync vietato ($cur -> $repTarget)."
                    }
                }
                $pNext = Split-Path -Parent $cur
                if ($pNext -eq $cur) { break }
                $cur = $pNext
            }
            $probe = [AkaiPortablePathHelper]::GetFinalPath($probe)
        } else {
            $cur = $probe
            while (-not [string]::IsNullOrWhiteSpace($cur)) {
                $gi = Get-Item -LiteralPath $cur -Force -ErrorAction SilentlyContinue
                if ($gi -and ($gi.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    $rt = $gi.ResolveLinkTarget($true)
                    if ($rt -and $rt.FullName -match "(?i)(OneDrive|Dropbox|Google Drive|iCloud|Nextcloud)") {
                        throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Reparse point verso cloud-sync vietato ($cur -> $($rt.FullName))."
                    }
                }
                $pNext = Split-Path -Parent $cur
                if ($pNext -eq $cur) { break }
                $cur = $pNext
            }
            $rpCmd = Get-Command realpath -ErrorAction SilentlyContinue
            if ($rpCmd) {
                $rpOut = (& $rpCmd.Source $probe 2>&1 | Out-String).Trim()
                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($rpOut)) {
                    $probe = $rpOut
                }
            } else {
                $giTop = Get-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
                if ($giTop) {
                    $rtTop = $giTop.ResolveLinkTarget($true)
                    if ($rtTop) { $probe = $rtTop.FullName }
                }
            }
        }
    }

    $phys = $probe
    for ($i = $tailParts.Count - 1; $i -ge 0; $i--) {
        $phys = Join-Path $phys $tailParts[$i]
    }
    return [IO.Path]::GetFullPath($phys)
}

function Assert-SafeExternalPath {
    param(
        [string]$CandidatePath,
        [string]$Label,
        [string]$RepositoryRoot,
        [switch]$AllowExisting
    )
    if ([string]::IsNullOrWhiteSpace($CandidatePath)) {
        throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Percorso $Label mancante."
    }
    $full = [IO.Path]::GetFullPath($CandidatePath)
    $physFull = Resolve-PhysicalCanonicalPath -CandidatePath $full
    $normRepo = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/')
    $physRepo = (Resolve-PhysicalCanonicalPath -CandidatePath $normRepo).TrimEnd('\', '/')

    foreach ($p in @($full, $physFull)) {
        $normP = $p.TrimEnd('\', '/')
        foreach ($r in @($normRepo, $physRepo)) {
            if ($normP -eq $r -or $normP.StartsWith($r + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Percorso $Label dentro il repository Git vietato ($full -> $physFull)."
            }
        }
        if ($p -match "(?i)(OneDrive|Dropbox|Google Drive|iCloud|Nextcloud)") {
            throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Percorso $Label in cartella cloud-sync vietato ($full -> $physFull)."
        }
    }

    if (-not $AllowExisting -and (Test-Path -LiteralPath $full)) {
        throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Destinazione $Label gia' esistente ($full)."
    }
    return $full
}

function Get-RecoveryPassphraseBytes {
    $raw = $env:JARVIS_RECOVERY_PASSPHRASE
    if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Length -lt 20) {
        throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Impostare JARVIS_RECOVERY_PASSPHRASE con almeno 20 caratteri."
    }
    return [Text.Encoding]::UTF8.GetBytes($raw)
}

function Get-BytesSha256Hex {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (-join ($sha.ComputeHash($Bytes) | ForEach-Object { "{0:x2}" -f $_ })).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Protect-BundleBytesWithPassphrase {
    param([byte[]]$PlainBytes, [byte[]]$PassBytes)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $salt = New-Object byte[] 32
    $iv = New-Object byte[] 16
    $derived = $null
    $encKey = New-Object byte[] 32
    $macKey = New-Object byte[] 32
    try {
        $rng.GetBytes($salt)
        $rng.GetBytes($iv)
        $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($PassBytes, $salt, $pbkdf2Iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        try {
            $derived = $kdf.GetBytes(64)
        } finally {
            $kdf.Dispose()
        }
        [Array]::Copy($derived, 0, $encKey, 0, 32)
        [Array]::Copy($derived, 32, $macKey, 0, 32)

        $cipherBytes = $null
        $aes = [System.Security.Cryptography.Aes]::Create()
        try {
            $aes.KeySize = 256
            $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
            $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
            $aes.Key = $encKey
            $aes.IV = $iv
            $ms = New-Object System.IO.MemoryStream
            try {
                $cs = New-Object System.Security.Cryptography.CryptoStream($ms, $aes.CreateEncryptor(), [System.Security.Cryptography.CryptoStreamMode]::Write)
                try {
                    $cs.Write($PlainBytes, 0, $PlainBytes.Length)
                    $cs.FlushFinalBlock()
                } finally {
                    $cs.Dispose()
                }
                $cipherBytes = $ms.ToArray()
            } finally {
                $ms.Dispose()
            }
        } finally {
            $aes.Dispose()
        }

        $saltB64 = [Convert]::ToBase64String($salt)
        $ivB64 = [Convert]::ToBase64String($iv)
        $cipherB64 = [Convert]::ToBase64String($cipherBytes)
        $authString = "JARVIS_RECOVERY_V1:$pbkdf2Iterations`:$saltB64`:$ivB64`:$cipherB64"
        $hmac = New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList @(,$macKey)
        try {
            $tagBytes = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($authString))
        } finally {
            $hmac.Dispose()
        }

        return [ordered]@{
            format = "jarvis-portable-recovery-v1"
            kdf = "PBKDF2-HMAC-SHA256"
            iterations = $pbkdf2Iterations
            cipher = "AES-256-CBC+HMAC-SHA256"
            saltB64 = $saltB64
            ivB64 = $ivB64
            cipherB64 = $cipherB64
            hmacB64 = [Convert]::ToBase64String($tagBytes)
        }
    } finally {
        $rng.Dispose()
        [Array]::Clear($salt, 0, $salt.Length)
        [Array]::Clear($iv, 0, $iv.Length)
        [Array]::Clear($encKey, 0, $encKey.Length)
        [Array]::Clear($macKey, 0, $macKey.Length)
        if ($derived) { [Array]::Clear($derived, 0, $derived.Length) }
    }
}

function Unprotect-BundleBytesWithPassphrase {
    param($Envelope, [byte[]]$PassBytes)
    if (-not $Envelope -or $Envelope.format -ne "jarvis-portable-recovery-v1") {
        throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Formato bundle sconosciuto o non supportato."
    }
    $iters = [int]$Envelope.iterations
    if ($iters -lt 100000) {
        throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Iterazioni KDF insufficienti ($iters)."
    }
    $salt = [Convert]::FromBase64String([string]$Envelope.saltB64)
    $iv = [Convert]::FromBase64String([string]$Envelope.ivB64)
    $cipherBytes = [Convert]::FromBase64String([string]$Envelope.cipherB64)
    $expectedMac = [Convert]::FromBase64String([string]$Envelope.hmacB64)
    if ($salt.Length -ne 32 -or $iv.Length -ne 16 -or $expectedMac.Length -ne 32) {
        throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Parametri crittografici corrotti nel bundle."
    }

    $derived = $null
    $encKey = New-Object byte[] 32
    $macKey = New-Object byte[] 32
    try {
        $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($PassBytes, $salt, $iters, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        try {
            $derived = $kdf.GetBytes(64)
        } finally {
            $kdf.Dispose()
        }
        [Array]::Copy($derived, 0, $encKey, 0, 32)
        [Array]::Copy($derived, 32, $macKey, 0, 32)

        $authString = "JARVIS_RECOVERY_V1:$iters`:$($Envelope.saltB64)`:$($Envelope.ivB64)`:$($Envelope.cipherB64)"
        $actualMac = $null
        $hmac = New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList @(,$macKey)
        try {
            $actualMac = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($authString))
        } finally {
            $hmac.Dispose()
        }

        if ($actualMac.Length -ne $expectedMac.Length) {
            throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Autenticazione HMAC fallita (passphrase errata o bundle manomesso)."
        }
        $diff = 0
        for ($i = 0; $i -lt $expectedMac.Length; $i++) {
            $diff = $diff -bor ($expectedMac[$i] -bxor $actualMac[$i])
        }
        if ($diff -ne 0) {
            throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Autenticazione HMAC fallita (passphrase errata o bundle manomesso)."
        }

        $aes = [System.Security.Cryptography.Aes]::Create()
        try {
            $aes.KeySize = 256
            $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
            $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
            $aes.Key = $encKey
            $aes.IV = $iv
            $outMs = New-Object System.IO.MemoryStream
            try {
                $inMs = New-Object System.IO.MemoryStream -ArgumentList @(,$cipherBytes)
                try {
                    $cs = New-Object System.Security.Cryptography.CryptoStream($inMs, $aes.CreateDecryptor(), [System.Security.Cryptography.CryptoStreamMode]::Read)
                    try {
                        $cs.CopyTo($outMs)
                    } finally {
                        $cs.Dispose()
                    }
                } finally {
                    $inMs.Dispose()
                }
                return $outMs.ToArray()
            } finally {
                $outMs.Dispose()
            }
        } finally {
            $aes.Dispose()
        }
    } finally {
        [Array]::Clear($encKey, 0, $encKey.Length)
        [Array]::Clear($macKey, 0, $macKey.Length)
        if ($derived) { [Array]::Clear($derived, 0, $derived.Length) }
    }
}

function Unprotect-LocalVaultEntryBytes {
    param(
        [byte[]]$CipherBytes,
        [string]$Mechanism,
        [string]$VaultDir
    )
    if ($Mechanism -eq "DPAPI_CURRENT_USER") {
        if ([Environment]::OSVersion.Platform -notmatch "Win") {
            throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Vault protetto con DPAPI_CURRENT_USER decifrabile solo su Windows nello stesso profilo utente prima dell'export."
        }
        $entropy = [Text.Encoding]::UTF8.GetBytes("AkaiTv_TLS_Identity_2026_DPAPI_Entropy")
        return [System.Security.Cryptography.ProtectedData]::Unprotect($CipherBytes, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    }
    if ($Mechanism -eq "AES_256_CBC") {
        $masterPath = Join-Path $VaultDir ".vault_master.key"
        if (-not (Test-Path -LiteralPath $masterPath -PathType Leaf)) {
            throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Master key Linux vault mancante: $masterPath"
        }
        if ($CipherBytes.Length -lt 17) {
            throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Payload AES_256_CBC vault troncato."
        }
        $keyBytes = [IO.File]::ReadAllBytes($masterPath)
        $iv = New-Object byte[] 16
        [Buffer]::BlockCopy($CipherBytes, 0, $iv, 0, 16)
        $aes = [System.Security.Cryptography.Aes]::Create()
        try {
            $aes.Key = $keyBytes
            $aes.IV = $iv
            $dec = $aes.CreateDecryptor()
            try {
                return $dec.TransformFinalBlock($CipherBytes, 16, $CipherBytes.Length - 16)
            } finally {
                $dec.Dispose()
            }
        } finally {
            $aes.Dispose()
            [Array]::Clear($keyBytes, 0, $keyBytes.Length)
        }
    }
    throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Meccanismo vault sconosciuto ($Mechanism)."
}

function Resolve-VaultDirectory {
    param([string]$SubSessionDir, $Manifest = $null)
    $ptrPath = Join-Path $SubSessionDir "vault_pointer.json"
    if (Test-Path -LiteralPath $ptrPath -PathType Leaf) {
        $ptr = Get-Content -LiteralPath $ptrPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($ptr.VaultDir -and (Test-Path -LiteralPath $ptr.VaultDir -PathType Container)) {
            return $ptr.VaultDir
        }
    }
    if ($Manifest -and $Manifest.VaultDir -and (Test-Path -LiteralPath $Manifest.VaultDir -PathType Container)) {
        return $Manifest.VaultDir
    }
    return $SubSessionDir
}

function Set-PrivateFileAclWindows {
    param([string]$FilePath)
    if ([Environment]::OSVersion.Platform -notmatch "Win") { return }
    try {
        $fi = New-Object System.IO.FileInfo($FilePath)
        $acl = $fi.GetAccessControl()
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($r in @($acl.Access)) { [void]$acl.RemoveAccessRule($r) }
        $idRef = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($idRef, [System.Security.AccessControl.FileSystemRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow)
        $acl.SetAccessRule($rule)
        $fi.SetAccessControl($acl)
    } catch {
        throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Impossibile applicare ACL esclusiva su $FilePath ($($_.Exception.Message))."
    }
}

function Clear-ZeroizedDirectory {
    param([string]$TargetDir)
    if ([string]::IsNullOrWhiteSpace($TargetDir) -or -not (Test-Path -LiteralPath $TargetDir)) { return }
    try {
        Get-ChildItem -LiteralPath $TargetDir -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                if ($_.Length -gt 0) {
                    $zero = New-Object byte[] ([Math]::Min($_.Length, 1048576))
                    $fs = [IO.File]::Open($_.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    try {
                        $rem = $_.Length
                        while ($rem -gt 0) {
                            $chunk = [Math]::Min($rem, $zero.Length)
                            $fs.Write($zero, 0, [int]$chunk)
                            $rem -= $chunk
                        }
                        $fs.Flush()
                    } finally {
                        $fs.Dispose()
                    }
                }
            } catch {
            }
        }
    } finally {
        Remove-Item -LiteralPath $TargetDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-SQLiteOfflineIntegrityCheck {
    param([string]$DbPath)
    $pyCmd = $null
    foreach ($cand in @("python3", "python", "C:\Program Files\Image-Line\FL Studio 2025\Shared\Python\python.exe")) {
        $cmd = Get-Command $cand -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch "WindowsApps" } | Select-Object -First 1
        if ($cmd) { $pyCmd = $cmd.Source; break }
        if ([IO.Path]::IsPathRooted($cand) -and (Test-Path -LiteralPath $cand -PathType Leaf)) { $pyCmd = $cand; break }
    }
    if ($pyCmd) {
        $pySrc = @'
import sqlite3, json, sys
conn = sqlite3.connect(sys.argv[2])
try:
    res = [r[0] for r in conn.execute('PRAGMA integrity_check;').fetchall()]
    tables = [r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()]
finally:
    conn.close()
print(json.dumps({'integrity': res, 'tables': len(tables)}))
'@
        $pyB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pySrc))
        $raw = (& $pyCmd -c "import base64,sys;exec(base64.b64decode(sys.argv[1]).decode())" $pyB64 $DbPath 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Verifica SQLite python fallita ($raw)."
        }
        $obj = $raw | ConvertFrom-Json
        if (@($obj.integrity).Count -ne 1 -or $obj.integrity[0] -ne "ok") {
            throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: SQLite PRAGMA integrity_check fallito ($raw)."
        }
        return [int]$obj.tables
    }

    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if ($nodeCmd) {
        $jsSrc = @'
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(process.argv[2]);
try {
  const r = db.prepare('PRAGMA integrity_check').all();
  const t = db.prepare("SELECT count(*) AS c FROM sqlite_master WHERE type='table'").get();
  console.log(JSON.stringify({ integrity: r.map(x => Object.values(x)[0]), tables: t.c }));
} finally {
  db.close();
}
'@
        $jsB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($jsSrc))
        $raw = (& $nodeCmd.Source -e "eval(Buffer.from(process.argv[1],'base64').toString())" $jsB64 $DbPath 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Verifica SQLite node fallita ($raw)."
        }
        $obj = $raw | ConvertFrom-Json
        if (@($obj.integrity).Count -ne 1 -or $obj.integrity[0] -ne "ok") {
            throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: SQLite PRAGMA integrity_check fallito ($raw)."
        }
        return [int]$obj.tables
    }
    throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Nessun engine SQLite offline (python3/node:sqlite) disponibile per PRAGMA integrity_check."
}

$passBytes = Get-RecoveryPassphraseBytes
try {
    if ($Action -eq "export") {
        if ([string]::IsNullOrWhiteSpace($BackupSessionDir) -or -not (Test-Path -LiteralPath $BackupSessionDir -PathType Container)) {
            throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: BackupSessionDir mancante o non valido ($BackupSessionDir)."
        }
        $normSession = Assert-SafeExternalPath -CandidatePath $BackupSessionDir -Label "BackupSessionDir" -RepositoryRoot $repoRoot -AllowExisting
        $normOut = Assert-SafeExternalPath -CandidatePath $OutputBundlePath -Label "OutputBundlePath" -RepositoryRoot $repoRoot
        $outParent = Split-Path -Parent $normOut
        if (-not (Test-Path -LiteralPath $outParent)) {
            New-Item -ItemType Directory -Force -Path $outParent | Out-Null
        }

        $entries = [System.Collections.Generic.List[object]]::new()
        $sensitiveBuffers = [System.Collections.Generic.List[byte[]]]::new()
        try {
            $apkPath = Join-Path $normSession "it.akai.customremote_backup.apk"
            $dbPath = Join-Path $normSession "akai_memory.db"
            if (-not (Test-Path -LiteralPath $apkPath -PathType Leaf) -or (Get-Item -LiteralPath $apkPath).Length -lt 512) {
                throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: APK backup mancante o corrotto in $apkPath"
            }
            if (-not (Test-Path -LiteralPath $dbPath -PathType Leaf) -or (Get-Item -LiteralPath $dbPath).Length -lt 512) {
                throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Database akai_memory.db mancante o corrotto in $dbPath"
            }
            foreach ($coreRel in @("it.akai.customremote_backup.apk", "akai_memory.db", "akai_memory.db-wal")) {
                $fp = Join-Path $normSession $coreRel
                if (Test-Path -LiteralPath $fp -PathType Leaf) {
                    $rawBytes = [IO.File]::ReadAllBytes($fp)
                    [void]$sensitiveBuffers.Add($rawBytes)
                    [void]$entries.Add([ordered]@{
                        logicalPath = "session/$coreRel"
                        category = "core"
                        sha256 = (Get-BytesSha256Hex -Bytes $rawBytes)
                        sizeBytes = $rawBytes.Length
                        dataB64 = [Convert]::ToBase64String($rawBytes)
                    })
                }
            }

            # TLS Identity (.enc in vault -> decifratura in RAM e inclusione sicura nel bundle cifrato portatile)
            $tlsSubDir = Join-Path $normSession "tls_identity"
            $tlsManifestPath = Join-Path $tlsSubDir "tls_manifest.json"
            if (-not (Test-Path -LiteralPath $tlsManifestPath -PathType Leaf)) {
                throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: tls_manifest.json mancante in $tlsSubDir"
            }
            $tlsManifest = Get-Content -LiteralPath $tlsManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $tlsVaultDir = Resolve-VaultDirectory -SubSessionDir $tlsSubDir -Manifest $tlsManifest
            foreach ($fName in @("server_keystore.p12", "server_keystore.pass", "ca.pem", "ca.crt", "ca_key.der")) {
                $fMeta = $tlsManifest.Files.$fName
                if (-not $fMeta) { throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Voce TLS obbligatoria $fName assente nel manifest." }
                $encPath = Join-Path $tlsVaultDir "$fName.enc"
                if (-not (Test-Path -LiteralPath $encPath -PathType Leaf)) {
                    throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Asset cifrato $fName.enc mancante in $tlsVaultDir"
                }
                $cBytes = [IO.File]::ReadAllBytes($encPath)
                $pBytes = Unprotect-LocalVaultEntryBytes -CipherBytes $cBytes -Mechanism $fMeta.Mechanism -VaultDir $tlsVaultDir
                [void]$sensitiveBuffers.Add($pBytes)
                $pHash = Get-BytesSha256Hex -Bytes $pBytes
                if ($pHash -ne $fMeta.Sha256) {
                    throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Hash TLS mismatch su $fName durante export."
                }
                [void]$entries.Add([ordered]@{
                    logicalPath = "tls/$fName"
                    category = "tls"
                    sha256 = $pHash
                    sizeBytes = $pBytes.Length
                    dataB64 = [Convert]::ToBase64String($pBytes)
                })
            }
            if ($tlsManifest.HasKeystoreBak -eq $true -and $tlsManifest.KeystoreBak) {
                $bakEnc = Join-Path $tlsVaultDir "server_keystore.p12.bak.enc"
                if (-not (Test-Path -LiteralPath $bakEnc -PathType Leaf)) {
                    throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Keystore .bak dichiarato nel manifest ma assente in $bakEnc"
                }
                $cBak = [IO.File]::ReadAllBytes($bakEnc)
                $pBak = Unprotect-LocalVaultEntryBytes -CipherBytes $cBak -Mechanism $tlsManifest.KeystoreBak.Mechanism -VaultDir $tlsVaultDir
                [void]$sensitiveBuffers.Add($pBak)
                $bakHash = Get-BytesSha256Hex -Bytes $pBak
                if ($bakHash -ne $tlsManifest.KeystoreBak.Sha256) {
                    throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Hash TLS mismatch su server_keystore.p12.bak durante export."
                }
                [void]$entries.Add([ordered]@{
                    logicalPath = "tls/server_keystore.p12.bak"
                    category = "tls"
                    sha256 = $bakHash
                    sizeBytes = $pBak.Length
                    dataB64 = [Convert]::ToBase64String($pBak)
                })
            }

            # Pairing / AI Preferences XML (.enc in vault)
            $pairSubDir = Join-Path $normSession "pairing_sessions"
            $pairManifestPath = Join-Path $pairSubDir "pairing_manifest.json"
            if (-not (Test-Path -LiteralPath $pairManifestPath -PathType Leaf)) {
                throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: pairing_manifest.json mancante in $pairSubDir"
            }
            $pairManifest = Get-Content -LiteralPath $pairManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $pairVaultDir = Resolve-VaultDirectory -SubSessionDir $pairSubDir -Manifest $pairManifest
            foreach ($prop in $pairManifest.Files.PSObject.Properties) {
                $xmlName = $prop.Name
                $xmlMeta = $prop.Value
                $encXml = Join-Path $pairVaultDir "$xmlName.enc"
                if (-not (Test-Path -LiteralPath $encXml -PathType Leaf)) {
                    throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Preferenza cifrata $xmlName.enc mancante in $pairVaultDir"
                }
                $cXml = [IO.File]::ReadAllBytes($encXml)
                $pXml = Unprotect-LocalVaultEntryBytes -CipherBytes $cXml -Mechanism $xmlMeta.Mechanism -VaultDir $pairVaultDir
                [void]$sensitiveBuffers.Add($pXml)
                $xmlHash = Get-BytesSha256Hex -Bytes $pXml
                if ($xmlHash -ne $xmlMeta.Sha256) {
                    throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Hash mismatch pairing XML su $xmlName durante export."
                }
                [void]$entries.Add([ordered]@{
                    logicalPath = "pairing/$xmlName"
                    category = "pairing"
                    sha256 = $xmlHash
                    sizeBytes = $pXml.Length
                    dataB64 = [Convert]::ToBase64String($pXml)
                })
            }

            $payloadObj = [ordered]@{
                bundleVersion = 1
                sourceSessionName = (Split-Path -Leaf $normSession)
                exportedAtUtc = ([DateTime]::UtcNow.ToString("o"))
                tlsRootCaSha256 = [string]$tlsManifest.Files."ca.crt".Sha256
                hasKeystoreBak = [bool]$tlsManifest.HasKeystoreBak
                entries = $entries
            }
            $payloadJson = ($payloadObj | ConvertTo-Json -Depth 6 -Compress)
            $payloadBytes = [Text.Encoding]::UTF8.GetBytes($payloadJson)
            [void]$sensitiveBuffers.Add($payloadBytes)

            $envelope = Protect-BundleBytesWithPassphrase -PlainBytes $payloadBytes -PassBytes $passBytes
            $envelopeJson = ($envelope | ConvertTo-Json -Depth 4)
            [IO.File]::WriteAllText($normOut, $envelopeJson, [Text.UTF8Encoding]::new($false))
            Set-PrivateFileAclWindows -FilePath $normOut

            $outSha = Get-BytesSha256Hex -Bytes ([IO.File]::ReadAllBytes($normOut))
            $summary = [ordered]@{
                action = "export"
                status = "EXPORTED_ENCRYPTED_BUNDLE"
                bundlePath = $normOut
                bundleSha256 = $outSha
                entryCount = $entries.Count
                hasKeystoreBak = [bool]$tlsManifest.HasKeystoreBak
            }
            Write-Output ($summary | ConvertTo-Json -Depth 4)
        } finally {
            foreach ($buf in $sensitiveBuffers) {
                if ($buf) { [Array]::Clear($buf, 0, $buf.Length) }
            }
        }
    } elseif ($Action -eq "verify-restore-offline") {
        if ([string]::IsNullOrWhiteSpace($BundlePath) -or -not (Test-Path -LiteralPath $BundlePath -PathType Leaf)) {
            throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: BundlePath mancante o inesistente ($BundlePath)."
        }
        $normBundle = Assert-SafeExternalPath -CandidatePath $BundlePath -Label "BundlePath" -RepositoryRoot $repoRoot -AllowExisting
        $tempBase = if (-not [string]::IsNullOrWhiteSpace($VerificationTempRoot)) {
            Assert-SafeExternalPath -CandidatePath $VerificationTempRoot -Label "VerificationTempRoot" -RepositoryRoot $repoRoot -AllowExisting
        } else {
            [IO.Path]::GetTempPath()
        }
        $ephemeralDir = Join-Path $tempBase ("jarvis_verify_bundle_" + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Force -Path $ephemeralDir | Out-Null

        $decBytes = $null
        try {
            $envObj = Get-Content -LiteralPath $normBundle -Raw -Encoding UTF8 | ConvertFrom-Json
            $decBytes = Unprotect-BundleBytesWithPassphrase -Envelope $envObj -PassBytes $passBytes
            $payload = ([Text.Encoding]::UTF8.GetString($decBytes)) | ConvertFrom-Json

            $written = @{}
            foreach ($entry in $payload.entries) {
                $rel = ([string]$entry.logicalPath).Replace('\', '/')
                if ($rel -match '(^/|\.\.)' -or $rel -notmatch '^[a-zA-Z0-9._/-]+$') {
                    throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: logicalPath non valido nel bundle ($rel)."
                }
                $destPath = Join-Path $ephemeralDir ($rel.Replace('/', [IO.Path]::DirectorySeparatorChar))
                $destParent = Split-Path -Parent $destPath
                if (-not (Test-Path -LiteralPath $destParent)) {
                    New-Item -ItemType Directory -Force -Path $destParent | Out-Null
                }
                $rawBytes = [Convert]::FromBase64String([string]$entry.dataB64)
                $actualHash = Get-BytesSha256Hex -Bytes $rawBytes
                if ($actualHash -ne $entry.sha256) {
                    throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: SHA-256 mismatch interno per $rel."
                }
                [IO.File]::WriteAllBytes($destPath, $rawBytes)
                $written[$rel] = $destPath
                [Array]::Clear($rawBytes, 0, $rawBytes.Length)
            }

            # 1. APK ZIP + AndroidManifest.xml + classes.dex
            if (-not $written.ContainsKey("session/it.akai.customremote_backup.apk")) {
                throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: APK backup mancante nel bundle."
            }
            $apkZip = [System.IO.Compression.ZipFile]::OpenRead($written["session/it.akai.customremote_backup.apk"])
            try {
                if ($null -eq $apkZip.GetEntry("AndroidManifest.xml") -or $null -eq $apkZip.GetEntry("classes.dex")) {
                    throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: APK backup corrotto (manifest o classes.dex assenti)."
                }
            } finally {
                $apkZip.Dispose()
            }

            # 2. SQLite PRAGMA integrity_check (con eventuale WAL consolidato in dir effimera)
            if (-not $written.ContainsKey("session/akai_memory.db")) {
                throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: akai_memory.db mancante nel bundle."
            }
            $tableCount = Invoke-SQLiteOfflineIntegrityCheck -DbPath $written["session/akai_memory.db"]

            # 3. TLS PKCS#12 + Root CA + eventuale .p12.bak
            foreach ($reqTls in @("tls/server_keystore.p12", "tls/server_keystore.pass", "tls/ca.pem", "tls/ca.crt", "tls/ca_key.der")) {
                if (-not $written.ContainsKey($reqTls)) {
                    throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: File TLS mancante nel bundle ($reqTls)."
                }
            }
            $ksPass = ([IO.File]::ReadAllText($written["tls/server_keystore.pass"], [Text.Encoding]::UTF8)).TrimEnd("`r", "`n")
            $ksCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($written["tls/server_keystore.p12"], $ksPass)
            try {
                if (-not $ksCert.HasPrivateKey) {
                    throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: PKCS#12 server_keystore.p12 privo di chiave privata."
                }
            } finally {
                $ksCert.Dispose()
            }
            $bakVerified = $false
            if ($written.ContainsKey("tls/server_keystore.p12.bak")) {
                $bakCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($written["tls/server_keystore.p12.bak"], $ksPass)
                try {
                    if (-not $bakCert.HasPrivateKey) {
                        throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: PKCS#12 .p12.bak privo di chiave privata."
                    }
                    $bakVerified = $true
                } finally {
                    $bakCert.Dispose()
                }
            }
            $caCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($written["tls/ca.crt"])
            try {
                $caSha = Get-BytesSha256Hex -Bytes $caCert.RawData
            } finally {
                $caCert.Dispose()
            }

            # 4. XML SharedPreferences validazione sintassi <map> senza esporre valori
            $xmlCount = 0
            $settings = New-Object System.Xml.XmlReaderSettings
            $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
            $settings.XmlResolver = $null
            foreach ($k in ($written.Keys | Where-Object { $_ -like "pairing/*" })) {
                $fsXml = [IO.File]::OpenRead($written[$k])
                try {
                    $xr = [System.Xml.XmlReader]::Create($fsXml, $settings)
                    $doc = New-Object System.Xml.XmlDocument
                    $doc.XmlResolver = $null
                    $doc.Load($xr)
                    if ($null -eq $doc.DocumentElement -or $doc.DocumentElement.Name -ne "map") {
                        throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: XML SharedPreferences non valido ($k)."
                    }
                    $xmlCount++
                } finally {
                    $fsXml.Dispose()
                }
            }
            if ($xmlCount -lt 1) {
                throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Nessun XML pairing/preferenze presente nel bundle."
            }

            $outObj = [ordered]@{
                action = "verify-restore-offline"
                status = "OFFLINE_RESTORE_VERIFIED"
                sqliteIntegrity = "ok"
                sqliteTableCount = $tableCount
                pkcs12HasPrivateKey = $true
                keystoreBakVerified = $bakVerified
                keystoreBakStatus = $(if ($bakVerified) { "VERIFIED_PRESENT" } else { "ABSENT_IN_SOURCE_BACKUP" })
                caSha256 = $caSha
                xmlFilesVerified = $xmlCount
                verifiedEntries = $written.Count
            }
            Write-Output ($outObj | ConvertTo-Json -Depth 4)
        } finally {
            if ($decBytes) { [Array]::Clear($decBytes, 0, $decBytes.Length) }
            Clear-ZeroizedDirectory -TargetDir $ephemeralDir
            if (Test-Path -LiteralPath $ephemeralDir) {
                throw "ERRORE FAIL-CLOSED [RECOVERY BUNDLE]: Directory temporanea non ripulita ($ephemeralDir)."
            }
        }
    }
} finally {
    if ($passBytes) { [Array]::Clear($passBytes, 0, $passBytes.Length) }
}
