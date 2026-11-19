#!/usr/bin/env node
/*
 * Owner-only offline preparation. Node.js 20+, NO dependencies.
 * Generates a DISTINCT, password-encrypted RSA release-manifest signing key
 * outside the public Git repo and exports ONLY its public SPKI for the TV.
 *
 * NEVER upload the encrypted private PEM, password, TV signing keystore or
 * personal TLS identity to GitHub. This is not the Android APK signing key.
 * Does NOT install anything, call GitHub, or contact the TV.
 */
import { generateKeyPairSync, createHash } from 'node:crypto';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { resolve, join, relative, isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = resolve(fileURLToPath(new URL('..', import.meta.url)));
const localAppData = process.env.LOCALAPPDATA;
const password = process.env.JARVIS_OTA_RELEASE_PASSPHRASE;
if (process.platform !== 'win32' || !localAppData) {
  throw new Error('This owner-only release trust setup requires Windows LOCALAPPDATA.');
}
if (process.env.CI || process.env.GITHUB_ACTIONS) {
  throw new Error('Never generate a release private key inside CI.');
}
if (!password || password.length < 20 || password.length > 1024) {
  throw new Error('Set a unique passphrase (at least 20 characters) in JARVIS_OTA_RELEASE_PASSPHRASE in your private PowerShell environment; never share it.');
}

const privateDir = resolve(localAppData, 'AkaiJarvisOtaReleaseTrust');
const insideRepo = relative(repoRoot, privateDir);
if (insideRepo === '' || (!insideRepo.startsWith('..') && !isAbsolute(insideRepo))) {
  throw new Error('The private key must never be generated inside the public repo.');
}
mkdirSync(privateDir, { recursive: true, mode: 0o700 });
const keyPath = join(privateDir, 'ota-release-private.encrypted.pem');
const pubPath = join(privateDir, 'ota-release-public.der');
if (existsSync(keyPath) || existsSync(pubPath)) {
  throw new Error('OTA trust already exists or is incomplete. Never rotate/overwrite keys automatically. Perform an owner-reviewed recovery instead.');
}
const { publicKey, privateKey } = generateKeyPairSync('rsa', {
  modulusLength: 3072,
  publicExponent: 0x10001,
  publicKeyEncoding: { type: 'spki', format: 'der' },
  privateKeyEncoding: {
    type: 'pkcs8', format: 'pem', cipher: 'aes-256-cbc', passphrase: password,
  },
});
if (publicKey.length < 200 || publicKey.length > 1024) {
  throw new Error('Unusable RSA public key length');
}
writeFileSync(keyPath, privateKey, { mode: 0o600, flag: 'wx' });
writeFileSync(pubPath, publicKey, { mode: 0o600, flag: 'wx' });
const fp = createHash('sha256').update(publicKey).digest('hex');
process.stdout.write(
  'OFFLINE KEY CREATED (never on GitHub, never installed on TV)\n' +
  'Encrypted manifest signing private key: ' + keyPath + '\n' +
  'PUBLIC key for owner-signed APK build: ' + pubPath + '\n' +
  'Public DER SHA-256: ' + fp + '\n' +
  'Keep JARVIS_OTA_RELEASE_PASSPHRASE private and backed up securely.\n'
);
