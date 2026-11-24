import { execFileSync } from 'node:child_process';
import {
  createHash,
  createPublicKey,
  sign,
  verify,
} from 'node:crypto';
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { proveActualRescueApk } from './ota_release_apk_proof.mjs';

export const EXPECTED_PACKAGE = 'it.akai.customremote';
export const MAX_RECEIPT_BYTES = 4096;
export const MAX_FUTURE_SKEW_SEC = 300;
export const MAX_RECEIPT_LIFETIME_SEC = 90 * 86400;

const FIELD_NAMES = [
  'format',
  'package',
  'channelProfile',
  'deviceUid',
  'installedVersionCode',
  'backupId',
  'backupCreatedEpochSec',
  'backupExpiresEpochSec',
  'backupArchiveSha256',
  'priorRescueFloorVersionCode',
  'recoveryRescueVersionCode',
  'rescueApkSha256',
  'offlineRestoreVerified',
  'nonDestructiveVerified',
];

function fail(code) {
  throw new Error(code);
}

function assertPositiveInt(raw, code = 'EVIDENCE_FORMAT_INVALID') {
  const s = String(raw ?? '');
  if (!/^[1-9][0-9]{0,9}$/.test(s)) fail(code);
  const n = Number(s);
  if (!Number.isSafeInteger(n) || n > 2147483647) fail(code);
  return n;
}

function assertNonNegativeInt(raw, code = 'EVIDENCE_FORMAT_INVALID') {
  if (String(raw) === '0') return 0;
  return assertPositiveInt(raw, code);
}

function assertPositiveLong(raw, code = 'EVIDENCE_FORMAT_INVALID') {
  const s = String(raw ?? '');
  if (!/^[1-9][0-9]{0,15}$/.test(s)) fail(code);
  const n = Number(s);
  if (!Number.isSafeInteger(n) || n <= 0) fail(code);
  return n;
}

export function sha256ExistingRegularFile(filePath, missingCode = 'EVIDENCE_ARCHIVE_MISSING') {
  if (!filePath || !existsSync(filePath)) fail(missingCode);
  const st = lstatSync(filePath);
  if (st.isSymbolicLink() || !st.isFile() || st.size <= 0) {
    fail(missingCode);
  }
  const buf = readFileSync(filePath);
  return {
    bytes: buf,
    size: buf.length,
    sha256: createHash('sha256').update(buf).digest('hex').toLowerCase(),
  };
}

export function buildCanonicalEvidenceReceipt(fields) {
  if (!fields || typeof fields !== 'object') fail('EVIDENCE_FORMAT_INVALID');
  const ordered = {
    format: 'jarvis-ota-evidence-v2',
    package: EXPECTED_PACKAGE,
    channelProfile: String(fields.channelProfile || ''),
    deviceUid: String(fields.deviceUid || ''),
    installedVersionCode: String(fields.installedVersionCode ?? ''),
    backupId: String(fields.backupId || ''),
    backupCreatedEpochSec: String(fields.backupCreatedEpochSec ?? ''),
    backupExpiresEpochSec: String(fields.backupExpiresEpochSec ?? ''),
    backupArchiveSha256: String(fields.backupArchiveSha256 || '').toLowerCase(),
    priorRescueFloorVersionCode: String(fields.priorRescueFloorVersionCode ?? '0'),
    recoveryRescueVersionCode: String(fields.recoveryRescueVersionCode ?? ''),
    rescueApkSha256: String(fields.rescueApkSha256 || '').toLowerCase(),
    offlineRestoreVerified: fields.offlineRestoreVerified === true ? 'true' : String(fields.offlineRestoreVerified || 'false'),
    nonDestructiveVerified: fields.nonDestructiveVerified === true ? 'true' : String(fields.nonDestructiveVerified || 'false'),
  };
  let out = '';
  for (const k of FIELD_NAMES) {
    const val = ordered[k];
    if (!val || /[^\x21-\x7e]/.test(val)) fail('EVIDENCE_NONCANONICAL_BYTES');
    out += `${k}=${val}\n`;
  }
  const buf = Buffer.from(out, 'ascii');
  if (buf.length > MAX_RECEIPT_BYTES) fail('EVIDENCE_SIGNATURE_INVALID');
  return buf;
}

