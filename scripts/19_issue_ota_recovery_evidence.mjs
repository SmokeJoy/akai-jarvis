#!/usr/bin/env node
/*
 * Owner PC only, offline, zero dependencies.
 * Issues or physically verifies a signed jarvis-ota-evidence-v2 backup/recovery
 * receipt against a REAL encrypted portable recovery bundle (via script 16
 * verify-restore-offline) and the real A2 Rescue APK on disk.
 *
 * Usage:
 *  node scripts/19_issue_ota_recovery_evidence.mjs --mode issue \
 *    --profile <staging|release> --device-uid <android_id> \
 *    --installed-version <int> --candidate-version <int> \
 *    --prior-rescue-version <int> --recovery-rescue-version <int> \
 *    --backup-id <id> --bundle <recovery_bundle.akv.json> \
 *    --rescue-apk <a2-rescue.apk> --out <private-output-dir> \
 *    --owner-approved-after-tests
 *
 *  node scripts/19_issue_ota_recovery_evidence.mjs --mode verify-with-archive \
 *    --receipt <ota-recovery-evidence.receipt> --sig <ota-recovery-evidence.receipt.sig> \
 *    --pubkey <ota-release-public.der> --bundle <recovery_bundle.akv.json> \
 *    --rescue-apk <a2-rescue.apk> --device-uid <android_id> \
 *    --installed-version <int> --candidate-version <int>
 *
 * Offline production signing refuses process.env.CI / GITHUB_ACTIONS and never
 * writes artifacts inside the repository or uploads backups/keys.
 */
import { createPrivateKey, createPublicKey } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, realpathSync } from 'node:fs';
import { basename, dirname, isAbsolute, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  issueArchiveVerifiedReceipt,
  verifyReceiptWithRealArchives,
} from './lib/ota_recovery_evidence.mjs';

function assertOutsideRepo(repoRoot, targetPath) {
  const physicalRepo = realpathSync(repoRoot);
  const resolved = resolve(targetPath);
  const parent = dirname(resolved);
  const physicalParent = existsSync(parent) ? realpathSync(parent) : parent;
  const physicalTarget = resolve(physicalParent, basename(resolved));
  const rel = relative(physicalRepo, physicalTarget);
  if (
    rel === '' ||
    (!rel.startsWith('..' + (process.platform === 'win32' ? '\\' : '/')) &&
      rel !== '..' &&
      !isAbsolute(rel))
  ) {
    throw new Error('EVIDENCE_OUTSIDE_REPO_REQUIRED');
  }
}

function decryptOwnerPrivateKey(trustDir, profile, passphrase) {
  const privName =
    profile === 'release'
      ? 'ota-release-private.encrypted.pem'
      : 'ota-staging-private.encrypted.pem';
  const pubName =
    profile === 'release'
      ? 'ota-release-public.der'
      : 'ota-staging-public.der';
  const encPath = join(trustDir, privName);
  const pubPath = join(trustDir, pubName);
  if (!existsSync(encPath) || !existsSync(pubPath)) {
    throw new Error('OWNER_TRUST_STORE_INCOMPLETE');
  }
  const pemBuf = readFileSync(encPath);
  try {
    const privateKey = createPrivateKey({
      key: pemBuf,
      format: 'pem',
      passphrase,
    });
    const pubDer = readFileSync(pubPath);
    createPublicKey({ key: pubDer, format: 'der', type: 'spki' });
    return { privateKey, pubDer };
  } finally {
    pemBuf.fill(0);
  }
}

function parseArgs(argv) {
  const map = new Map();
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--owner-approved-after-tests') {
      map.set(argv[i], 'true');
      continue;
    }
    if (!argv[i].startsWith('--') || !argv[i + 1] || argv[i + 1].startsWith('--')) {
      throw new Error('INVALID_CLI_ARGUMENT_' + argv[i]);
    }
    if (map.has(argv[i])) throw new Error('DUPLICATE_CLI_ARGUMENT_' + argv[i]);
    map.set(argv[i], argv[++i]);
  }
  return map;
}

