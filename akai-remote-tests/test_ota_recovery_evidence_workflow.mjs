#!/usr/bin/env node
/**
 * Host-only E2E workflow tests for P1-A (physical encrypted archive + rescue APK
 * digest/restore verification before receipt issuance & on verification) and
 * P1-B (coherent Staging vs Release Rescue version ordering across scripts/17,
 * scripts/lib/ota_recovery_evidence.mjs, and Java OtaRecoveryEvidenceGate).
 *
 * Uses ONLY ephemeral host keys and synthetic dummy sessions. NEVER implies
 * OTA_PROVISIONED_READY, real owner signing keys, or AKAI TV hardware PASS.
 */
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { generateKeyPairSync } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  issueArchiveVerifiedReceipt,
  verifyReceiptWithRealArchives,
} from '../scripts/lib/ota_recovery_evidence.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '..');

function resolveJdkTool(toolBase) {
  const isWin = process.platform === 'win32';
  const ext = isWin ? '.exe' : '';
  const localTool = path.join(repoRoot, 'tools', 'jdk-17', 'bin', toolBase + ext);
  if (fs.existsSync(localTool)) return localTool;
  if (process.env.JAVA_HOME) {
    const jhTool = path.join(process.env.JAVA_HOME, 'bin', toolBase + ext);
    if (fs.existsSync(jhTool)) return jhTool;
  }
  return toolBase;
}

function resolvePowerShell() {
  return process.platform === 'win32' ? 'powershell.exe' : 'pwsh';
}

