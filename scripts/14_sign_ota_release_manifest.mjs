#!/usr/bin/env node
/*
 * Owner PC only, offline, zero dependencies. PREPARES (but never publishes)
 * a signed jarvis-ota-v1 manifest, its detached RSA signature, and the exact
 * original-signer Android APK as a reviewable private release folder.
 *
 * Usage:
 *  node scripts/14_sign_ota_release_manifest.mjs --apk <verified-owner.apk>
 *    --handoff <JARVIS_FINAL_BUILD_MANIFEST.json>
 *    --manifest-url <https://.../jarvis.manifest>
 *    --apk-url <https://.../jarvis.apk>
 *    --approved-v4-source-sha <40hex-approved-v4-HEAD>
 *    --out <private-output-dir> --owner-approved-after-tests
 *
 * Requires the distinct owner-offline OTA RSA private key created by script 13,
 * and JARVIS_OTA_RELEASE_PASSPHRASE environment secret. NO uploading or TV.
 */
import { readFileSync, writeFileSync, mkdtempSync, renameSync, rmSync, copyFileSync, existsSync, realpathSync, constants as fsConstants } from 'node:fs';
import { createPrivateKey, createPublicKey, createHash, sign, constants as cryptoConstants } from 'node:crypto';
import { resolve, join, basename, relative, isAbsolute, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { proveActualOwnerSignedApk } from './lib/ota_release_apk_proof.mjs';

export function validateReleaseHttpsUrl(raw, extension) {
  if (typeof raw !== 'string' || raw.length === 0 || raw.length > 480 || /[^\x21-\x7e]/.test(raw)) {
    throw new Error('RELEASE_URL_REJECTED_FORMAT');
  }
  const rawLower = raw.toLowerCase();
  if (raw.includes('\\') || raw.includes('/../') || raw.endsWith('/..') ||
      rawLower.includes('%2e') || rawLower.includes('%2f') || rawLower.includes('%5c')) {
    throw new Error('RELEASE_URL_REJECTED_PATH_TRAVERSAL');
  }
  const url = new URL(raw);
  if (url.protocol !== 'https:' || !url.hostname || url.port ||
      url.username || url.password || url.hash || url.search ||
      !url.pathname.endsWith(extension) || !url.pathname.startsWith('/')) {
    throw new Error('RELEASE_URL_REJECTED_HTTPS_PIN_' + extension);
  }
  const host = url.hostname.toLowerCase();
  if (host === 'localhost' || host.endsWith('.localhost') || host.endsWith('.local') ||
      host.endsWith('.lan') || host.endsWith('.internal') || host.endsWith('.home') ||
      host.startsWith('[') || host.includes(':') || host.startsWith('.') ||
      host.endsWith('.') || host.includes('..') || !host.includes('.') ||
      /^\d{1,3}(?:\.\d{1,3}){3}$/.test(host)) {
    throw new Error('RELEASE_URL_REJECTED_PRIVATE_OR_LOCAL_HOST');
  }
  return url;
}

function runCli() {
  if (process.platform !== 'win32' || !process.env.LOCALAPPDATA ||
      process.env.CI || process.env.GITHUB_ACTIONS)
    throw new Error('Offline release signing requires the owner Windows PC, never CI.');

  const args = process.argv.slice(2);
  const fields = new Map();
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--owner-approved-after-tests') {
      fields.set(args[i], 'true'); continue;
    }
    if (!args[i].startsWith('--') || !args[i + 1] || args[i + 1].startsWith('--'))
      throw new Error('Expected --name value pairs; see usage in script header.');
    if (fields.has(args[i])) throw new Error('Duplicate CLI argument ' + args[i]);
    fields.set(args[i], args[++i]);
  }
  const needed = ['--apk','--handoff','--manifest-url','--apk-url','--out','--approved-v4-source-sha'];
  if (!needed.every(x => fields.has(x)) ||
      fields.size !== needed.length + 1 ||
      !fields.has('--owner-approved-after-tests'))
    throw new Error('Must provide all paths/URLs and explicit --owner-approved-after-tests confirmation.');

  const manifestUrl = validateReleaseHttpsUrl(fields.get('--manifest-url'), '.manifest');
  const apkUrl = validateReleaseHttpsUrl(fields.get('--apk-url'), '.apk');