export function parseAndVerifyEvidenceBytes(
  receiptBuf,
  sigBuf,
  publicKeyDerBuf,
  { deviceUid, installedVersionCode, candidateVersionCode, nowEpochSec }
) {
  if (!Buffer.isBuffer(receiptBuf) || receiptBuf.length === 0 || receiptBuf.length > MAX_RECEIPT_BYTES) {
    fail('EVIDENCE_SIGNATURE_INVALID');
  }
  if (!Buffer.isBuffer(sigBuf) || sigBuf.length === 0 || !Buffer.isBuffer(publicKeyDerBuf) || publicKeyDerBuf.length === 0) {
    fail('EVIDENCE_SIGNATURE_INVALID');
  }
  let publicKey;
  try {
    publicKey = createPublicKey({ key: publicKeyDerBuf, format: 'der', type: 'spki' });
  } catch {
    fail('EVIDENCE_SIGNATURE_INVALID');
  }
  let sigOk = false;
  try {
    sigOk = verify('SHA256', receiptBuf, publicKey, sigBuf);
  } catch {
    sigOk = false;
  }
  if (!sigOk) fail('EVIDENCE_SIGNATURE_INVALID');

  for (const byte of receiptBuf) {
    if (byte !== 10 && (byte < 33 || byte > 126)) fail('EVIDENCE_NONCANONICAL_BYTES');
  }
  const raw = receiptBuf.toString('ascii');
  if (!raw.endsWith('\n')) fail('EVIDENCE_MISSING_TERMINATOR');
  const lines = raw.split('\n');
  if (lines.length !== FIELD_NAMES.length + 1 || lines[FIELD_NAMES.length] !== '') {
    fail('EVIDENCE_LINE_COUNT_INVALID');
  }

  const fields = {};
  for (let i = 0; i < FIELD_NAMES.length; i++) {
    const name = FIELD_NAMES[i];
    const prefix = name + '=';
    if (!lines[i].startsWith(prefix) || lines[i].length <= prefix.length) {
      fail('EVIDENCE_FIELD_INVALID_' + name);
    }
    fields[name] = lines[i].slice(prefix.length);
  }

  if (fields.format !== 'jarvis-ota-evidence-v2') fail('EVIDENCE_FORMAT_UNSUPPORTED');
  if (fields.package !== EXPECTED_PACKAGE) fail('EVIDENCE_PACKAGE_MISMATCH');
  if (fields.channelProfile !== 'staging' && fields.channelProfile !== 'release') {
    fail('EVIDENCE_CHANNEL_PROFILE_INVALID');
  }
  if (typeof deviceUid !== 'string' || !/^[A-Za-z0-9._:-]{8,128}$/.test(deviceUid)) {
    fail('EVIDENCE_DEVICE_UID_UNAVAILABLE');
  }
  if (!/^[A-Za-z0-9._:-]{8,128}$/.test(fields.deviceUid) || fields.deviceUid !== deviceUid) {
    fail('EVIDENCE_DEVICE_UID_MISMATCH');
  }
  const recInstalled = assertPositiveInt(fields.installedVersionCode);
  if (!Number.isInteger(installedVersionCode) || installedVersionCode < 1 || recInstalled !== installedVersionCode) {
    fail('EVIDENCE_INSTALLED_VERSION_MISMATCH');
  }
  if (!/^[A-Za-z0-9._:-]{4,64}$/.test(fields.backupId)) fail('EVIDENCE_BACKUP_ID_INVALID');

  const created = assertPositiveLong(fields.backupCreatedEpochSec);
  const expires = assertPositiveLong(fields.backupExpiresEpochSec);
  if (!Number.isSafeInteger(nowEpochSec) || nowEpochSec <= 0) fail('EVIDENCE_CLOCK_INVALID');
  if (created > nowEpochSec + MAX_FUTURE_SKEW_SEC) fail('EVIDENCE_CREATED_IN_FUTURE');
  if (expires <= created) fail('EVIDENCE_WINDOW_INVALID');
  if (expires - created > MAX_RECEIPT_LIFETIME_SEC) fail('EVIDENCE_LIFETIME_EXCESSIVE');
  if (nowEpochSec >= expires) fail('EVIDENCE_EXPIRED');

  if (!/^[0-9a-fA-F]{64}$/.test(fields.backupArchiveSha256)) fail('EVIDENCE_BACKUP_DIGEST_INVALID');
  const priorRescueFloor = assertNonNegativeInt(fields.priorRescueFloorVersionCode);
  if (priorRescueFloor !== 0 && priorRescueFloor < 5) fail('EVIDENCE_PRIOR_RESCUE_FLOOR_INVALID');
  const recoveryRescueVersion = assertPositiveInt(fields.recoveryRescueVersionCode);
  if (!/^[0-9a-fA-F]{64}$/.test(fields.rescueApkSha256)) fail('EVIDENCE_RESCUE_DIGEST_INVALID');

  if (!Number.isInteger(candidateVersionCode) || candidateVersionCode <= installedVersionCode) {
    fail('EVIDENCE_CANDIDATE_NOT_ABOVE_INSTALLED');
  }
  if (fields.channelProfile === 'release') {
    if (priorRescueFloor < 5 || candidateVersionCode <= priorRescueFloor) {
      fail('EVIDENCE_RELEASE_NOT_ABOVE_PRIOR_RESCUE');
    }
  } else if (priorRescueFloor !== 0 && candidateVersionCode <= priorRescueFloor) {
    fail('EVIDENCE_STAGING_NOT_ABOVE_PRIOR_RESCUE');
  }
  if (recoveryRescueVersion < 5 || recoveryRescueVersion <= candidateVersionCode) {
    fail('EVIDENCE_RECOVERY_RESCUE_NOT_ABOVE_CANDIDATE');
  }

  if (fields.offlineRestoreVerified !== 'true' && fields.offlineRestoreVerified !== 'false') {
    fail('EVIDENCE_FORMAT_INVALID');
  }
  if (fields.nonDestructiveVerified !== 'true' && fields.nonDestructiveVerified !== 'false') {
    fail('EVIDENCE_FORMAT_INVALID');
  }
  if (fields.offlineRestoreVerified !== 'true') fail('EVIDENCE_OFFLINE_RESTORE_NOT_VERIFIED');
  if (fields.nonDestructiveVerified !== 'true') fail('EVIDENCE_NONDESTRUCTIVE_RESTORE_NOT_VERIFIED');

  return {
    accepted: true,
    channelProfile: fields.channelProfile,
    backupId: fields.backupId,
    backupArchiveSha256: fields.backupArchiveSha256.toLowerCase(),
    priorRescueFloorVersionCode: priorRescueFloor,
    recoveryRescueVersionCode: recoveryRescueVersion,
    rescueApkSha256: fields.rescueApkSha256.toLowerCase(),
    installedVersionCode: recInstalled,
  };
}