function crc32(buf) {
  let crc = 0xffffffff;
  for (let i = 0; i < buf.length; i++) {
    crc ^= buf[i];
    for (let j = 0; j < 8; j++) {
      crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function writeStoredZip(outPath, entries) {
  const localParts = [];
  const centralParts = [];
  let offset = 0;
  for (const [name, content] of entries) {
    const nameBuf = Buffer.from(name, 'utf8');
    const dataBuf = Buffer.isBuffer(content) ? content : Buffer.from(content, 'utf8');
    const sum = crc32(dataBuf);

    const lfh = Buffer.alloc(30);
    lfh.writeUInt32LE(0x04034b50, 0);
    lfh.writeUInt16LE(20, 4);
    lfh.writeUInt16LE(0, 6);
    lfh.writeUInt16LE(0, 8);
    lfh.writeUInt16LE(0, 10);
    lfh.writeUInt16LE(0, 12);
    lfh.writeUInt32LE(sum, 14);
    lfh.writeUInt32LE(dataBuf.length, 18);
    lfh.writeUInt32LE(dataBuf.length, 22);
    lfh.writeUInt16LE(nameBuf.length, 26);
    lfh.writeUInt16LE(0, 28);
    localParts.push(lfh, nameBuf, dataBuf);

    const cdh = Buffer.alloc(46);
    cdh.writeUInt32LE(0x02014b50, 0);
    cdh.writeUInt16LE(20, 4);
    cdh.writeUInt16LE(20, 6);
    cdh.writeUInt16LE(0, 8);
    cdh.writeUInt16LE(0, 10);
    cdh.writeUInt16LE(0, 12);
    cdh.writeUInt16LE(0, 14);
    cdh.writeUInt32LE(sum, 16);
    cdh.writeUInt32LE(dataBuf.length, 20);
    cdh.writeUInt32LE(dataBuf.length, 24);
    cdh.writeUInt16LE(nameBuf.length, 28);
    cdh.writeUInt16LE(0, 30);
    cdh.writeUInt16LE(0, 32);
    cdh.writeUInt16LE(0, 34);
    cdh.writeUInt16LE(0, 36);
    cdh.writeUInt32LE(0, 38);
    cdh.writeUInt32LE(offset, 42);
    centralParts.push(cdh, nameBuf);

    offset += lfh.length + nameBuf.length + dataBuf.length;
  }
  const centralBuf = Buffer.concat(centralParts);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(0, 4);
  eocd.writeUInt16LE(0, 6);
  eocd.writeUInt16LE(entries.length, 8);
  eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(centralBuf.length, 12);
  eocd.writeUInt32LE(offset, 16);
  eocd.writeUInt16LE(0, 20);
  fs.writeFileSync(outPath, Buffer.concat([...localParts, centralBuf, eocd]));
}

function buildEncryptedBundleViaScript16(workDir, bundleOutPath, passphrase) {
  const script16 = path.join(repoRoot, 'scripts', '16_export_portable_recovery_bundle.ps1');
  const helperPs1 = path.join(workDir, 'build_test_bundle.ps1');
  const sessionDir = path.join(workDir, 'session_01');
  const tlsVault = path.join(workDir, 'vault', 'tls');
  const pairVault = path.join(workDir, 'vault', 'pairing');

  // Create valid SQLite DB cross-platform via python/node before PS16 export
  fs.mkdirSync(path.join(sessionDir, 'tls_identity'), { recursive: true });
  fs.mkdirSync(path.join(sessionDir, 'pairing_sessions'), { recursive: true });
  fs.mkdirSync(tlsVault, { recursive: true });
  fs.mkdirSync(pairVault, { recursive: true });

  const dbPath = path.join(sessionDir, 'akai_memory.db');
  execFileSync(
    process.execPath,
    [
      '-e',
      `const {DatabaseSync}=require('node:sqlite');const db=new DatabaseSync(process.argv[1]);db.exec("CREATE TABLE facts(id INTEGER PRIMARY KEY,k TEXT,v TEXT);INSERT INTO facts(k,v) VALUES('k1','v1');");db.close();`,
      dbPath,
    ],
    { stdio: 'inherit' }
  );

  // Create valid dummy backup APK zip
  writeStoredZip(path.join(sessionDir, 'it.akai.customremote_backup.apk'), [
    ['AndroidManifest.xml', Buffer.alloc(600, 0x41)],
    ['classes.dex', Buffer.alloc(600, 0x42)],
  ]);

  const psScript = `
param([string]$SessionDir, [string]$TlsVault, [string]$PairVault, [string]$BundleOut, [string]$Script16)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
}
$isWin = [Environment]::OSVersion.Platform -match 'Win'
function Get-HexSha256([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (-join ($sha.ComputeHash($Bytes) | ForEach-Object { '{0:x2}' -f $_ })).ToLowerInvariant() } finally { $sha.Dispose() }
}
function Protect-Vault([byte[]]$Plain, [string]$Vault) {
    if ($isWin) {
        $ent = [Text.Encoding]::UTF8.GetBytes('AkaiTv_TLS_Identity_2026_DPAPI_Entropy')
        return @{ Mechanism='DPAPI_CURRENT_USER'; Cipher=[System.Security.Cryptography.ProtectedData]::Protect($Plain, $ent, [System.Security.Cryptography.DataProtectionScope]::CurrentUser) }
    }
    $mk = Join-Path $Vault '.vault_master.key'
    if (-not (Test-Path -LiteralPath $mk)) {
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $k = New-Object byte[] 32; $rng.GetBytes($k); $rng.Dispose()
        [IO.File]::WriteAllBytes($mk, $k)
    } else { $k = [IO.File]::ReadAllBytes($mk) }
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = $k; $aes.GenerateIV()
        $enc = $aes.CreateEncryptor()
        try { $cd = $enc.TransformFinalBlock($Plain, 0, $Plain.Length) } finally { $enc.Dispose() }
        $out = New-Object byte[] ($aes.IV.Length + $cd.Length)
        [Buffer]::BlockCopy($aes.IV, 0, $out, 0, $aes.IV.Length)
        [Buffer]::BlockCopy($cd, 0, $out, $aes.IV.Length, $cd.Length)
        return @{ Mechanism='AES_256_CBC'; Cipher=$out }
    } finally { $aes.Dispose() }
}
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
try {
    $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=AkaiSandboxTestCA', $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $cert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(30))
    $ksPass = 'dummy_test_pfx_pass_999'
    $pfx = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $ksPass)
    $crt = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $pem = [Text.Encoding]::ASCII.GetBytes("-----BEGIN CERTIFICATE-----\`n" + [Convert]::ToBase64String($crt) + "\`n-----END CERTIFICATE-----\`n")
    $cert.Dispose()
} finally { $rsa.Dispose() }
$tlsPlain = [ordered]@{ 'server_keystore.p12'=$pfx; 'server_keystore.pass'=[Text.Encoding]::UTF8.GetBytes($ksPass); 'ca.pem'=$pem; 'ca.crt'=$crt; 'ca_key.der'=[byte[]](1..64); 'server_keystore.p12.bak'=$pfx }
$tlsMeta = [ordered]@{}; $bakMeta = $null
foreach ($fn in $tlsPlain.Keys) {
    $pb = $tlsPlain[$fn]; $p = Protect-Vault $pb $TlsVault
    [IO.File]::WriteAllBytes((Join-Path $TlsVault "$fn.enc"), $p.Cipher)
    $m = [ordered]@{ Sha256=(Get-HexSha256 $pb); SizeBytes=$pb.Length; Encrypted=$true; CipherSha256=(Get-HexSha256 $p.Cipher); Mechanism=$p.Mechanism }
    if ($fn -eq 'server_keystore.p12.bak') { $bakMeta = $m } else { $tlsMeta[$fn] = $m }
}
[IO.File]::WriteAllText((Join-Path $SessionDir 'tls_identity\\tls_manifest.json'), (@{ Version=1; Files=$tlsMeta; KeystoreSha256=$tlsMeta.'server_keystore.p12'.Sha256; HasKeystoreBak=$true; KeystoreBak=$bakMeta } | ConvertTo-Json -Depth 5))
[IO.File]::WriteAllText((Join-Path $SessionDir 'tls_identity\\vault_pointer.json'), (@{ VaultDir=$TlsVault } | ConvertTo-Json))
$pairPlain = [ordered]@{ 'akai_remote_sessions.xml'=[Text.Encoding]::UTF8.GetBytes("<?xml version='1.0' encoding='utf-8'?><map><string name=\`"k\`">v</string></map>"); 'akai_ai_security_prefs.xml'=[Text.Encoding]::UTF8.GetBytes("<?xml version='1.0' encoding='utf-8'?><map><string name=\`"s\`">ks:v</string></map>") }
$pairMeta = [ordered]@{}
foreach ($pn in $pairPlain.Keys) {
    $pb = $pairPlain[$pn]; $p = Protect-Vault $pb $PairVault
    [IO.File]::WriteAllBytes((Join-Path $PairVault "$pn.enc"), $p.Cipher)
    $pairMeta[$pn] = [ordered]@{ Sha256=(Get-HexSha256 $pb); SizeBytes=$pb.Length; Encrypted=$true; CipherSha256=(Get-HexSha256 $p.Cipher); Mechanism=$p.Mechanism }
}
[IO.File]::WriteAllText((Join-Path $SessionDir 'pairing_sessions\\pairing_manifest.json'), (@{ Version=1; Files=$pairMeta } | ConvertTo-Json -Depth 5))
[IO.File]::WriteAllText((Join-Path $SessionDir 'pairing_sessions\\vault_pointer.json'), (@{ VaultDir=$PairVault } | ConvertTo-Json))
& $Script16 -Action export -BackupSessionDir $SessionDir -OutputBundlePath $BundleOut | Out-Null
`;
  fs.writeFileSync(helperPs1, psScript, 'utf8');
  const psExe = resolvePowerShell();
  const baseArgs = process.platform === 'win32'
    ? ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', helperPs1]
    : ['-NoProfile', '-File', helperPs1];
  execFileSync(
    psExe,
    [...baseArgs, '-SessionDir', sessionDir, '-TlsVault', tlsVault, '-PairVault', pairVault, '-BundleOut', bundleOutPath, '-Script16', script16],
    {
      stdio: 'inherit',
      env: { ...process.env, JARVIS_RECOVERY_PASSPHRASE: passphrase },
    }
  );
}

function invokeScript17(args) {
  const script17 = path.join(repoRoot, 'scripts', '17_check_ota_provisioning_readiness.ps1');
  const psExe = resolvePowerShell();
  const baseArgs = process.platform === 'win32'
    ? ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script17]
    : ['-NoProfile', '-File', script17];
  const res = spawnSync(psExe, [...baseArgs, ...args], { encoding: 'utf8' });
  const text = (res.stdout || '').trim();
  return { exitCode: res.status, json: JSON.parse(text) };
}

/**
 * SYNTHETIC_HOST_FIXTURE_NON_AUTHORITATIVE:
 * Simulates stdout of apksigner.jar + aapt for host workflow tests without
 * shipping any real owner signing key or owner-signed Rescue APK.
 */
function makeSyntheticRescueApkRunner({
  versionCode,
  signerSha256 = '21c2c41dc4c34576cca14ad5404e87d1c5a07ace961c0fab96d128c2164a51ed',
  packageName = 'it.akai.customremote',
  debuggable = false,
}) {
  return (cmd, args) => {
    const joined = args.join(' ');
    if (joined.includes('verify --verbose --print-certs')) {
      return `Verifies\nVerified using v2 scheme (APK Signature Scheme v2): true\nNumber of signers: 1\nSigner #1 certificate SHA-256 digest: ${signerSha256}\n`;
    }
    if (joined.includes('dump badging')) {
      return `package: name='${packageName}' versionCode='${versionCode}' versionName='1.3.0-rescue-v${versionCode}'\nsdkVersion:'21'\ntargetSdkVersion:'28'\nnative-code: 'armeabi-v7a'\n`;
    }
    if (joined.includes('dump xmltree')) {
      const dbg = debuggable ? '0xffffffff' : '0x0';
      return `E: manifest\n  E: application\n    A: android:debuggable(0x0101000f)=(type 0x12)${dbg}\n`;
    }
    throw new Error('UNEXPECTED_APK_TOOL_INVOCATION: ' + cmd + ' ' + joined);
  };
}

const workDir = fs.mkdtempSync(path.join(os.tmpdir(), 'jarvis_ota_ev_wf_'));
let count = 0;

try {
  const passphrase = 'Workflow_Ephemeral_Test_Passphrase_2026!';
  const bundlePath = path.join(workDir, 'recovery_bundle.akv.json');
  buildEncryptedBundleViaScript16(workDir, bundlePath, passphrase);
  assert.ok(fs.existsSync(bundlePath), 'Encrypted backup bundle created');
  count++;

  // Synthetic stored-ZIP Rescue APKs
  const rescueV8Apk = path.join(workDir, 'a2_rescue_v8.apk');
  const rescueV9Apk = path.join(workDir, 'a2_rescue_v9.apk');
  writeStoredZip(rescueV8Apk, [
    ['AndroidManifest.xml', Buffer.alloc(700, 0x51)],
    ['classes.dex', Buffer.alloc(700, 0x52)],
  ]);
  writeStoredZip(rescueV9Apk, [
    ['AndroidManifest.xml', Buffer.alloc(800, 0x61)],
    ['classes.dex', Buffer.alloc(800, 0x62)],
  ]);

  // Ephemeral RSA-3072 keys (NEVER production keys)
  const { publicKey: stagingPubDer, privateKey: stagingPriv } = generateKeyPairSync('rsa', {
    modulusLength: 3072,
    publicKeyEncoding: { type: 'spki', format: 'der' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  });
  const { publicKey: releasePubDer, privateKey: releasePriv } = generateKeyPairSync('rsa', {
    modulusLength: 3072,
    publicKeyEncoding: { type: 'spki', format: 'der' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  });
  const stagingPubPath = path.join(workDir, 'staging-pub.der');
  const releasePubPath = path.join(workDir, 'release-pub.der');
  fs.writeFileSync(stagingPubPath, stagingPubDer);
  fs.writeFileSync(releasePubPath, releasePubDer);

  const nowSec = 1_795_000_000;
  const deviceUid = 'akai-tv-workflow-uid-001';

  const runnerV8 = makeSyntheticRescueApkRunner({ versionCode: 8 });
  const runnerV9 = makeSyntheticRescueApkRunner({ versionCode: 9 });

  // 1. Issue archive-verified STAGING receipt (installed=6, candidate=7, recoveryRescue=8)
  const stagingDir = path.join(workDir, 'out_staging');
  const issuedStaging = issueArchiveVerifiedReceipt({
    repoRoot,
    channelProfile: 'staging',
    deviceUid,
    installedVersionCode: 6,
    candidateVersionCode: 7,
    priorRescueFloorVersionCode: 0,
    recoveryRescueVersionCode: 8,
    backupId: 'bkp-wf-stg-01',
    bundlePath,
    rescueApkPath: rescueV8Apk,
    bundlePassphrase: passphrase,
    privateKeyPemOrKeyObject: stagingPriv,
    publicKeyDerBuf: stagingPubDer,
    outReceiptPath: path.join(stagingDir, 'ota-recovery-evidence.receipt'),
    outSigPath: path.join(stagingDir, 'ota-recovery-evidence.receipt.sig'),
    nowEpochSec: nowSec,
    rescueApkProofRunner: runnerV8,
  });
  const verStaging = verifyReceiptWithRealArchives({
    repoRoot,
    receiptPath: issuedStaging.receiptPath,
    sigPath: issuedStaging.sigPath,
    publicKeyDerPath: stagingPubPath,
    bundlePath,
    rescueApkPath: rescueV8Apk,
    deviceUid,
    installedVersionCode: 6,
    candidateVersionCode: 7,
    nowEpochSec: nowSec,
    rescueApkProofRunner: runnerV8,
  });
  assert.equal(verStaging.archivePhysicallyVerified, true);
  assert.equal(verStaging.rescueApkCertVerified, true);
  assert.equal(verStaging.rescueApkVersionCode, 8);
  assert.equal(verStaging.recoveryRescueVersionCode, 8);
  count++;

  // 2. Issue archive-verified RELEASE receipt (installed=6 <= priorRescue=7 < candidate=8 < postReleaseRescue=9)
  const releaseDir = path.join(workDir, 'out_release');
  const issuedRelease = issueArchiveVerifiedReceipt({
    repoRoot,
    channelProfile: 'release',
    deviceUid,
    installedVersionCode: 6,
    candidateVersionCode: 8,
    priorRescueFloorVersionCode: 7,
    recoveryRescueVersionCode: 9,
    backupId: 'bkp-wf-rel-01',
    bundlePath,
    rescueApkPath: rescueV9Apk,
    bundlePassphrase: passphrase,
    privateKeyPemOrKeyObject: releasePriv,
    publicKeyDerBuf: releasePubDer,
    outReceiptPath: path.join(releaseDir, 'ota-recovery-evidence.receipt'),
    outSigPath: path.join(releaseDir, 'ota-recovery-evidence.receipt.sig'),
    nowEpochSec: nowSec,
    rescueApkProofRunner: runnerV9,
  });
  const verRelease = verifyReceiptWithRealArchives({
    repoRoot,
    receiptPath: issuedRelease.receiptPath,
    sigPath: issuedRelease.sigPath,
    publicKeyDerPath: releasePubPath,
    bundlePath,
    rescueApkPath: rescueV9Apk,
    deviceUid,
    installedVersionCode: 6,
    candidateVersionCode: 8,
    nowEpochSec: nowSec,
    rescueApkProofRunner: runnerV9,
  });
  assert.equal(verRelease.archivePhysicallyVerified, true);
  assert.equal(verRelease.rescueApkCertVerified, true);
  assert.equal(verRelease.rescueApkVersionCode, 9);
  assert.equal(verRelease.priorRescueFloorVersionCode, 7);
  assert.equal(verRelease.recoveryRescueVersionCode, 9);
  assert.ok(fs.existsSync(issuedRelease.bundlePkgPath), 'Portable .pkg bundle must be emitted');
  count++;

  // 3. Cross-check Java OtaRecoveryEvidenceGate & OtaRecoveryEvidenceStore.parsePortableBundle directly on Node-issued artifacts
  const javaDir = path.join(workDir, 'java_cross');
  const javaBin = path.join(javaDir, 'bin');
  fs.mkdirSync(javaBin, { recursive: true });
  const crossRunner = path.join(javaDir, 'WorkflowJavaCrossCheck.java');
  fs.writeFileSync(
    crossRunner,
    `
import it.akai.customremote.ai.*;
import java.nio.file.*;
import java.security.PublicKey;

public final class WorkflowJavaCrossCheck {
    public static void main(String[] args) throws Exception {
        PublicKey stgPub = OtaPinnedReleaseKey.decodeBundledSpki(Files.readAllBytes(Paths.get(args[0])));
        byte[] stgRec = Files.readAllBytes(Paths.get(args[1]));
        byte[] stgSig = Files.readAllBytes(Paths.get(args[2]));
        PublicKey relPub = OtaPinnedReleaseKey.decodeBundledSpki(Files.readAllBytes(Paths.get(args[3])));
        byte[] relRec = Files.readAllBytes(Paths.get(args[4]));
        byte[] relSig = Files.readAllBytes(Paths.get(args[5]));
        long now = Long.parseLong(args[6]);
        String uid = args[7];
        byte[] relPkgBytes = Files.readAllBytes(Paths.get(args[8]));

        OtaRecoveryEvidenceGate.Verdict vStg = OtaRecoveryEvidenceGate.verify(stgRec, stgSig, stgPub, uid, 6, 7, now);
        if (!vStg.accepted) throw new AssertionError("Java rejected staging receipt: " + vStg.code);

        OtaRecoveryEvidenceGate.Verdict vRel = OtaRecoveryEvidenceGate.verify(relRec, relSig, relPub, uid, 6, 8, now);
        if (!vRel.accepted) throw new AssertionError("Java rejected release receipt: " + vRel.code);

        OtaRecoveryEvidenceStore.PortableBundle parsedPkg = OtaRecoveryEvidenceStore.parsePortableBundle(relPkgBytes);
        if (parsedPkg == null) throw new AssertionError("Java failed to parse Node-issued .pkg bundle");
        OtaRecoveryEvidenceGate.Verdict vPkg = OtaRecoveryEvidenceGate.verify(
                parsedPkg.receiptBytes, parsedPkg.signatureBytes, relPub, uid, 6, 8, now);
        if (!vPkg.accepted) throw new AssertionError("Java rejected decoded .pkg receipt: " + vPkg.code);
        OtaRecoveryEvidenceGate.Verdict vPkgInstalled = OtaRecoveryEvidenceGate.verifyForInstalled(
                parsedPkg.receiptBytes, parsedPkg.signatureBytes, relPub, uid, 6, now);
        if (!vPkgInstalled.accepted) throw new AssertionError("verifyForInstalled rejected .pkg receipt: " + vPkgInstalled.code);

        // Negative cross-policy check inside Java gate
        OtaRecoveryEvidenceGate.Verdict vRelLowCand = OtaRecoveryEvidenceGate.verify(relRec, relSig, relPub, uid, 6, 7, now);
        if (vRelLowCand.accepted || !"EVIDENCE_RELEASE_NOT_ABOVE_PRIOR_RESCUE".equals(vRelLowCand.code)) {
            throw new AssertionError("Expected EVIDENCE_RELEASE_NOT_ABOVE_PRIOR_RESCUE, got " + vRelLowCand.code);
        }
        OtaRecoveryEvidenceGate.Verdict vRelHighCand = OtaRecoveryEvidenceGate.verify(relRec, relSig, relPub, uid, 6, 9, now);
        if (vRelHighCand.accepted || !"EVIDENCE_RECOVERY_RESCUE_NOT_ABOVE_CANDIDATE".equals(vRelHighCand.code)) {
            throw new AssertionError("Expected EVIDENCE_RECOVERY_RESCUE_NOT_ABOVE_CANDIDATE, got " + vRelHighCand.code);
        }
        System.out.println("JAVA_CROSS_POLICY_PASS");
    }
}
`,
    'utf8'
  );
  const hostMockDirs = [
    ['android', 'content'],
    ['android', 'content', 'res'],
    ['android', 'content', 'pm'],
    ['android', 'os'],
    ['android', 'provider'],
  ];
  const hostMockSources = [];
  for (const segs of hostMockDirs) {
    const dir = path.join(repoRoot, 'akai-remote-tests', 'host_mock', ...segs);
    for (const entry of fs.readdirSync(dir)) {
      if (entry.endsWith('.java')) hostMockSources.push(path.join(dir, entry));
    }
  }
  execFileSync(
    resolveJdkTool('javac'),
    [
      '-encoding', 'UTF-8', '-source', '8', '-target', '8', '-d', javaBin,
      ...hostMockSources,
      path.join(repoRoot, 'akai-remote-tv', 'app', 'src', 'main', 'java', 'it', 'akai', 'customremote', 'ai', 'OtaPinnedReleaseKey.java'),
      path.join(repoRoot, 'akai-remote-tv', 'app', 'src', 'main', 'java', 'it', 'akai', 'customremote', 'ai', 'OtaCandidateGate.java'),
      path.join(repoRoot, 'akai-remote-tv', 'app', 'src', 'main', 'java', 'it', 'akai', 'customremote', 'ai', 'OtaReleaseTrust.java'),
      path.join(repoRoot, 'akai-remote-tv', 'app', 'src', 'main', 'java', 'it', 'akai', 'customremote', 'ai', 'OtaRecoveryEvidenceGate.java'),
      path.join(repoRoot, 'akai-remote-tv', 'app', 'src', 'main', 'java', 'it', 'akai', 'customremote', 'ai', 'OtaRecoveryEvidenceStore.java'),
      crossRunner,
    ],
    { stdio: 'inherit' }
  );
  const javaOut = execFileSync(
    resolveJdkTool('java'),
    [
      '-cp', javaBin, 'WorkflowJavaCrossCheck',
      stagingPubPath, issuedStaging.receiptPath, issuedStaging.sigPath,
      releasePubPath, issuedRelease.receiptPath, issuedRelease.sigPath,
      String(nowSec), deviceUid, issuedRelease.bundlePkgPath,
    ],
    { encoding: 'utf8' }
  );
  assert.ok(javaOut.includes('JAVA_CROSS_POLICY_PASS'));
  count++;

  // 4. Cross-policy check on Script 17 (P1-B): consistent Release & Staging floors match Java gate!
  const mockSig = path.join(workDir, 'mock_apksigner.txt');
  const mockBadg = path.join(workDir, 'mock_badging.txt');
  const mockXml = path.join(workDir, 'mock_xml.txt');
  const mockRelApk = path.join(workDir, 'rel_v8.apk');
  const relMan = path.join(workDir, 'rel_man_v8.json');
  writeStoredZip(mockRelApk, [
    ['AndroidManifest.xml', Buffer.alloc(600, 0x33)],
    ['classes.dex', Buffer.alloc(600, 0x34)],
    ['lib/armeabi-v7a/libakai_uinput.so', Buffer.alloc(100, 0x35)],
    ['assets/www/index.html', '<html></html>'],
    ['assets/ota-release-public.der', releasePubDer],
    ['assets/ota-release-channel.txt', 'https://updates.akai-jarvis.example/releases/v8.manifest\n'],
  ]);
  const ownerSigner = '21c2c41dc4c34576cca14ad5404e87d1c5a07ace961c0fab96d128c2164a51ed';
  fs.writeFileSync(
    relMan,
    JSON.stringify({
      packageName: 'it.akai.customremote',
      versionCode: 8,
      versionName: '1.3.0-release-v8',
      buildProfile: 'Release',
      debuggable: false,
      signerSha256: ownerSigner,
      otaProvisioned: true,
    })
  );
  fs.writeFileSync(
    mockSig,
    `Verifies\nVerified using v2 scheme (APK Signature Scheme v2): true\nNumber of signers: 1\nSigner #1 certificate SHA-256 digest: ${ownerSigner}\n`
  );
  fs.writeFileSync(
    mockBadg,
    `package: name='it.akai.customremote' versionCode='8' versionName='1.3.0-release-v8'\nsdkVersion:'21'\ntargetSdkVersion:'28'\nnative-code: 'armeabi-v7a'\n`
  );
  fs.writeFileSync(mockXml, `E: manifest\n  E: application\n    A: android:debuggable(0x0101000f)=(type 0x12)0x0\n`);

  // Consistent Release v8 with priorRescue=7, maxInstalled=7, postReleaseRescue=9 -> ZERO version-floor rejections
  const rel17Ok = invokeScript17([
    '-ApkPath', mockRelApk,
    '-BuildManifestPath', relMan,
    '-OtaReleasePublicKeyPath', releasePubPath,
    '-OtaReleaseManifestUrl', 'https://updates.akai-jarvis.example/releases/v8.manifest',
    '-ChannelProfile', 'Release',
    '-RescueVersionCode', '7',
    '-MaxInstalledOrPreparedVersionCode', '7',
    '-PostReleaseRescueVersionCode', '9',
    '-MockApksignerReportPath', mockSig,
    '-MockAaptBadgingPath', mockBadg,
    '-MockAaptXmltreePath', mockXml,
  ]);
  assert.equal(rel17Ok.json.otaReady, false, 'Mock MUST remain non-authoritative');
  assert.equal(rel17Ok.json.priorRescueFloorVersionCode, 7);
  assert.equal(rel17Ok.json.postReleaseRescueVersionCode, 9);
  for (const forbiddenReason of [
    'RELEASE_VERSION_NOT_ABOVE_RESCUE',
    'RELEASE_VERSION_NOT_ABOVE_MAX_INSTALLED',
    'RELEASE_POST_RESCUE_NOT_ABOVE_CANDIDATE',
    'OTA_POST_RELEASE_RESCUE_VERSION_INVALID',
  ]) {
    assert.ok(!rel17Ok.json.reasons.includes(forbiddenReason), 'Unexpected floor rejection: ' + forbiddenReason);
  }
  count++;

  // Contradictory Release: postReleaseRescue=8 == candidate=8 -> Script 17 rejects RELEASE_POST_RESCUE_NOT_ABOVE_CANDIDATE
  const rel17BadPost = invokeScript17([
    '-ApkPath', mockRelApk,
    '-BuildManifestPath', relMan,
    '-OtaReleasePublicKeyPath', releasePubPath,
    '-OtaReleaseManifestUrl', 'https://updates.akai-jarvis.example/releases/v8.manifest',
    '-ChannelProfile', 'Release',
    '-RescueVersionCode', '7',
    '-MaxInstalledOrPreparedVersionCode', '7',
    '-PostReleaseRescueVersionCode', '8',
    '-MockApksignerReportPath', mockSig,
    '-MockAaptBadgingPath', mockBadg,
    '-MockAaptXmltreePath', mockXml,
  ]);
  assert.ok(
    rel17BadPost.json.reasons.includes('RELEASE_POST_RESCUE_NOT_ABOVE_CANDIDATE'),
    'Script 17 must reject postReleaseRescue <= manifestVersionCode'
  );
  count++;

  // 5. P1-A Negative checks even when RSA signature on receipt IS 100% VALID!
  // 5a: 1-byte modified backup bundle -> EVIDENCE_ARCHIVE_HASH_MISMATCH
  const tamperedBundle = path.join(workDir, 'tampered_copy.akv.json');
  const bBytes = fs.readFileSync(bundlePath);
  const altered = Buffer.from(bBytes);
  altered[10] ^= 0x55;
  fs.writeFileSync(tamperedBundle, altered);
  assert.throws(
    () =>
      verifyReceiptWithRealArchives({
        receiptPath: issuedRelease.receiptPath,
        sigPath: issuedRelease.sigPath,
        publicKeyDerPath: releasePubPath,
        bundlePath: tamperedBundle,
        rescueApkPath: rescueV9Apk,
        deviceUid,
        installedVersionCode: 6,
        candidateVersionCode: 8,
        nowEpochSec: nowSec,
      }),
    /EVIDENCE_ARCHIVE_HASH_MISMATCH/
  );
  count++;

  // 5b: missing backup bundle file -> EVIDENCE_ARCHIVE_MISSING
  assert.throws(
    () =>
      verifyReceiptWithRealArchives({
        receiptPath: issuedRelease.receiptPath,
        sigPath: issuedRelease.sigPath,
        publicKeyDerPath: releasePubPath,
        bundlePath: path.join(workDir, 'nonexistent_bundle.akv.json'),
        rescueApkPath: rescueV9Apk,
        deviceUid,
        installedVersionCode: 6,
        candidateVersionCode: 8,
        nowEpochSec: nowSec,
      }),
    /EVIDENCE_ARCHIVE_MISSING/
  );
  count++;

  // 5c: modified rescue APK -> EVIDENCE_RESCUE_APK_HASH_MISMATCH
  const tamperedRescue = path.join(workDir, 'tampered_rescue.apk');
  const rBytes = fs.readFileSync(rescueV9Apk);
  const rAltered = Buffer.from(rBytes);
  rAltered[rAltered.length - 10] ^= 0x0f;
  fs.writeFileSync(tamperedRescue, rAltered);
  assert.throws(
    () =>
      verifyReceiptWithRealArchives({
        receiptPath: issuedRelease.receiptPath,
        sigPath: issuedRelease.sigPath,
        publicKeyDerPath: releasePubPath,
        bundlePath,
        rescueApkPath: tamperedRescue,
        deviceUid,
        installedVersionCode: 6,
        candidateVersionCode: 8,
        nowEpochSec: nowSec,
      }),
    /EVIDENCE_RESCUE_APK_HASH_MISMATCH/
  );
  count++;

  // 5d: corrupted bundle refuses to ISSUE any receipt via Script 16 offline restore check!
  const corruptCipherBundle = path.join(workDir, 'corrupt_cipher.akv.json');
  const bJson = JSON.parse(fs.readFileSync(bundlePath, 'utf8'));
  const cb = Buffer.from(bJson.cipherB64, 'base64');
  cb[0] ^= 0x01;
  bJson.cipherB64 = cb.toString('base64');
  fs.writeFileSync(corruptCipherBundle, JSON.stringify(bJson));
  const failOutDir = path.join(workDir, 'should_not_emit');
  assert.throws(() =>
    issueArchiveVerifiedReceipt({
      repoRoot,
      channelProfile: 'release',
      deviceUid,
      installedVersionCode: 6,
      candidateVersionCode: 8,
      priorRescueFloorVersionCode: 7,
      recoveryRescueVersionCode: 9,
      backupId: 'bkp-bad',
      bundlePath: corruptCipherBundle,
      rescueApkPath: rescueV9Apk,
      bundlePassphrase: passphrase,
      privateKeyPemOrKeyObject: releasePriv,
      publicKeyDerBuf: releasePubDer,
      outReceiptPath: path.join(failOutDir, 'ota-recovery-evidence.receipt'),
      outSigPath: path.join(failOutDir, 'ota-recovery-evidence.receipt.sig'),
      nowEpochSec: nowSec,
      rescueApkProofRunner: runnerV9,
    })
  );
  assert.equal(fs.existsSync(path.join(failOutDir, 'ota-recovery-evidence.receipt')), false);
  count++;

  // 6. NEXT-8 Rescue APK cert / package / versionCode / debuggable negative checks:
  // Even with valid ZIP header + matching SHA-256 + valid RSA signature, BOTH issue & verify MUST fail closed!
  const rescueProofCases = [
    {
      label: 'wrong Rescue APK signer cert',
      runner: makeSyntheticRescueApkRunner({ versionCode: 9, signerSha256: 'f'.repeat(64) }),
      pattern: /APK_REJECTED_REAL_SIGNER/,
    },
    {
      label: 'wrong Rescue APK package',
      runner: makeSyntheticRescueApkRunner({ versionCode: 9, packageName: 'org.evil.rescue' }),
      pattern: /APK_REJECTED_PACKAGE_VERSION/,
    },
    {
      label: 'wrong Rescue APK versionCode != recoveryRescueVersionCode',
      runner: makeSyntheticRescueApkRunner({ versionCode: 8 }),
      pattern: /APK_REJECTED_PACKAGE_VERSION/,
    },
    {
      label: 'debuggable Rescue APK',
      runner: makeSyntheticRescueApkRunner({ versionCode: 9, debuggable: true }),
      pattern: /APK_REJECTED_DEBUGGABLE_TRUE/,
    },
  ];
  for (let i = 0; i < rescueProofCases.length; i++) {
    const tc = rescueProofCases[i];
    const badIssueDir = path.join(workDir, 'bad_rescue_issue_' + i);
    assert.throws(
      () =>
        issueArchiveVerifiedReceipt({
          repoRoot,
          channelProfile: 'release',
          deviceUid,
          installedVersionCode: 6,
          candidateVersionCode: 8,
          priorRescueFloorVersionCode: 7,
          recoveryRescueVersionCode: 9,
          backupId: 'bkp-bad-apk-' + i,
          bundlePath,
          rescueApkPath: rescueV9Apk,
          bundlePassphrase: passphrase,
          privateKeyPemOrKeyObject: releasePriv,
          publicKeyDerBuf: releasePubDer,
          outReceiptPath: path.join(badIssueDir, 'ota-recovery-evidence.receipt'),
          outSigPath: path.join(badIssueDir, 'ota-recovery-evidence.receipt.sig'),
          nowEpochSec: nowSec,
          rescueApkProofRunner: tc.runner,
        }),
      tc.pattern,
      'issue must reject ' + tc.label
    );
    assert.equal(fs.existsSync(path.join(badIssueDir, 'ota-recovery-evidence.receipt')), false);

    assert.throws(
      () =>
        verifyReceiptWithRealArchives({
          repoRoot,
          receiptPath: issuedRelease.receiptPath,
          sigPath: issuedRelease.sigPath,
          publicKeyDerPath: releasePubPath,
          bundlePath,
          rescueApkPath: rescueV9Apk,
          deviceUid,
          installedVersionCode: 6,
          candidateVersionCode: 8,
          nowEpochSec: nowSec,
          rescueApkProofRunner: tc.runner,
        }),
      tc.pattern,
      'verifyReceiptWithRealArchives must reject ' + tc.label
    );
    count++;
  }

  console.log(
    `test_ota_recovery_evidence_workflow PASS: ${count} checks (SYNTHETIC_HOST_FIXTURE_NON_AUTHORITATIVE — real script 16 restore + real archive hashes + Staging/Release cross-policy coherence; NOT OTA_PROVISIONED_READY, NOT TV PASS)`
  );
} finally {
  fs.rmSync(workDir, { recursive: true, force: true });
}
