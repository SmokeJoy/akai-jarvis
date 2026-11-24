#!/usr/bin/env node
// Isolated OTA staging channel & monotonic version plan regression suite.
// Uses ephemeral in-memory RSA-3072 keys and synthetic APK metadata only.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  EXPECTED_SIGNER_SHA256,
  auditDiagnosticStagingApkOutputs,
  buildStagingManifestText,
  validateHttpsStagingUrl,
  validateMonotonicVersionPlan,
} from '../scripts/18_prepare_ota_staging.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '..');

function resolveJdkTool(toolBase) {
  const ext = process.platform === 'win32' ? '.exe' : '';
  const localTool = path.join(repoRoot, 'tools', 'jdk-17', 'bin', toolBase + ext);
  if (fs.existsSync(localTool)) return localTool;
  if (process.env.JAVA_HOME) {
    const jhTool = path.join(process.env.JAVA_HOME, 'bin', toolBase + ext);
    if (fs.existsSync(jhTool)) return jhTool;
  }
  return toolBase;
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
    lfh.writeUInt32LE(sum, 14);
    lfh.writeUInt32LE(dataBuf.length, 18);
    lfh.writeUInt32LE(dataBuf.length, 22);
    lfh.writeUInt16LE(nameBuf.length, 26);
    localParts.push(lfh, nameBuf, dataBuf);

    const cdh = Buffer.alloc(46);
    cdh.writeUInt32LE(0x02014b50, 0);
    cdh.writeUInt16LE(20, 4);
    cdh.writeUInt16LE(20, 6);
    cdh.writeUInt32LE(sum, 16);
    cdh.writeUInt32LE(dataBuf.length, 20);
    cdh.writeUInt32LE(dataBuf.length, 24);
    cdh.writeUInt16LE(nameBuf.length, 28);
    cdh.writeUInt32LE(offset, 42);
    centralParts.push(cdh, nameBuf);

    offset += lfh.length + nameBuf.length + dataBuf.length;
  }
  const cdBuf = Buffer.concat(centralParts);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(entries.length, 8);
  eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(cdBuf.length, 12);
  eocd.writeUInt32LE(offset, 16);
  fs.writeFileSync(outPath, Buffer.concat([...localParts, cdBuf, eocd]));
}

let testCount = 0;

// 1. Monotonic 7-step version ordering (includes higher rescue recovery step for staging)
const validPlan = {
  installedA2: 3,
  v4Diagnostic: 4,
  a2Rescue: 5,
  otaStageBase: 6,
  otaStageTarget: 7,
  a2RescueForStaging: 8,
  v5Release: 9,
};
assert.equal(validateMonotonicVersionPlan(validPlan).ok, true);
testCount++;

for (const [label, bad] of [
  ['collision', { ...validPlan, otaStageBase: 5 }],
  ['inversion', { ...validPlan, v4Diagnostic: 6, a2Rescue: 5 }],
  ['rescueForStaging<=stageTarget', { ...validPlan, a2RescueForStaging: 7 }],
  ['v5<=rescueForStaging', { ...validPlan, v5Release: 8 }],
  ['zero', { ...validPlan, installedA2: 0 }],
  ['non-integer', { ...validPlan, otaStageTarget: 7.5 }],
  ['string', { ...validPlan, v5Release: '9' }],
]) {
  assert.throws(
    () => validateMonotonicVersionPlan(bad),
    /OTA_VERSION_PLAN_REJECTED_/,
    'plan rejection: ' + label
  );
  testCount++;
}

// 2. Staging APK audit cases
const stagingFixture = {
  handoff: {
    packageName: 'it.akai.customremote',
    buildProfile: 'Diagnostic',
    versionCode: 7,
    versionName: '1.3.0-diagnostic-ota-stage-v7',
  },
  signerReport:
    'Verifies\nVerified using v1 scheme (JAR signing): true\n' +
    'Verified using v2 scheme (APK Signature Scheme v2): true\n' +
    'Number of signers: 1\nSigner #1 certificate SHA-256 digest: ' +
    EXPECTED_SIGNER_SHA256 +
    '\n',
  badging:
    "package: name='it.akai.customremote' versionCode='7' versionName='1.3.0-diagnostic-ota-stage-v7'\n" +
    "sdkVersion:'21'\ntargetSdkVersion:'28'\nnative-code: 'armeabi-v7a'\n",
  manifestXml:
    'E: manifest\n  E: application\n    A: android:debuggable(0x0101000f)=(type 0x12)0xffffffff\n',
};

