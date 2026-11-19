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
 *    --out <private-output-dir> --owner-approved-after-tests
 *
 * Requires the distinct owner-offline OTA RSA private key created by script 13,
 * and JARVIS_OTA_RELEASE_PASSPHRASE environment secret. NO uploading or TV.
 */
import { readFileSync, writeFileSync, mkdirSync, copyFileSync, existsSync, constants as fsConstants } from 'node:fs';
import { createPrivateKey, createPublicKey, createHash, sign, constants as cryptoConstants } from 'node:crypto';
import { resolve, join, basename, relative, isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';

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
const needed = ['--apk','--handoff','--manifest-url','--apk-url','--out'];
if (!needed.every(x => fields.has(x)) ||
    fields.size !== needed.length + 1 ||
    !fields.has('--owner-approved-after-tests'))
  throw new Error('Must provide all paths/URLs and explicit --owner-approved-after-tests confirmation.');

function validateUrl(raw, extension) {
  if (raw.length > 480 || /[^\x21-\x7e]/.test(raw)) throw new Error('Non-ASCII or too long URL');
  const url = new URL(raw);
  if (url.protocol !== 'https:' || !url.hostname || url.port ||
      url.username || url.password || url.hash || url.search ||
      !url.pathname.endsWith(extension) || !url.pathname.startsWith('/'))
    throw new Error('Only fixed clean HTTPS URLs with ' + extension + ' are allowed.');
  return url;
}
const manifestUrl = validateUrl(fields.get('--manifest-url'), '.manifest');
const apkUrl = validateUrl(fields.get('--apk-url'), '.apk');
if (manifestUrl.hostname.toLowerCase() !== apkUrl.hostname.toLowerCase())
  throw new Error('Signed APK URL must use the same owner-pinned HTTPS host.');
const manifestFile = basename(manifestUrl.pathname);
const apkFile = basename(apkUrl.pathname);
if (!manifestFile || !apkFile) throw new Error('Release URLs lack filenames');

const repoRoot = resolve(fileURLToPath(new URL('..', import.meta.url)));
const outDir = resolve(fields.get('--out'));
const outsideRepo = relative(repoRoot, outDir);
if (outsideRepo === '' || (!outsideRepo.startsWith('..') && !isAbsolute(outsideRepo)))
  throw new Error('Do not prepare public-release artifacts inside the source repository.');
if (existsSync(outDir)) throw new Error('Output folder already exists; never overwrite an existing release.');
const apkPath = resolve(fields.get('--apk'));
const handoff = JSON.parse(readFileSync(resolve(fields.get('--handoff')), 'utf8'));
const signer = '21c2c41dc4c34576cca14ad5404e87d1c5a07ace961c0fab96d128c2164a51ed';
if (handoff.packageName !== 'it.akai.customremote' ||
    handoff.buildProfile !== 'Release' || handoff.debuggable !== false ||
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

mkdirSync(outDir, { recursive: false, mode: 0o700 });
writeFileSync(join(outDir, manifestFile), manifestBytes, { flag: 'wx' });
writeFileSync(join(outDir, manifestFile + '.sig'), signature, { flag: 'wx' });
copyFileSync(apkPath, join(outDir, apkFile), fsConstants.COPYFILE_EXCL);
process.stdout.write(
  'OWNER-REVIEW RELEASE FOLDER ONLY. NOT UPLOADED OR INSTALLED.\n' +
  'Output: ' + outDir + '\nVersion: ' + handoff.versionCode +
  '\nAPK SHA-256: ' + apkSha + '\nPublic manifest key SHA-256: ' +
  createHash('sha256').update(publicDer).digest('hex') +
  '\nPublish only after real on-TV tests, independent review, and explicit approval.\n'
);