function runCli() {
  if (
    process.platform !== 'win32' ||
    !process.env.LOCALAPPDATA ||
    process.env.CI ||
    process.env.GITHUB_ACTIONS
  ) {
    throw new Error('Offline recovery evidence issuer requires owner Windows PC, never CI.');
  }

  const repoRoot = resolve(fileURLToPath(new URL('..', import.meta.url)));
  const args = parseArgs(process.argv.slice(2));
  const mode = args.get('--mode');

  if (mode === 'verify-with-archive') {
    const req = [
      '--receipt',
      '--sig',
      '--pubkey',
      '--bundle',
      '--rescue-apk',
      '--device-uid',
      '--installed-version',
      '--candidate-version',
    ];
    for (const k of req) {
      if (!args.has(k)) throw new Error('MISSING_ARG_' + k);
    }
    const verdict = verifyReceiptWithRealArchives({
      receiptPath: resolve(args.get('--receipt')),
      sigPath: resolve(args.get('--sig')),
      publicKeyDerPath: resolve(args.get('--pubkey')),
      bundlePath: resolve(args.get('--bundle')),
      rescueApkPath: resolve(args.get('--rescue-apk')),
      deviceUid: args.get('--device-uid'),
      installedVersionCode: Number(args.get('--installed-version')),
      candidateVersionCode: Number(args.get('--candidate-version')),
      nowEpochSec: Math.floor(Date.now() / 1000),
    });
    console.log(JSON.stringify(verdict, null, 2));
    return;
  }

  if (mode !== 'issue') {
    throw new Error('UNSUPPORTED_MODE_' + mode);
  }

  const needed = [
    '--profile',
    '--device-uid',
    '--installed-version',
    '--candidate-version',
    '--prior-rescue-version',
    '--recovery-rescue-version',
    '--backup-id',
    '--bundle',
    '--rescue-apk',
    '--out',
    '--owner-approved-after-tests',
  ];
  for (const k of needed) {
    if (!args.has(k)) throw new Error('MISSING_ARG_' + k);
  }

  const profile = args.get('--profile');
  if (profile !== 'staging' && profile !== 'release') {
    throw new Error('INVALID_PROFILE_' + profile);
  }
  const trustRootName =
    profile === 'release' ? 'AkaiJarvisOtaReleaseTrust' : 'AkaiJarvisOtaStagingTrust';
  const keyPassEnv =
    profile === 'release' ? process.env.JARVIS_OTA_RELEASE_PASSPHRASE : process.env.JARVIS_OTA_STAGING_PASSPHRASE;
  const bundlePass = process.env.JARVIS_RECOVERY_PASSPHRASE || '';
  if (!keyPassEnv || keyPassEnv.length < 20) {
    throw new Error('MISSING_OWNER_KEY_PASSPHRASE');
  }
  if (!bundlePass || bundlePass.length < 20) {
    throw new Error('MISSING_RECOVERY_BUNDLE_PASSPHRASE');
  }

  const outDir = resolve(args.get('--out'));
  assertOutsideRepo(repoRoot, outDir);
  mkdirSync(outDir, { recursive: true });

  const trustDir = join(process.env.LOCALAPPDATA, trustRootName);
  const { privateKey, pubDer } = decryptOwnerPrivateKey(trustDir, profile, keyPassEnv);
  const nowSec = Math.floor(Date.now() / 1000);
  const issued = issueArchiveVerifiedReceipt({
    repoRoot,
    channelProfile: profile,
    deviceUid: args.get('--device-uid'),
    installedVersionCode: Number(args.get('--installed-version')),
    candidateVersionCode: Number(args.get('--candidate-version')),
    priorRescueFloorVersionCode: Number(args.get('--prior-rescue-version')),
    recoveryRescueVersionCode: Number(args.get('--recovery-rescue-version')),
    backupId: args.get('--backup-id'),
    bundlePath: resolve(args.get('--bundle')),
    rescueApkPath: resolve(args.get('--rescue-apk')),
    bundlePassphrase: bundlePass,
    privateKeyPemOrKeyObject: privateKey,
    publicKeyDerBuf: pubDer,
    outReceiptPath: join(outDir, 'ota-recovery-evidence.receipt'),
    outSigPath: join(outDir, 'ota-recovery-evidence.receipt.sig'),
    nowEpochSec: nowSec,
  });
  console.log(JSON.stringify(issued, null, 2));
}

if (resolve(fileURLToPath(import.meta.url)) === resolve(process.argv[1] || '')) {
  runCli();
}