if (manifestUrl.hostname.toLowerCase() !== apkUrl.hostname.toLowerCase())
  throw new Error('Signed APK URL must use the same owner-pinned HTTPS host.');
const manifestFile = basename(manifestUrl.pathname);
const apkFile = basename(apkUrl.pathname);
if (!manifestFile || !apkFile) throw new Error('Release URLs lack filenames');

const repoRoot = resolve(fileURLToPath(new URL('..', import.meta.url)));
const outDir = resolve(fields.get('--out'));
// Resolve the existing output parent physically: Windows junctions and directory
// symlinks can make a lexically external path write inside this repository.
// A missing parent fails closed; this offline tool never creates parent folders.
const physicalRepo = realpathSync(repoRoot);
const physicalParent = realpathSync(dirname(outDir));
const physicalTarget = resolve(physicalParent, basename(outDir));
const outsideRepo = relative(physicalRepo, physicalTarget);
if (outsideRepo === '' || (!outsideRepo.startsWith('..' + (process.platform === 'win32' ? '\\' : '/')) && outsideRepo !== '..' && !isAbsolute(outsideRepo)))
  throw new Error('Do not prepare public-release artifacts inside the source repository (including junctions).');
if (existsSync(outDir)) throw new Error('Output folder already exists; never overwrite an existing release.');
const apkPath = resolve(fields.get('--apk'));
const handoff = JSON.parse(readFileSync(resolve(fields.get('--handoff')), 'utf8'));
const ownerApprovedV4Sha = String(fields.get('--approved-v4-source-sha') || '').toLowerCase();
if (!/^[a-f0-9]{40}$/.test(ownerApprovedV4Sha) ||
    String(handoff.sourceCommit || '').toLowerCase() !== ownerApprovedV4Sha)
  throw new Error('V5 release source MUST equal independently TV-approved v4 source HEAD. No functional code changes allowed.');
const signer = '21c2c41dc4c34576cca14ad5404e87d1c5a07ace961c0fab96d128c2164a51ed';
if (handoff.packageName !== 'it.akai.customremote' ||
    handoff.buildProfile !== 'Release' || handoff.debuggable !== false ||
    !/^[a-z0-9][a-z0-9._-]{0,60}$/i.test(handoff.versionName || '') ||
    /diagnostic|debug/i.test(handoff.versionName || '') ||
    handoff.productionProfile !== true || handoff.signedWithOwnerOriginalCert !== true ||
    String(handoff.signerSha256 || '').toLowerCase() !== signer ||
    handoff.installed !== false || !Number.isInteger(handoff.versionCode) ||
    handoff.versionCode <= 4 || handoff.versionCode > 2147483647 ||
    handoff.abi !== 'armeabi-v7a' || handoff.minSdk !== 21 ||
    handoff.targetSdk !== 28 || !/^[a-f0-9]{40}$/i.test(handoff.sourceCommit || ''))
  throw new Error('Handoff does not certify an Android9 owner-original-signed non-debug release candidate.');
const apkBytes = readFileSync(apkPath);
const apkSha = createHash('sha256').update(apkBytes).digest('hex');
if (apkBytes.length < 1024 || apkBytes.length > 25 * 1024 * 1024 ||
    String(handoff.apkSha256 || '').toLowerCase() !== apkSha)
  throw new Error('APK bytes mismatch handoff hash, length or OTA size limit.');

// CRITICAL: JSON handoff claims CAN be forged or stale. Verify the ACTUAL
// binary via official Android apksigner + aapt, not only handoff booleans.
// Any missing Android SDK tool, mismatched certificate/version, debug=true,
// non-ARMv7 or failed APK signature aborts before a manifest is signed.
proveActualOwnerSignedApk({ repoRoot, apkPath, handoff });
if (handoff.otaPublicTrustProvisioned !== true ||
    String(handoff.otaChannelHost || '').toLowerCase() !== manifestUrl.hostname.toLowerCase())
  throw new Error('APK lacks pinned OTA public key/channel for this exact HTTPS host.');


