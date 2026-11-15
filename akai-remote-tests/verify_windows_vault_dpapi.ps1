# ==============================================================================
# VERIFICA OFFLINE AMBIENTE WINDOWS: LOCALAPPDATA VAULT, ACL, DPAPI FAIL-CLOSED
# Esecuzione esclusiva OFF-TV con mock ADB e asset sintetici dalla directory OneDrive
# ==============================================================================

$ErrorActionPreference = "Stop"

$currentDir = (Get-Location).Path
$isOneDrive = $currentDir -match "OneDrive"
$osVersion = [System.Environment]::OSVersion.VersionString
$psVersion = $PSVersionTable.PSVersion.ToString()

Write-Host "=== VERIFICA OFFLINE WINDOWS LAB: VAULT LOCALAPPDATA & DPAPI ===" -ForegroundColor Cyan
Write-Host "OS Version: $osVersion"
Write-Host "PowerShell Version: $psVersion"
Write-Host "Working Directory: $currentDir (OneDrive Detected: $isOneDrive)"
Write-Host "Target: 100% OFF-TV (Mock ADB su 127.0.0.1:5555, zero socket TV reale)`n"

$results = [ordered]@{}

# 1. Caricamento funzioni da 05_safe_install_and_rollback.ps1
. "$PSScriptRoot/05_safe_install_and_rollback.ps1" -Action plan | Out-Null

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "akai_win_lab_test_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
    # 2. Creazione mock ADB con storage sintetico di test
    $mockDevStorage = Join-Path $tempRoot "mock_device_storage"
    New-Item -ItemType Directory -Force -Path $mockDevStorage | Out-Null

    $synthKsBytes = New-Object byte[] 1024
    (New-Object System.Random).NextBytes($synthKsBytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $synthKsHash = -join ($sha.ComputeHash($synthKsBytes) | ForEach-Object { "{0:x2}" -f $_ })

    $synthPassBytes = [System.Text.Encoding]::UTF8.GetBytes("lab_synth_secret_pass_8844")
    $synthPassHash = -join ($sha.ComputeHash($synthPassBytes) | ForEach-Object { "{0:x2}" -f $_ })

    $synthPemBytes = [System.Text.Encoding]::UTF8.GetBytes("-----BEGIN CERTIFICATE-----`nSYNTH_ROOT_CA_PEM`n-----END CERTIFICATE-----")
    $synthPemHash = -join ($sha.ComputeHash($synthPemBytes) | ForEach-Object { "{0:x2}" -f $_ })

    $synthCrtBytes = [System.Text.Encoding]::UTF8.GetBytes("SYNTH_CRT_DER_PAYLOAD")
    $synthCrtHash = -join ($sha.ComputeHash($synthCrtBytes) | ForEach-Object { "{0:x2}" -f $_ })

    $synthKeyBytes = [System.Text.Encoding]::UTF8.GetBytes("SYNTH_RSA_PRIVATE_KEY_DER")
    $synthKeyHash = -join ($sha.ComputeHash($synthKeyBytes) | ForEach-Object { "{0:x2}" -f $_ })

    [System.IO.File]::WriteAllBytes((Join-Path $mockDevStorage "server_keystore.p12"), $synthKsBytes)
    [System.IO.File]::WriteAllBytes((Join-Path $mockDevStorage "server_keystore.pass"), $synthPassBytes)
    [System.IO.File]::WriteAllBytes((Join-Path $mockDevStorage "ca.pem"), $synthPemBytes)
    [System.IO.File]::WriteAllBytes((Join-Path $mockDevStorage "ca.crt"), $synthCrtBytes)
    [System.IO.File]::WriteAllBytes((Join-Path $mockDevStorage "ca_key.der"), $synthKeyBytes)

    # Mock ADB script JS
    $mockAdbJs = Join-Path $tempRoot "mock_adb.js"
    $devStorageEsc = $mockDevStorage.Replace('\', '/')
    @"
const fs = require('fs');
const path = require('path');
const argv = process.argv.slice(2);
const argStr = argv.join(' ');

if (argStr.includes('test -f') || argStr.includes('FILE_PROBE_RESULT')) {
    if (argStr.includes('it.akai.customremote') && argStr.includes('server_keystore.p12')) {
        console.log('FILE_PROBE_RESULT:EXISTS');
        process.exit(0);
    }
    console.log('FILE_PROBE_RESULT:NOT_FOUND');
    process.exit(0);
}

if (argv.includes('exec-out')) {
    const devDir = '$devStorageEsc';
    const files = ['server_keystore.p12', 'server_keystore.pass', 'ca.pem', 'ca.crt', 'ca_key.der'];
    for (const f of files) {
        if (argStr.includes(f)) {
            const fp = path.join(devDir, f);
            if (fs.existsSync(fp)) {
                const buf = fs.readFileSync(fp);
                process.stdout.write(buf, () => process.exit(0));
                return;
            }
        }
    }
    process.exit(1);
}

if (argv.includes('exec-in')) {
    const devDir = '$devStorageEsc';
    const match = argStr.match(/files\/([a-zA-Z0-9_\.]+)/);
    if (match) {
        const dest = path.join(devDir, match[1]);
        const chunks = [];
        process.stdin.on('data', chunk => chunks.push(chunk));
        process.stdin.on('end', () => {
            const buf = Buffer.concat(chunks);
            fs.writeFileSync(dest, buf);
            process.exit(0);
        });
        return;
    }
    process.exit(0);
}

process.exit(0);
"@ | Set-Content -Path $mockAdbJs -Encoding ascii

    $nodeExe = (Get-Command node -ErrorAction Stop).Source
    $mockAdbCmd = Join-Path $tempRoot "adb.cmd"
    "@echo off`n`"$nodeExe`" `"$mockAdbJs`" %*" | Set-Content -Path $mockAdbCmd -Encoding ascii

    # 3. Test di Resolve-TlsVaultDir con percorso relativo -BackupDir .\backup_tv da OneDrive
    $relativeBackupDir = ".\backup_tv"
    $sessionName = "backup_winlab_$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
    $sessionRelDir = Join-Path $relativeBackupDir $sessionName
    New-Item -ItemType Directory -Force -Path $sessionRelDir | Out-Null

    $vaultInfo = Resolve-TlsVaultDir -SessionDir $sessionRelDir -PackageName "it.akai.customremote"
    $vaultPath = $vaultInfo.VaultDir

    $isUnderLocalAppData = $vaultPath.StartsWith($env:LOCALAPPDATA, [System.StringComparison]::OrdinalIgnoreCase)
    $results["Vault_Under_LocalAppData"] = $isUnderLocalAppData

    # 4. Verifica ACL effettiva
    $dirInfo = New-Object System.IO.DirectoryInfo($vaultPath)
    $dirSec = $dirInfo.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
    $isAclProtected = $dirSec.AreAccessRulesProtected
    $results["ACL_Inheritance_Disabled"] = $isAclProtected

    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $userAccess = $dirSec.Access | Where-Object { $_.IdentityReference.Value -eq $currentUser }
    $results["ACL_CurrentUser_FullControl"] = ($userAccess.FileSystemRights -match "FullControl")

    # 5. Esecuzione Backup-DeviceTlsIdentity (5 asset)
    $backupRes = Backup-DeviceTlsIdentity -AdbExe $mockAdbCmd -TargetAdb "127.0.0.1:5555" -PackageName "it.akai.customremote" -SessionDir $sessionRelDir

    $files5Present = ($backupRes.HasTls -eq $true) -and
                     (Test-Path (Join-Path $vaultPath "server_keystore.p12.enc")) -and
                     (Test-Path (Join-Path $vaultPath "server_keystore.pass.enc")) -and
                     (Test-Path (Join-Path $vaultPath "ca.pem.enc")) -and
                     (Test-Path (Join-Path $vaultPath "ca.crt.enc")) -and
                     (Test-Path (Join-Path $vaultPath "ca_key.der.enc"))
    $results["All_5_Assets_Encrypted_Present"] = $files5Present

    # 6. Verifica ASSENZA di .vault_master.key
    $noMasterKeyInVault = -not (Test-Path (Join-Path $vaultPath ".vault_master.key"))
    $noMasterKeyInSession = -not (Test-Path (Join-Path $sessionRelDir "tls_identity\.vault_master.key"))
    $results["No_MasterKey_On_Disk"] = ($noMasterKeyInVault -and $noMasterKeyInSession)

    # 7. Verifica ASSENZA di plaintext keys in sessione o vault
    $noPlainPass = (-not (Test-Path (Join-Path $sessionRelDir "tls_identity\server_keystore.pass"))) -and
                   (-not (Test-Path (Join-Path $vaultPath "server_keystore.pass")))
    $noPlainKey = (-not (Test-Path (Join-Path $sessionRelDir "tls_identity\ca_key.der"))) -and
                  (-not (Test-Path (Join-Path $vaultPath "ca_key.der")))
    $results["Zero_Plaintext_Keys_On_Disk"] = ($noPlainPass -and $noPlainKey)

    # 8. Decifratura DPAPI roundtrip di tutti e 5 gli asset e confronto hash
    $ksDec = Unprotect-TlsData -CipherBytes ([System.IO.File]::ReadAllBytes((Join-Path $vaultPath "server_keystore.p12.enc"))) -Mechanism "DPAPI_CURRENT_USER" -VaultDir $vaultPath
    $ksDecHash = -join ($sha.ComputeHash($ksDec) | ForEach-Object { "{0:x2}" -f $_ })

    $passDec = Unprotect-TlsData -CipherBytes ([System.IO.File]::ReadAllBytes((Join-Path $vaultPath "server_keystore.pass.enc"))) -Mechanism "DPAPI_CURRENT_USER" -VaultDir $vaultPath
    $passDecHash = -join ($sha.ComputeHash($passDec) | ForEach-Object { "{0:x2}" -f $_ })

    $pemDec = Unprotect-TlsData -CipherBytes ([System.IO.File]::ReadAllBytes((Join-Path $vaultPath "ca.pem.enc"))) -Mechanism "DPAPI_CURRENT_USER" -VaultDir $vaultPath
    $pemDecHash = -join ($sha.ComputeHash($pemDec) | ForEach-Object { "{0:x2}" -f $_ })

    $crtDec = Unprotect-TlsData -CipherBytes ([System.IO.File]::ReadAllBytes((Join-Path $vaultPath "ca.crt.enc"))) -Mechanism "DPAPI_CURRENT_USER" -VaultDir $vaultPath
    $crtDecHash = -join ($sha.ComputeHash($crtDec) | ForEach-Object { "{0:x2}" -f $_ })

    $keyDec = Unprotect-TlsData -CipherBytes ([System.IO.File]::ReadAllBytes((Join-Path $vaultPath "ca_key.der.enc"))) -Mechanism "DPAPI_CURRENT_USER" -VaultDir $vaultPath
    $keyDecHash = -join ($sha.ComputeHash($keyDec) | ForEach-Object { "{0:x2}" -f $_ })

    $roundtripOk = ($ksDecHash -eq $synthKsHash) -and
                   ($passDecHash -eq $synthPassHash) -and
                   ($pemDecHash -eq $synthPemHash) -and
                   ($crtDecHash -eq $synthCrtHash) -and
                   ($keyDecHash -eq $synthKeyHash)
    $results["DPAPI_Roundtrip_5_of_5_Parity"] = $roundtripOk

    # 9. Test negativo: DPAPI non disponibile -> STOP fail-closed senza fallback AES
    $dpapiFailClosed = $false
    $env:MOCK_FAIL_DPAPI = 'true'
    try {
        Protect-TlsData -PlainBytes $synthKsBytes -VaultDir $vaultPath | Out-Null
    } catch {
        if ($_.Exception.Message -match "ERRORE FAIL-CLOSED" -and $_.Exception.Message -match "DPAPI") {
            $dpapiFailClosed = $true
        }
    } finally {
        $env:MOCK_FAIL_DPAPI = 'false'
    }
    $results["DPAPI_Unavailable_FailClosed"] = $dpapiFailClosed

    # 10. Verifica pointer e manifest in sessione OneDrive
    $pointerExists = Test-Path (Join-Path $sessionRelDir "tls_identity\vault_pointer.json")
    $manifestExists = Test-Path (Join-Path $sessionRelDir "tls_identity\tls_manifest.json")
    $manifestContent = Get-Content (Join-Path $sessionRelDir "tls_identity\tls_manifest.json") -Raw
    $noSecretsInManifest = ($manifestContent -notmatch "lab_synth_secret_pass_8844") -and
                           ($manifestContent -notmatch "SYNTH_RSA_PRIVATE_KEY_DER")
    $results["Manifest_And_Pointer_Safe"] = ($pointerExists -and $manifestExists -and $noSecretsInManifest)

    # 11. Rollback Restore bit-for-bit di tutti i 5 file
    # Svuotiamo lo storage device mock per simulare ripristino da zero
    Remove-Item (Join-Path $mockDevStorage "*") -Force
    $restoreRes = Restore-DeviceTlsIdentity -AdbExe $mockAdbCmd -TargetAdb "127.0.0.1:5555" -PackageName "it.akai.customremote" -SessionDir $sessionRelDir -ChownTarget "10045:10045"
    
    $restoredKsHash = (Get-FileHash (Join-Path $mockDevStorage "server_keystore.p12") -Algorithm SHA256).Hash.ToLower()
    $restoredPassHash = (Get-FileHash (Join-Path $mockDevStorage "server_keystore.pass") -Algorithm SHA256).Hash.ToLower()
    $restoredPemHash = (Get-FileHash (Join-Path $mockDevStorage "ca.pem") -Algorithm SHA256).Hash.ToLower()
    $restoredCrtHash = (Get-FileHash (Join-Path $mockDevStorage "ca.crt") -Algorithm SHA256).Hash.ToLower()
    $restoredKeyHash = (Get-FileHash (Join-Path $mockDevStorage "ca_key.der") -Algorithm SHA256).Hash.ToLower()

    $restoreAll5Ok = ($restoreRes.Restored -eq $true) -and
                     ($restoreRes.All5FilesVerified -eq $true) -and
                     ($restoredKsHash -eq $synthKsHash) -and
                     ($restoredPassHash -eq $synthPassHash) -and
                     ($restoredPemHash -eq $synthPemHash) -and
                     ($restoredCrtHash -eq $synthCrtHash) -and
                     ($restoredKeyHash -eq $synthKeyHash)
    $results["Rollback_Restore_All_5_BitForBit"] = $restoreAll5Ok

} finally {
    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $sessionRelDir) {
        Remove-Item $sessionRelDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "=== RISULTATI VERIFICHE OFFLINE WINDOWS LAB ===" -ForegroundColor Yellow
$allPassed = $true
foreach ($k in $results.Keys) {
    $v = $results[$k]
    $color = if ($v -eq $true) { "Green" } else { "Red"; $allPassed = $false }
    Write-Host "  $k : $v" -ForegroundColor $color
}

Write-Host "`nESITO COMPLESSIVO GATE WINDOWS LAB: $(if ($allPassed) { '100% PASS' } else { 'FAIL' })" -ForegroundColor $(if ($allPassed) { 'Green' } else { 'Red' })
if (-not $allPassed) { exit 1 }