export function findPowerShellExecutable() {
  if (process.platform === 'win32') {
    return 'powershell.exe';
  }
  return 'pwsh';
}

export function runScript16OfflineRestoreVerify({ repoRoot, bundlePath, verificationTempRoot, passphrase }) {
  if (!bundlePath || !existsSync(bundlePath)) fail('EVIDENCE_ARCHIVE_MISSING');
  if (!passphrase || passphrase.length < 20) fail('EVIDENCE_PASSPHRASE_TOO_SHORT');
  const script16 = join(repoRoot, 'scripts', '16_export_portable_recovery_bundle.ps1');
  if (!existsSync(script16)) fail('SCRIPT16_NOT_FOUND');

  const psExe = findPowerShellExecutable();
  const baseArgs = process.platform === 'win32'
    ? ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script16]
    : ['-NoProfile', '-File', script16];
  const args = [
    ...baseArgs,
    '-Action', 'verify-restore-offline',
    '-BundlePath', resolve(bundlePath),
  ];
  if (verificationTempRoot) {
    args.push('-VerificationTempRoot', resolve(verificationTempRoot));
  }
  const stdout = execFileSync(psExe, args, {
    encoding: 'utf8',
    env: { ...process.env, JARVIS_RECOVERY_PASSPHRASE: passphrase },
  });
  const parsed = JSON.parse(stdout);
  if (
    parsed.status !== 'OFFLINE_RESTORE_VERIFIED' ||
    parsed.sqliteIntegrity !== 'ok' ||
    parsed.pkcs12HasPrivateKey !== true
  ) {
    fail('EVIDENCE_OFFLINE_RESTORE_CHECK_FAILED');
  }
  return parsed;
}