const privateDir = resolve(process.env.LOCALAPPDATA, 'AkaiJarvisOtaReleaseTrust');
const secretPem = readFileSync(join(privateDir, 'ota-release-private.encrypted.pem'), 'utf8');
const publicDer = readFileSync(join(privateDir, 'ota-release-public.der'));
const password = process.env.JARVIS_OTA_RELEASE_PASSPHRASE;
if (!password) throw new Error('Missing private offline manifest signing passphrase.');
const privateKey = createPrivateKey({ key: secretPem, format: 'pem', passphrase: password });
const pubActual = createPublicKey(privateKey).export({ type: 'spki', format: 'der' });
if (!pubActual.equals(publicDer)) throw new Error('Offline release public/private key pair mismatch.');

const manifest =
  'format=jarvis-ota-v1\n' +
  'package=it.akai.customremote\n' +
  'versionCode=' + handoff.versionCode + '\n' +
  'signerSha256=' + signer + '\n' +
  'apkSha256=' + apkSha + '\n' +
  'url=' + apkUrl.href + '\n' +
  'abi=armeabi-v7a\n' +
  'minSdk=21\n' +
  'sizeBytes=' + apkBytes.length + '\n' +
  'channel=stable\n';
const manifestBytes = Buffer.from(manifest, 'ascii');
const signature = sign('RSA-SHA256', manifestBytes,
  { key: privateKey, padding: cryptoConstants.RSA_PKCS1_PADDING });
if (manifestBytes.length > 8192 || signature.length < 256 || signature.length > 512)
  throw new Error('Unexpected signed release manifest/signature format.');

// Prepare the complete private bundle beside its final directory, then expose
// it with a single same-parent rename. Failed preparation never leaves a
// partially populated final release folder. Never remove an existing release.
const stagingDir = mkdtempSync(join(dirname(outDir), '.jarvis-ota-staging-'));
let committed = false;
try {
  const stagedApkPath = join(stagingDir, apkFile);
  copyFileSync(apkPath, stagedApkPath, fsConstants.COPYFILE_EXCL);
  const stagedApkBytes = readFileSync(stagedApkPath);
  const stagedApkSha = createHash('sha256').update(stagedApkBytes).digest('hex');
  if (stagedApkBytes.length !== apkBytes.length || stagedApkSha !== apkSha)
    throw new Error('Staged APK differs from verified candidate; abort release preparation.');
  proveActualOwnerSignedApk({ repoRoot, apkPath: stagedApkPath, handoff });
  writeFileSync(join(stagingDir, manifestFile), manifestBytes, { flag: 'wx' });
  writeFileSync(join(stagingDir, manifestFile + '.sig'), signature, { flag: 'wx' });
  // On the owner Windows filesystem, rename to an existing directory fails.
  // Recheck immediately before rename to reject a concurrently created target.
  if (existsSync(outDir)) throw new Error('Output folder appeared during staging; never overwrite.');
  renameSync(stagingDir, outDir);
  committed = true;
} finally {
  if (!committed) {
    try {
      rmSync(stagingDir, { recursive: true, force: true });
    } catch (cleanupError) {
      // Never replace the primary release-preparation failure with a cleanup
      // failure. A leftover private staging folder is NOT a valid release.
      process.stderr.write('WARNING: private OTA staging cleanup failed; inspect manually: ' +
        stagingDir + ' (' + String(cleanupError?.code || 'unknown error') + ')\n');
    }
  }
}
process.stdout.write(
  'OWNER-REVIEW RELEASE FOLDER ONLY. NOT UPLOADED OR INSTALLED.\n' +
  'Output: ' + outDir + '\nVersion: ' + handoff.versionCode +
  '\nAPK SHA-256: ' + apkSha + '\nPublic manifest key SHA-256: ' +
  createHash('sha256').update(publicDer).digest('hex') +
  '\nPublish only after real on-TV tests, independent review, and explicit approval.\n'
);
}

const isMain =
  Boolean(process.argv[1]) && resolve(fileURLToPath(import.meta.url)) === resolve(process.argv[1]);
if (isMain) {
  runCli();
}