const audited = auditDiagnosticStagingApkOutputs(stagingFixture);
assert.equal(audited.verified, true);
assert.equal(audited.debuggable, true);
assert.equal(audited.stagingOnly, true);
testCount++;

const wrongCert = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
for (const [label, bad] of [
  ['non-debuggable 0x0 rejected', { ...stagingFixture, manifestXml: stagingFixture.manifestXml.replace('0xffffffff', '0x0') }],
  ['missing debuggable attr', { ...stagingFixture, manifestXml: 'E: manifest\n  E: application\n' }],
  ['wrong signer', { ...stagingFixture, signerReport: stagingFixture.signerReport.replace(EXPECTED_SIGNER_SHA256, wrongCert) }],
  ['multi signer', { ...stagingFixture, signerReport: stagingFixture.signerReport.replace('Number of signers: 1', 'Number of signers: 2') }],
  ['v2 unverified', { ...stagingFixture, signerReport: stagingFixture.signerReport.replace('Scheme v2): true', 'Scheme v2): false') }],
  ['versionCode < 6', {
    ...stagingFixture,
    handoff: { ...stagingFixture.handoff, versionCode: 5 },
    badging: stagingFixture.badging.replace("versionCode='7'", "versionCode='5'"),
  }],
  ['missing ota-stage tag', {
    ...stagingFixture,
    handoff: { ...stagingFixture.handoff, versionName: '1.3.0-diagnostic-rc1' },
    badging: stagingFixture.badging.replace('1.3.0-diagnostic-ota-stage-v7', '1.3.0-diagnostic-rc1'),
  }],
  ['release buildProfile rejected', { ...stagingFixture, handoff: { ...stagingFixture.handoff, buildProfile: 'Release' } }],
  ['wrong ABI', { ...stagingFixture, badging: stagingFixture.badging.replace("'armeabi-v7a'", "'arm64-v8a'") }],
  ['wrong targetSdk', { ...stagingFixture, badging: stagingFixture.badging.replace("targetSdkVersion:'28'", "targetSdkVersion:'29'") }],
]) {
  assert.throws(() => auditDiagnosticStagingApkOutputs(bad), /STAGING_APK_REJECTED_/, label);
  testCount++;
}

// 3. URL & manifest text guards (public/DNS HTTPS only; no localhost, .local, .lan, or IP literals)
assert.throws(() => validateHttpsStagingUrl('http://staging.example/a.manifest', '.manifest'), /STAGING_URL_REJECTED_/);
assert.throws(() => validateHttpsStagingUrl('https://staging.example:8443/a.manifest', '.manifest'), /STAGING_URL_REJECTED_/);
assert.throws(() => validateHttpsStagingUrl('https://staging.example/a.manifest?x=1', '.manifest'), /STAGING_URL_REJECTED_/);
assert.throws(() => validateHttpsStagingUrl('https://staging.example/a.txt', '.manifest'), /STAGING_URL_REJECTED_/);
for (const badHost of [
  'https://localhost/a.manifest',
  'https://127.0.0.1/a.manifest',
  'https://192.168.1.50/a.manifest',
  'https://[::1]/a.manifest',
  'https://jarvis.local/a.manifest',
  'https://router.lan/a.manifest',
  'https://.staging.example/a.manifest',
  'https://staging..example/a.manifest',
]) {
  assert.throws(() => validateHttpsStagingUrl(badHost, '.manifest'), /STAGING_URL_REJECTED_/, badHost);
}
for (const badTraversal of [
  'https://staging.example/releases/../a.manifest',
  'https://staging.example/releases/%2e%2e/a.manifest',
  'https://staging.example/releases\\a.manifest',
  'https://staging.example/releases//a.manifest',
]) {
  assert.throws(() => validateHttpsStagingUrl(badTraversal, '.manifest'), /STAGING_URL_REJECTED_/, badTraversal);
}
testCount += 16;