export function verifyReceiptWithRealArchives({
  repoRoot,
  receiptPath,
  sigPath,
  publicKeyDerPath,
  bundlePath,
  rescueApkPath,
  deviceUid,
  installedVersionCode,
  candidateVersionCode,
  nowEpochSec,
  rescueApkProofRunner,
}) {
  if (!existsSync(receiptPath) || !existsSync(sigPath)) fail('EVIDENCE_RECEIPT_MISSING');
  if (!existsSync(publicKeyDerPath)) fail('EVIDENCE_TRUST_KEY_NOT_PROVISIONED');

  const receiptBuf = readFileSync(receiptPath);
  const sigBuf = readFileSync(sigPath);
  const pubDer = readFileSync(publicKeyDerPath);

  const policy = parseAndVerifyEvidenceBytes(receiptBuf, sigBuf, pubDer, {
    deviceUid,
    installedVersionCode,
    candidateVersionCode,
    nowEpochSec,
  });

  // P1-A physical archive verification: recompute real hashes on disk AFTER
  // verifying RSA signature so valid signatures can never mask missing/tampered files.
  const bundleInfo = sha256ExistingRegularFile(bundlePath, 'EVIDENCE_ARCHIVE_MISSING');
  if (bundleInfo.sha256 !== policy.backupArchiveSha256) {
    fail('EVIDENCE_ARCHIVE_HASH_MISMATCH');
  }
  const rescueInfo = sha256ExistingRegularFile(rescueApkPath, 'EVIDENCE_RESCUE_APK_MISSING');
  if (rescueInfo.size < 1024 || rescueInfo.bytes[0] !== 0x50 || rescueInfo.bytes[1] !== 0x4b) {
    fail('EVIDENCE_RESCUE_APK_INVALID');
  }
  if (rescueInfo.sha256 !== policy.rescueApkSha256) {
    fail('EVIDENCE_RESCUE_APK_HASH_MISMATCH');
  }
  const resolvedRepoRoot = repoRoot || resolve(fileURLToPath(new URL('../..', import.meta.url)));
  const rescueApkProof = proveActualRescueApk({
    repoRoot: resolvedRepoRoot,
    apkPath: rescueApkPath,
    expectedVersionCode: policy.recoveryRescueVersionCode,
    runner: rescueApkProofRunner,
  });

  return {
    ...policy,
    archivePhysicallyVerified: true,
    rescueApkPhysicallyVerified: true,
    rescueApkCertVerified: true,
    rescueApkPackage: rescueApkProof.packageName,
    rescueApkVersionCode: rescueApkProof.versionCode,
    rescueApkSignerSha256: rescueApkProof.originalSignerSha256,
    verifiedBundleBytes: bundleInfo.size,
    verifiedRescueApkBytes: rescueInfo.size,
  };
}

