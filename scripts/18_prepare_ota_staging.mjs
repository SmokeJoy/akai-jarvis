#!/usr/bin/env node
/*
 * Owner PC only, offline, zero dependencies.
 * Prepares and signs an ISOLATED Diagnostic OTA staging bundle using a
 * dedicated staging trust store (LOCALAPPDATA/AkaiJarvisOtaStagingTrust),
 * strictly separated from production OTA release trust.
 *
 * Usage:
 *  node scripts/18_prepare_ota_staging.mjs --mode init-staging-trust
 *  node scripts/18_prepare_ota_staging.mjs --mode sign-staging \
 *    --apk <diagnostic-ota-stage.apk> --handoff <JARVIS_FINAL_BUILD_MANIFEST.json> \
 *    --manifest-url <https://.../staging.manifest> --apk-url <https://.../staging.apk> \
 *    --approved-v4-source-sha <40hex> --out <private-staging-dir> \
 *    --owner-approved-after-tests
 *
 * Requires JARVIS_OTA_STAGING_PASSPHRASE (>= 20 chars). Zero TV/network/upload.
 */
import { execFileSync } from 'node:child_process';
import {
  createHash,
  createPrivateKey,
  createPublicKey,
  generateKeyPairSync,
  sign,
  constants as cryptoConstants,
} from 'node:crypto';
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
  constants as fsConstants,
} from 'node:fs';
import { basename, dirname, isAbsolute, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { findAndroidTool } from './lib/ota_release_apk_proof.mjs';

export const EXPECTED_PACKAGE = 'it.akai.customremote';
export const EXPECTED_SIGNER_SHA256 = '21c2c41dc4c34576cca14ad5404e87d1c5a07ace961c0fab96d128c2164a51ed';
const STAGING_MARKER_FILENAME = 'STAGING_ONLY_DO_NOT_PUBLISH_PUBLICLY.txt';

function mustPlan(ok, label) {
  if (!ok) throw new Error('OTA_VERSION_PLAN_REJECTED_' + label);
}

function mustStaging(ok, label) {
  if (!ok) throw new Error('STAGING_APK_REJECTED_' + label);
}

export function validateMonotonicVersionPlan(plan) {
  mustPlan(plan && typeof plan === 'object', 'MISSING_PLAN');
  const keys = [
    'installedA2',
    'v4Diagnostic',
    'a2Rescue',
    'otaStageBase',
    'otaStageTarget',
    'a2RescueForStaging',
    'v5Release',
  ];
  const values = [];
  for (const key of keys) {
    const val = plan[key];
    mustPlan(Number.isInteger(val) && val >= 1 && val <= 2147483647, 'NON_INTEGER_' + key);
    values.push(val);
  }
  for (let i = 1; i < values.length; i++) {
    mustPlan(
      values[i] > values[i - 1],
      `NOT_MONOTONIC_${keys[i - 1]}(${values[i - 1]})>=${keys[i]}(${values[i]})`
    );
  }
  return { ok: true, ordered: values };
}

export function validateHttpsStagingUrl(raw, extension) {
  if (typeof raw !== 'string' || raw.length === 0 || raw.length > 480 || /[^\x21-\x7e]/.test(raw)) {
    throw new Error('STAGING_URL_REJECTED_FORMAT');
  }
  const url = new URL(raw);
  if (
    url.protocol !== 'https:' ||
    !url.hostname ||
    url.port ||
    url.username ||
    url.password ||
    url.hash ||
    url.search ||
    !url.pathname.startsWith('/') ||
    !url.pathname.endsWith(extension)
  ) {
    throw new Error('STAGING_URL_REJECTED_HTTPS_PIN_' + extension);
  }
  const host = url.hostname.toLowerCase();
  if (
    host === 'localhost' ||
    host.endsWith('.localhost') ||
    host.endsWith('.local') ||
    host.endsWith('.lan') ||
    host.endsWith('.internal') ||
    host.endsWith('.home') ||
    host.startsWith('[') ||
    host.includes(':') ||
    /^\d{1,3}(?:\.\d{1,3}){3}$/.test(host) ||
    !host.includes('.') ||
    host.endsWith('.')
  ) {
    throw new Error('STAGING_URL_REJECTED_PRIVATE_OR_LOCAL_HOST');
  }
  return url;
}

export function auditDiagnosticStagingApkOutputs({ signerReport, badging, manifestXml, handoff }) {
  mustStaging(
    typeof signerReport === 'string' &&
      typeof badging === 'string' &&
      typeof manifestXml === 'string' &&
      handoff &&
      typeof handoff === 'object',
    'EVIDENCE_MISSING'
  );

  const signers = [
    ...signerReport.matchAll(/Signer #([0-9]+) certificate SHA-256 digest:\s*([0-9a-f]{64})\s*$/gim),
  ];
  mustStaging(
    signers.length === 1 &&
      signers[0][1] === '1' &&
      signers[0][2].toLowerCase() === EXPECTED_SIGNER_SHA256,
    'REAL_SIGNER'
  );

  const signerCounts = [...signerReport.matchAll(/^Number of signers:\s*([0-9]+)\s*$/gim)];
  mustStaging(signerCounts.length === 1 && signerCounts[0][1] === '1', 'SIGNER_COUNT');

  const v2Reports = [
    ...signerReport.matchAll(
      /^Verified using v2 scheme \(APK Signature Scheme v2\):\s*(true|false)\s*$/gim
    ),
  ];
  mustStaging(v2Reports.length === 1 && v2Reports[0][1].toLowerCase() === 'true', 'APK_V2_SIGNATURE');

  const pkgs = [
    ...badging.matchAll(
      /^package:\s+name='([^']+)'\s+versionCode='([0-9]+)'\s+versionName='([^']+)'(?:\s+[^\n]*)?$/gm
    ),
  ];
  mustStaging(
    pkgs.length === 1 &&
      pkgs[0][1] === EXPECTED_PACKAGE &&
      Number(pkgs[0][2]) === handoff.versionCode &&
      pkgs[0][3] === handoff.versionName,
    'PACKAGE_VERSION'
  );

  mustStaging(handoff.buildProfile === 'Diagnostic', 'NOT_DIAGNOSTIC_PROFILE');
  mustStaging(
    Number.isInteger(handoff.versionCode) && handoff.versionCode >= 6 && handoff.versionCode <= 99,
    'STAGING_VERSION_CODE_RANGE'
  );
  mustStaging(/diagnostic.*ota-stage/i.test(handoff.versionName || ''), 'VERSION_NAME_TAG');

  const sdkLines = [...badging.matchAll(/^sdkVersion:\s*'([^']*)'\s*$/gm)];
  const targetLines = [...badging.matchAll(/^targetSdkVersion:\s*'([^']*)'\s*$/gm)];
  const nativeLines = [...badging.matchAll(/^native-code:\s*(.*)$/gm)];
  mustStaging(
    sdkLines.length === 1 &&
      sdkLines[0][1] === '21' &&
      targetLines.length === 1 &&
      targetLines[0][1] === '28',
    'ANDROID9_SDK'
  );
  mustStaging(nativeLines.length === 1 && nativeLines[0][1].trim() === "'armeabi-v7a'", 'ANDROID_ARMV7');

  const debugAttributes = [
    ...manifestXml.matchAll(/^\s*A:\s+android:debuggable(?:\(0x[0-9a-f]+\))?\s*=/gim),
  ];
  mustStaging(debugAttributes.length === 1, 'DEBUGGABLE_ATTRIBUTE_COUNT');
  mustStaging(
    !/A:\s+android:debuggable(?:\(0x[0-9a-f]+\))?\s*=\s*\(type 0x12\)0x0(?:\s|$)/im.test(manifestXml),
    'NON_DEBUGGABLE_PRODUCTION_FORBIDDEN_IN_STAGING'
  );
  mustStaging(
    /A:\s+android:debuggable(?:\(0x[0-9a-f]+\))?\s*=\s*\(type 0x12\)0xffffffff(?:\s|$)/im.test(
      manifestXml
    ),
    'DEBUGGABLE_TRUE_NOT_PROVEN'
  );

  return {
    verified: true,
    stagingOnly: true,
    debuggable: true,
    packageName: EXPECTED_PACKAGE,
    versionCode: handoff.versionCode,
    versionName: handoff.versionName,
    originalSignerSha256: EXPECTED_SIGNER_SHA256,
  };
}

export function buildStagingManifestText({ versionCode, apkSha256, apkUrl, sizeBytes }) {
  mustStaging(Number.isInteger(versionCode) && versionCode >= 6 && versionCode <= 99, 'MANIFEST_VC');
  mustStaging(/^[0-9a-f]{64}$/.test(String(apkSha256 || '')), 'MANIFEST_SHA256');
  const validatedUrl = validateHttpsStagingUrl(apkUrl, '.apk');
  mustStaging(
    Number.isInteger(sizeBytes) && sizeBytes >= 1024 && sizeBytes <= 25 * 1024 * 1024,
    'MANIFEST_SIZE'
  );
  return (
    'format=jarvis-ota-v1\n' +
    'package=' + EXPECTED_PACKAGE + '\n' +
    'versionCode=' + versionCode + '\n' +
    'signerSha256=' + EXPECTED_SIGNER_SHA256 + '\n' +
    'apkSha256=' + apkSha256.toLowerCase() + '\n' +
    'url=' + validatedUrl.href + '\n' +
    'abi=armeabi-v7a\n' +
    'minSdk=21\n' +
    'sizeBytes=' + sizeBytes + '\n' +
    'channel=stable\n'
  );
}

function resolvePhysicalCandidateOutsideRepo(repoRoot, candidatePath, expectExistingParentOnly = false) {
  const full = resolve(candidatePath);
  const physicalRepo = realpathSync(repoRoot);
  let probe = expectExistingParentOnly ? dirname(full) : full;
  const tail = expectExistingParentOnly ? [basename(full)] : [];
  while (probe && !existsSync(probe)) {
    const parent = dirname(probe);
    if (!parent || parent === probe) break;
    tail.unshift(basename(probe));
    probe = parent;
  }
  const physicalBase = existsSync(probe) ? realpathSync(probe) : probe;
  const physicalTarget = resolve(physicalBase, ...tail);
  const rel = relative(physicalRepo, physicalTarget);
  const sep = process.platform === 'win32' ? '\\' : '/';
  if (rel === '' || (!rel.startsWith('..' + sep) && rel !== '..' && !isAbsolute(rel))) {
    throw new Error('Staging path must remain strictly outside the public repository (including junctions): ' + full);
  }
  return physicalTarget;
}

function proveActualDiagnosticStagingApk({ repoRoot, apkPath, handoff }) {
  const signerJar = findAndroidTool(repoRoot, 'lib/apksigner.jar');
  const javaExecutable = [
    process.env.JAVA_HOME ? join(process.env.JAVA_HOME, 'bin', 'java.exe') : null,
    join(repoRoot, 'tools', 'jdk-17', 'bin', 'java.exe'),
  ]
    .filter(Boolean)
    .find(existsSync);
  mustStaging(javaExecutable, 'JAVA_NOT_AVAILABLE');
  const aaptTool = findAndroidTool(repoRoot, 'aapt.exe');
  const opts = { encoding: 'utf8', timeout: 60000, maxBuffer: 8 * 1024 * 1024, windowsHide: true };
  const signerReport = execFileSync(
    javaExecutable,
    ['-jar', signerJar, 'verify', '--verbose', '--print-certs', apkPath],
    opts
  );
  const badging = execFileSync(aaptTool, ['dump', 'badging', apkPath], opts);
  const manifestXml = execFileSync(aaptTool, ['dump', 'xmltree', apkPath, 'AndroidManifest.xml'], opts);
  return auditDiagnosticStagingApkOutputs({ signerReport, badging, manifestXml, handoff });
}

function runCli() {
  if (
    process.platform !== 'win32' ||
    !process.env.LOCALAPPDATA ||
    process.env.CI ||
    process.env.GITHUB_ACTIONS
  ) {
    throw new Error('Offline OTA staging key/manifest tooling requires the owner Windows PC, never CI.');
  }

  const args = process.argv.slice(2);
  const fields = new Map();
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--owner-approved-after-tests') {
      fields.set(args[i], 'true');
      continue;
    }
    if (!args[i].startsWith('--') || !args[i + 1] || args[i + 1].startsWith('--')) {
      throw new Error('Expected --name value arguments.');
    }
    if (fields.has(args[i])) throw new Error('Duplicate CLI argument ' + args[i]);
    fields.set(args[i], args[++i]);
  }

  const mode = fields.get('--mode');
  if (mode !== 'init-staging-trust' && mode !== 'sign-staging') {
    throw new Error('Specify --mode init-staging-trust or --mode sign-staging.');
  }

  const repoRoot = resolve(fileURLToPath(new URL('..', import.meta.url)));
  const trustDir = resolve(process.env.LOCALAPPDATA, 'AkaiJarvisOtaStagingTrust');
  resolvePhysicalCandidateOutsideRepo(repoRoot, trustDir, false);

  const password = process.env.JARVIS_OTA_STAGING_PASSPHRASE;
  if (!password || password.length < 20 || password.length > 1024) {
    throw new Error('Set JARVIS_OTA_STAGING_PASSPHRASE (>= 20 characters) in your private PowerShell session.');
  }

  const privPath = join(trustDir, 'ota-staging-private.encrypted.pem');
  const pubPath = join(trustDir, 'ota-staging-public.der');

  if (mode === 'init-staging-trust') {
    mkdirSync(trustDir, { recursive: true, mode: 0o700 });
    if (existsSync(privPath) || existsSync(pubPath)) {
      throw new Error('Staging trust store already exists or is partial; never overwrite automatically.');
    }
    const { publicKey, privateKey } = generateKeyPairSync('rsa', {
      modulusLength: 3072,
      publicExponent: 0x10001,
      publicKeyEncoding: { type: 'spki', format: 'der' },
      privateKeyEncoding: {
        type: 'pkcs8',
        format: 'pem',
        cipher: 'aes-256-cbc',
        passphrase: password,
      },
    });
    writeFileSync(privPath, privateKey, { mode: 0o600, flag: 'wx' });
    writeFileSync(pubPath, publicKey, { mode: 0o600, flag: 'wx' });
    const fp = createHash('sha256').update(publicKey).digest('hex');
    process.stdout.write(
      'OFFLINE OTA STAGING KEY CREATED (isolated from production OTA trust)\n' +
        'Encrypted staging private key: ' + privPath + '\n' +
        'PUBLIC staging SPKI DER: ' + pubPath + '\n' +
        'Public DER SHA-256: ' + fp + '\n'
    );
    return;
  }

  const needed = [
    '--mode',
    '--apk',
    '--handoff',
    '--manifest-url',
    '--apk-url',
    '--out',
    '--approved-v4-source-sha',
  ];
  if (!needed.every(k => fields.has(k)) || !fields.has('--owner-approved-after-tests')) {
    throw new Error('sign-staging requires --apk, --handoff, --manifest-url, --apk-url, --approved-v4-source-sha, --out, --owner-approved-after-tests.');
  }

  const manifestUrl = validateHttpsStagingUrl(fields.get('--manifest-url'), '.manifest');
  const apkUrl = validateHttpsStagingUrl(fields.get('--apk-url'), '.apk');
  if (manifestUrl.hostname.toLowerCase() !== apkUrl.hostname.toLowerCase()) {
    throw new Error('Staging APK URL must match staging manifest HTTPS host.');
  }
  const manifestFile = basename(manifestUrl.pathname);
  const apkFile = basename(apkUrl.pathname);
  if (!manifestFile || !apkFile) throw new Error('Staging URLs require filenames.');

  const outDir = resolve(fields.get('--out'));
  resolvePhysicalCandidateOutsideRepo(repoRoot, outDir, true);
  if (existsSync(outDir)) throw new Error('Staging output folder already exists; never overwrite.');

  const apkPath = resolve(fields.get('--apk'));
  const handoff = JSON.parse(readFileSync(resolve(fields.get('--handoff')), 'utf8'));
  const approvedSha = String(fields.get('--approved-v4-source-sha') || '').toLowerCase();
  if (!/^[a-f0-9]{40}$/.test(approvedSha) || String(handoff.sourceCommit || '').toLowerCase() !== approvedSha) {
    throw new Error('Staging APK sourceCommit does not match approved HEAD SHA.');
  }

  if (
    handoff.packageName !== EXPECTED_PACKAGE ||
    handoff.buildProfile !== 'Diagnostic' ||
    handoff.debuggable !== true ||
    handoff.signedWithOwnerOriginalCert !== true ||
    String(handoff.signerSha256 || '').toLowerCase() !== EXPECTED_SIGNER_SHA256 ||
    handoff.abi !== 'armeabi-v7a' ||
    handoff.minSdk !== 21 ||
    handoff.targetSdk !== 28 ||
    handoff.otaPublicTrustProvisioned !== true ||
    String(handoff.otaChannelHost || '').toLowerCase() !== manifestUrl.hostname.toLowerCase()
  ) {
    throw new Error('Staging handoff failed mandatory Diagnostic/OTA host metadata gates.');
  }

  const apkBytes = readFileSync(apkPath);
  const apkSha = createHash('sha256').update(apkBytes).digest('hex');
  if (String(handoff.apkSha256 || '').toLowerCase() !== apkSha) {
    throw new Error('Staging APK bytes mismatch handoff apkSha256.');
  }
  proveActualDiagnosticStagingApk({ repoRoot, apkPath, handoff });

  if (!existsSync(privPath) || !existsSync(pubPath)) {
    throw new Error('Staging trust store missing; run --mode init-staging-trust first.');
  }
  const secretPem = readFileSync(privPath, 'utf8');
  const publicDer = readFileSync(pubPath);
  const privateKey = createPrivateKey({ key: secretPem, format: 'pem', passphrase: password });
  const pubActual = createPublicKey(privateKey).export({ type: 'spki', format: 'der' });
  if (!pubActual.equals(publicDer)) {
    throw new Error('Staging public/private key pair mismatch.');
  }

  const manifestText = buildStagingManifestText({
    versionCode: handoff.versionCode,
    apkSha256: apkSha,
    apkUrl: apkUrl.href,
    sizeBytes: apkBytes.length,
  });
  const manifestBytes = Buffer.from(manifestText, 'ascii');
  const signature = sign('RSA-SHA256', manifestBytes, {
    key: privateKey,
    padding: cryptoConstants.RSA_PKCS1_PADDING,
  });

  const stagingDir = mkdtempSync(join(dirname(outDir), '.jarvis-ota-stage-tmp-'));
  let committed = false;
  try {
    const stagedApkPath = join(stagingDir, apkFile);
    copyFileSync(apkPath, stagedApkPath, fsConstants.COPYFILE_EXCL);
    const stagedBytes = readFileSync(stagedApkPath);
    const stagedSha = createHash('sha256').update(stagedBytes).digest('hex');
    if (stagedBytes.length !== apkBytes.length || stagedSha !== apkSha) {
      throw new Error('Staged APK bytes changed during copy.');
    }
    proveActualDiagnosticStagingApk({ repoRoot, apkPath: stagedApkPath, handoff });
    writeFileSync(join(stagingDir, manifestFile), manifestBytes, { flag: 'wx' });
    writeFileSync(join(stagingDir, manifestFile + '.sig'), signature, { flag: 'wx' });
    writeFileSync(
      join(stagingDir, STAGING_MARKER_FILENAME),
      'DIAGNOSTIC OTA STAGING BUNDLE ONLY.\n' +
        'VersionCode: ' + handoff.versionCode + '\n' +
        'VersionName: ' + handoff.versionName + '\n' +
        'APK SHA-256: ' + apkSha + '\n' +
        'DO NOT PUBLISH AS PRODUCTION RELEASE.\n',
      { flag: 'wx' }
    );
    if (existsSync(outDir)) throw new Error('Target staging output dir appeared concurrently.');
    renameSync(stagingDir, outDir);
    committed = true;
  } finally {
    if (!committed) {
      try {
        rmSync(stagingDir, { recursive: true, force: true });
      } catch (e) {
        process.stderr.write('WARNING: staging cleanup failed: ' + stagingDir + '\n');
      }
    }
  }

  process.stdout.write(
    'ISOLATED DIAGNOSTIC OTA STAGING FOLDER READY (NOT UPLOADED, NOT INSTALLED).\n' +
      'Output: ' + outDir + '\n' +
      'Version: ' + handoff.versionCode + ' (' + handoff.versionName + ')\n' +
      'APK SHA-256: ' + apkSha + '\n' +
      'Staging public DER SHA-256: ' + createHash('sha256').update(publicDer).digest('hex') + '\n'
  );
}

const isMain =
  Boolean(process.argv[1]) && resolve(fileURLToPath(import.meta.url)) === resolve(process.argv[1]);
if (isMain) {
  runCli();
}