// 4. Java OtaSignedReleaseManifest + OtaCandidateGate E2E using ephemeral in-memory staging RSA-3072 keys
const workDir = fs.mkdtempSync(path.join(os.tmpdir(), 'akai_ota_staging_test_'));
try {
  const { publicKey: stagingPubDer, privateKey: stagingPrivPem } = crypto.generateKeyPairSync('rsa', {
    modulusLength: 3072,
    publicKeyEncoding: { type: 'spki', format: 'der' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  });
  const { publicKey: wrongPubDer } = crypto.generateKeyPairSync('rsa', {
    modulusLength: 3072,
    publicKeyEncoding: { type: 'spki', format: 'der' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  });

  const channelUrl = 'https://staging-ota.akai-jarvis.example/staging/jarvis-stage.manifest';
  const apkUrl = 'https://staging-ota.akai-jarvis.example/staging/jarvis-v7-ota-stage.apk';
  const syntheticApkBytes = Buffer.from('SYNTHETIC_STAGING_APK_PAYLOAD_' + 'a'.repeat(2048), 'utf8');
  const apkSha = crypto.createHash('sha256').update(syntheticApkBytes).digest('hex');

  const provStagingApk = path.join(workDir, 'staging-base-v6.apk');
  writeStoredZip(provStagingApk, [
    ['AndroidManifest.xml', Buffer.from('DUMMY')],
    ['classes.dex', Buffer.from('DUMMY')],
    ['assets/ota-release-public.der', stagingPubDer],
    ['assets/ota-release-channel.txt', Buffer.from(channelUrl + '\n', 'utf8')],
  ]);

  const wrongKeyApk = path.join(workDir, 'staging-wrongkey-v6.apk');
  writeStoredZip(wrongKeyApk, [
    ['AndroidManifest.xml', Buffer.from('DUMMY')],
    ['classes.dex', Buffer.from('DUMMY')],
    ['assets/ota-release-public.der', wrongPubDer],
    ['assets/ota-release-channel.txt', Buffer.from(channelUrl + '\n', 'utf8')],
  ]);

  const makeSigned = (versionCode) => {
    const text = buildStagingManifestText({
      versionCode,
      apkSha256: apkSha,
      apkUrl,
      sizeBytes: syntheticApkBytes.length,
    });
    const buf = Buffer.from(text, 'ascii');
    const sig = crypto.sign('RSA-SHA256', buf, {
      key: stagingPrivPem,
      padding: crypto.constants.RSA_PKCS1_PADDING,
    });
    return { buf, sig };
  };

  const validV7 = makeSigned(7);
  const tamperedV7 = Buffer.from(validV7.buf);
  const idx = tamperedV7.indexOf('versionCode=7');
  tamperedV7[idx + 'versionCode='.length] = '8'.charCodeAt(0);
  const equalV6 = makeSigned(6);
  const downgradeV5Text = validV7.buf.toString('ascii').replace('versionCode=7', 'versionCode=5');
  const downgradeV5Buf = Buffer.from(downgradeV5Text, 'ascii');
  const downgradeV5Sig = crypto.sign('RSA-SHA256', downgradeV5Buf, {
    key: stagingPrivPem,
    padding: crypto.constants.RSA_PKCS1_PADDING,
  });

  const paths = {
    v7Man: path.join(workDir, 'v7.manifest'),
    v7Sig: path.join(workDir, 'v7.manifest.sig'),
    tamMan: path.join(workDir, 'tampered.manifest'),
    eqMan: path.join(workDir, 'v6.manifest'),
    eqSig: path.join(workDir, 'v6.manifest.sig'),
    dwMan: path.join(workDir, 'v5.manifest'),
    dwSig: path.join(workDir, 'v5.manifest.sig'),
  };
  fs.writeFileSync(paths.v7Man, validV7.buf);
  fs.writeFileSync(paths.v7Sig, validV7.sig);
  fs.writeFileSync(paths.tamMan, tamperedV7);
  fs.writeFileSync(paths.eqMan, equalV6.buf);
  fs.writeFileSync(paths.eqSig, equalV6.sig);
  fs.writeFileSync(paths.dwMan, downgradeV5Buf);
  fs.writeFileSync(paths.dwSig, downgradeV5Sig);

  const mockSrc = path.join(workDir, 'mock_java');
  const binDir = path.join(workDir, 'bin');
  fs.mkdirSync(path.join(mockSrc, 'android', 'content', 'res'), { recursive: true });
  fs.mkdirSync(path.join(mockSrc, 'it', 'akai', 'customremote'), { recursive: true });
  fs.mkdirSync(binDir, { recursive: true });

  fs.writeFileSync(
    path.join(mockSrc, 'android', 'content', 'res', 'AssetManager.java'),
    `
package android.content.res;
import java.io.*;
import java.util.zip.*;
public class AssetManager {
    private final String apkPath;
    public AssetManager(String apkPath) { this.apkPath = apkPath; }
    public InputStream open(String fileName) throws IOException {
        final ZipFile zf = new ZipFile(apkPath);
        ZipEntry entry = zf.getEntry("assets/" + fileName);
        if (entry == null) { zf.close(); throw new FileNotFoundException(fileName); }
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        try (InputStream is = zf.getInputStream(entry)) {
            byte[] buf = new byte[4096]; int r;
            while ((r = is.read(buf)) != -1) baos.write(buf, 0, r);
        } finally { zf.close(); }
        return new ByteArrayInputStream(baos.toByteArray());
    }
}
`
  );
  fs.writeFileSync(
    path.join(mockSrc, 'android', 'content', 'Context.java'),
    `
package android.content;
import android.content.res.AssetManager;
public class Context {
    private final AssetManager assets;
    public Context(String apkPath) { this.assets = new AssetManager(apkPath); }
    public AssetManager getAssets() { return assets; }
}
`
  );
  fs.writeFileSync(
    path.join(mockSrc, 'it', 'akai', 'customremote', 'OtaStagingChannelE2ERunner.java'),
    `
package it.akai.customremote;

import android.content.Context;
import it.akai.customremote.ai.OtaCandidateGate;
import it.akai.customremote.ai.OtaReleaseChannel;
import it.akai.customremote.ai.OtaReleaseTrust;
import it.akai.customremote.ai.OtaSignedReleaseManifest;
import java.io.*;
import java.security.PublicKey;

public class OtaStagingChannelE2ERunner {
    private static byte[] readAll(String path) throws IOException {
        try (FileInputStream fis = new FileInputStream(path)) {
            ByteArrayOutputStream baos = new ByteArrayOutputStream();
            byte[] buf = new byte[4096]; int r;
            while ((r = fis.read(buf)) != -1) baos.write(buf, 0, r);
            return baos.toByteArray();
        }
    }
    private static void check(boolean cond, String msg) {
        if (!cond) throw new AssertionError("STAGING_JAVA_FAIL: " + msg);
    }
    public static void main(String[] args) throws Exception {
        Context provCtx = new Context(args[0]);
        Context wrongCtx = new Context(args[1]);
        String signer = args[2];
        byte[] v7Man = readAll(args[3]);
        byte[] v7Sig = readAll(args[4]);
        byte[] tamMan = readAll(args[5]);
        byte[] eqMan = readAll(args[6]);
        byte[] eqSig = readAll(args[7]);
        byte[] dwMan = readAll(args[8]);
        byte[] dwSig = readAll(args[9]);

        PublicKey stagingKey = OtaReleaseTrust.readBundledPublicKey(provCtx);
        PublicKey wrongKey = OtaReleaseTrust.readBundledPublicKey(wrongCtx);
        OtaReleaseChannel.Channel ch = OtaReleaseChannel.loadBundled(provCtx);
        check(stagingKey != null && wrongKey != null && ch != null, "Keys/channel must load");
        check(OtaCandidateGate.EXPECTED_SIGNER_SHA256.equalsIgnoreCase(signer), "Pinned signer match");

        OtaSignedReleaseManifest.Result ok = OtaSignedReleaseManifest.verify(v7Man, v7Sig, stagingKey, 6, signer, ch.trustedHosts);
        check(ok.verified() && ok.candidate.versionCode == 7, "v7 staging over v6 must verify");

        OtaSignedReleaseManifest.Result tam = OtaSignedReleaseManifest.verify(tamMan, v7Sig, stagingKey, 6, signer, ch.trustedHosts);
        check(!tam.verified(), "Tampered manifest must be rejected");

        OtaSignedReleaseManifest.Result wk = OtaSignedReleaseManifest.verify(v7Man, v7Sig, wrongKey, 6, signer, ch.trustedHosts);
        check(!wk.verified(), "Wrong RSA public key must be rejected");

        OtaSignedReleaseManifest.Result eq = OtaSignedReleaseManifest.verify(eqMan, eqSig, stagingKey, 6, signer, ch.trustedHosts);
        check(!eq.verified(), "Equal versionCode v6 -> v6 must be rejected by gate");

        OtaSignedReleaseManifest.Result dw = OtaSignedReleaseManifest.verify(dwMan, dwSig, stagingKey, 6, signer, ch.trustedHosts);
        check(!dw.verified(), "Downgrade v6 -> v5 must be rejected by gate");

        System.out.println("JAVA_STAGING_OTA_PASS");
    }
}
`
  );

  const javaSources = [
    path.join(mockSrc, 'android', 'content', 'res', 'AssetManager.java'),
    path.join(mockSrc, 'android', 'content', 'Context.java'),
    path.join(repoRoot, 'akai-remote-tv', 'app', 'src', 'main', 'java', 'it', 'akai', 'customremote', 'ai', 'OtaPinnedReleaseKey.java'),
    path.join(repoRoot, 'akai-remote-tv', 'app', 'src', 'main', 'java', 'it', 'akai', 'customremote', 'ai', 'OtaCandidateGate.java'),
    path.join(repoRoot, 'akai-remote-tv', 'app', 'src', 'main', 'java', 'it', 'akai', 'customremote', 'ai', 'OtaStagingCommit.java'),
    path.join(repoRoot, 'akai-remote-tv', 'app', 'src', 'main', 'java', 'it', 'akai', 'customremote', 'ai', 'OtaHttpsTransport.java'),
    path.join(repoRoot, 'akai-remote-tv', 'app', 'src', 'main', 'java', 'it', 'akai', 'customremote', 'ai', 'OtaSignedReleaseManifest.java'),
    path.join(repoRoot, 'akai-remote-tv', 'app', 'src', 'main', 'java', 'it', 'akai', 'customremote', 'ai', 'OtaReleaseTrust.java'),
    path.join(repoRoot, 'akai-remote-tv', 'app', 'src', 'main', 'java', 'it', 'akai', 'customremote', 'ai', 'OtaReleaseChannel.java'),
    path.join(mockSrc, 'it', 'akai', 'customremote', 'OtaStagingChannelE2ERunner.java'),
  ];

  execFileSync(resolveJdkTool('javac'), ['-encoding', 'UTF-8', '-source', '8', '-target', '8', '-d', binDir, ...javaSources], {
    stdio: 'inherit',
  });
  const javaOut = execFileSync(
    resolveJdkTool('java'),
    [
      '-cp',
      binDir,
      'it.akai.customremote.OtaStagingChannelE2ERunner',
      provStagingApk,
      wrongKeyApk,
      EXPECTED_SIGNER_SHA256,
      paths.v7Man,
      paths.v7Sig,
      paths.tamMan,
      paths.eqMan,
      paths.eqSig,
      paths.dwMan,
      paths.dwSig,
    ],
    { encoding: 'utf8' }
  );
  assert.ok(javaOut.includes('JAVA_STAGING_OTA_PASS'), 'Unexpected Java staging output: ' + javaOut);
  testCount++;
} finally {
  fs.rmSync(workDir, { recursive: true, force: true });
}

console.log('test_ota_staging_channel PASS: ' + testCount + ' checks (monotonic plan + staging APK audit + Java E2E with ephemeral RSA-3072 keys)');