export function issueArchiveVerifiedReceipt({
  repoRoot,
  channelProfile,
  deviceUid,
  installedVersionCode,
  candidateVersionCode,
  priorRescueFloorVersionCode,
  recoveryRescueVersionCode,
  backupId,
  bundlePath,
  rescueApkPath,
  verificationTempRoot,
  bundlePassphrase,
  privateKeyPemOrKeyObject,
  publicKeyDerBuf,
  outReceiptPath,
  outSigPath,
  nowEpochSec,
  validityDays = 7,
  nonDestructiveVerified = true,
  rescueApkProofRunner,
}) {
  if (!Number.isInteger(validityDays) || validityDays < 1 || validityDays > 90) {
    fail('EVIDENCE_LIFETIME_EXCESSIVE');
  }
  if (nonDestructiveVerified !== true) {
    fail('EVIDENCE_NONDESTRUCTIVE_RESTORE_NOT_VERIFIED');
  }

  const bundleInfo = sha256ExistingRegularFile(bundlePath, 'EVIDENCE_ARCHIVE_MISSING');
  const rescueInfo = sha256ExistingRegularFile(rescueApkPath, 'EVIDENCE_RESCUE_APK_MISSING');
  if (rescueInfo.size < 1024 || rescueInfo.bytes[0] !== 0x50 || rescueInfo.bytes[1] !== 0x4b) {
    fail('EVIDENCE_RESCUE_APK_INVALID');
  }

  // Verify actual Rescue APK signing cert, packageName, versionCode, SDK/ABI & debuggable=false BEFORE signing
  const rescueApkProof = proveActualRescueApk({
    repoRoot,
    apkPath: rescueApkPath,
    expectedVersionCode: recoveryRescueVersionCode,
    runner: rescueApkProofRunner,
  });

  // Execute real encrypted backup decryption, SQLite integrity check, PKCS#12 + XML verification
  const restoreEvidence = runScript16OfflineRestoreVerify({
    repoRoot,
    bundlePath,
    verificationTempRoot,
    passphrase: bundlePassphrase,
  });

  const created = nowEpochSec;
  const expires = created + validityDays * 86400;
  const receiptBuf = buildCanonicalEvidenceReceipt({
    channelProfile,
    deviceUid,
    installedVersionCode,
    backupId,
    backupCreatedEpochSec: created,
    backupExpiresEpochSec: expires,
    backupArchiveSha256: bundleInfo.sha256,
    priorRescueFloorVersionCode,
    recoveryRescueVersionCode,
    rescueApkSha256: rescueInfo.sha256,
    offlineRestoreVerified: true,
    nonDestructiveVerified: true,
  });

  const sigBuf = sign('SHA256', receiptBuf, privateKeyPemOrKeyObject);
  // Self-verify against SPKI DER + full archive checks before atomic write
  parseAndVerifyEvidenceBytes(receiptBuf, sigBuf, publicKeyDerBuf, {
    deviceUid,
    installedVersionCode,
    candidateVersionCode,
    nowEpochSec,
  });

  const outDir = dirname(outReceiptPath);
  mkdirSync(outDir, { recursive: true });
  writeAtomicOut(outReceiptPath, receiptBuf);
  writeAtomicOut(outSigPath, sigBuf);

  return {
    receiptPath: outReceiptPath,
    sigPath: outSigPath,
    backupArchiveSha256: bundleInfo.sha256,
    rescueApkSha256: rescueInfo.sha256,
    rescueApkProof,
    restoreEvidence,
  };
}

function writeAtomicOut(destPath, dataBuf) {
  if (existsSync(destPath) && lstatSync(destPath).isSymbolicLink()) {
    fail('EVIDENCE_SYMLINK_FORBIDDEN');
  }
  const tmpPath = destPath + '.tmp.' + process.pid;
  try {
    writeFileSync(tmpPath, dataBuf);
    renameSync(tmpPath, destPath);
  } finally {
    if (existsSync(tmpPath)) rmSync(tmpPath, { force: true });
  }
}
