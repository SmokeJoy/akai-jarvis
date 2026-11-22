#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

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
  if (process.platform === 'win32') return 'powershell';
  return 'pwsh';
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
    lfh.writeUInt16LE(0, 8); // store
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
  const cdBuf = Buffer.concat(centralParts);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(0, 4);
  eocd.writeUInt16LE(0, 6);
  eocd.writeUInt16LE(entries.length, 8);
  eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(cdBuf.length, 12);
  eocd.writeUInt32LE(offset, 16);
  eocd.writeUInt16LE(0, 20);
  fs.writeFileSync(outPath, Buffer.concat([...localParts, cdBuf, eocd]));
}

const workDir = fs.mkdtempSync(path.join(os.tmpdir(), 'akai_ota_e2e_'));

try {
  // 1. Genera trust keypair effimera RSA-3072 in dir temporanea (mai LOCALAPPDATA reale)
  const { publicKey: pubDer, privateKey: privKeyPem } = crypto.generateKeyPairSync('rsa', {
    modulusLength: 3072,
    publicKeyEncoding: { type: 'spki', format: 'der' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' }
  });
  const pubDerPath = path.join(workDir, 'ota-release-public.der');
  fs.writeFileSync(pubDerPath, pubDer);
  const pubSha = crypto.createHash('sha256').update(pubDer).digest('hex');

  const manifestUrl = 'https://updates.akai-jarvis.example/releases/jarvis-v6.manifest';
  const apkUrlV6 = 'https://updates.akai-jarvis.example/releases/jarvis-v6.apk';
  const signerA = '21c2c41dc4c34576cca14ad5404e87d1c5a07ace961c0fab96d128c2164a51ed';
  const signerB = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const apkPayload = Buffer.from('DUMMY_SIGNED_V6_APK_ARCHIVE_BYTES_' + 'x'.repeat(2048), 'utf8');
  const apkSha = crypto.createHash('sha256').update(apkPayload).digest('hex');

  const provisionedApk = path.join(workDir, 'provisioned-v5-rescue.apk');
  writeStoredZip(provisionedApk, [
    ['AndroidManifest.xml', Buffer.from('DUMMY_MANIFEST')],
    ['classes.dex', Buffer.from('DUMMY_DEX')],
    ['assets/ota-release-public.der', pubDer],
    ['assets/ota-release-channel.txt', Buffer.from(manifestUrl + '\n', 'utf8')]
  ]);

  const unprovisionedApk = path.join(workDir, 'unprovisioned-v4.apk');
  writeStoredZip(unprovisionedApk, [
    ['AndroidManifest.xml', Buffer.from('DUMMY_MANIFEST')],
    ['classes.dex', Buffer.from('DUMMY_DEX')]
  ]);

  const badUrlApks = [];
  for (const [idx, badChanUrl] of [
    'https://localhost/releases/jarvis.manifest',
    'https://192.168.1.50/releases/jarvis.manifest',
    'https://akai.local/releases/jarvis.manifest',
    'https://updates.akai-jarvis.example/releases/jarvis.manifest?token=1'
  ].entries()) {
    const p = path.join(workDir, `bad-channel-${idx}.apk`);
    writeStoredZip(p, [
      ['AndroidManifest.xml', Buffer.from('DUMMY_MANIFEST')],
      ['classes.dex', Buffer.from('DUMMY_DEX')],
      ['assets/ota-release-public.der', pubDer],
      ['assets/ota-release-channel.txt', Buffer.from(badChanUrl + '\n', 'utf8')]
    ]);
    badUrlApks.push(p);
  }

  const crlfChannelApk = path.join(workDir, 'crlf-channel-v5.apk');
  writeStoredZip(crlfChannelApk, [
    ['AndroidManifest.xml', Buffer.from('DUMMY_MANIFEST')],
    ['classes.dex', Buffer.from('DUMMY_DEX')],
    ['assets/ota-release-public.der', pubDer],
    ['assets/ota-release-channel.txt', Buffer.from(manifestUrl + '\r\n', 'utf8')]
  ]);

  const oversizedDer = Buffer.alloc(1500, 0xaa);
  oversizedDer[0] = 0x30;
  const oversizedDerApk = path.join(workDir, 'oversized-der-v5.apk');
  writeStoredZip(oversizedDerApk, [
    ['AndroidManifest.xml', Buffer.from('DUMMY_MANIFEST')],
    ['classes.dex', Buffer.from('DUMMY_DEX')],
    ['assets/ota-release-public.der', oversizedDer],
    ['assets/ota-release-channel.txt', Buffer.from(manifestUrl + '\n', 'utf8')]
  ]);

  const makeManifest = ({ versionCode, signerSha256 = signerA, url = apkUrlV6 }) =>
    [
      'format=jarvis-ota-v1',
      'package=it.akai.customremote',
      `versionCode=${versionCode}`,
      `signerSha256=${signerSha256}`,
      `apkSha256=${apkSha}`,
      `url=${url}`,
      'abi=armeabi-v7a',
      'minSdk=21',
      `sizeBytes=${apkPayload.length}`,
      'channel=stable'
    ].join('\n') + '\n';

  const signManifest = (txt) => {
    const manBuf = Buffer.from(txt, 'utf8');
    const sigBuf = crypto.sign('RSA-SHA256', manBuf, privKeyPem);
    return { manBuf, sigBuf };
  };

  const validV6 = signManifest(makeManifest({ versionCode: 6 }));
  const badSigV6 = Buffer.from(validV6.sigBuf);
  badSigV6[0] ^= 0x01;
  const wrongSignerV6 = signManifest(makeManifest({ versionCode: 6, signerSha256: signerB }));
  const untrustedHostV6 = signManifest(makeManifest({ versionCode: 6, url: 'https://untrusted.example/releases/v6.apk' }));
  const insecureHttpV6 = signManifest(makeManifest({ versionCode: 6, url: 'http://updates.akai-jarvis.example/releases/v6.apk' }));
  const downgradeV4 = signManifest(makeManifest({ versionCode: 4 }));

  const filesOut = {
    v6Man: path.join(workDir, 'v6.manifest'),
    v6Sig: path.join(workDir, 'v6.manifest.sig'),
    badSig: path.join(workDir, 'v6_bad.sig'),
    wsMan: path.join(workDir, 'ws.manifest'),
    wsSig: path.join(workDir, 'ws.manifest.sig'),
    uhMan: path.join(workDir, 'uh.manifest'),
    uhSig: path.join(workDir, 'uh.manifest.sig'),
    htMan: path.join(workDir, 'ht.manifest'),
    htSig: path.join(workDir, 'ht.manifest.sig'),
    dv4Man: path.join(workDir, 'dv4.manifest'),
    dv4Sig: path.join(workDir, 'dv4.manifest.sig')
  };
  fs.writeFileSync(filesOut.v6Man, validV6.manBuf);
  fs.writeFileSync(filesOut.v6Sig, validV6.sigBuf);
  fs.writeFileSync(filesOut.badSig, badSigV6);
  fs.writeFileSync(filesOut.wsMan, wrongSignerV6.manBuf);
  fs.writeFileSync(filesOut.wsSig, wrongSignerV6.sigBuf);
  fs.writeFileSync(filesOut.uhMan, untrustedHostV6.manBuf);
  fs.writeFileSync(filesOut.uhSig, untrustedHostV6.sigBuf);
  fs.writeFileSync(filesOut.htMan, insecureHttpV6.manBuf);
  fs.writeFileSync(filesOut.htSig, insecureHttpV6.sigBuf);
  fs.writeFileSync(filesOut.dv4Man, downgradeV4.manBuf);
  fs.writeFileSync(filesOut.dv4Sig, downgradeV4.sigBuf);

  // 2. Compila stub Android Context/AssetManager isolato + sorgenti OTA Java + E2E runner
  const mockSrc = path.join(workDir, 'mock_java');
  const binDir = path.join(workDir, 'bin');
  fs.mkdirSync(path.join(mockSrc, 'android', 'content', 'res'), { recursive: true });
  fs.mkdirSync(path.join(mockSrc, 'it', 'akai', 'customremote'), { recursive: true });
  fs.mkdirSync(binDir, { recursive: true });

  fs.writeFileSync(path.join(mockSrc, 'android', 'content', 'res', 'AssetManager.java'), `
package android.content.res;
import java.io.*;
import java.util.zip.*;
public class AssetManager {
    private final String apkPath;
    public AssetManager(String apkPath) { this.apkPath = apkPath; }
    public InputStream open(String fileName) throws IOException {
        final ZipFile zf = new ZipFile(apkPath);
        ZipEntry entry = zf.getEntry("assets/" + fileName);
        if (entry == null) {
            zf.close();
            throw new FileNotFoundException("Asset missing: " + fileName);
        }
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        try (InputStream is = zf.getInputStream(entry)) {
            byte[] buf = new byte[4096];
            int r;
            while ((r = is.read(buf)) != -1) baos.write(buf, 0, r);
        } finally {
            zf.close();
        }
        return new ByteArrayInputStream(baos.toByteArray());
    }
}
`);

  fs.writeFileSync(path.join(mockSrc, 'android', 'content', 'Context.java'), `
package android.content;
import android.content.res.AssetManager;
public class Context {
    private final AssetManager assets;
    public Context(String apkPath) { this.assets = new AssetManager(apkPath); }
    public AssetManager getAssets() { return assets; }
}
`);

  fs.writeFileSync(path.join(mockSrc, 'it', 'akai', 'customremote', 'OtaProvisioningE2ERunner.java'), `
package it.akai.customremote;

import android.content.Context;
import it.akai.customremote.ai.OtaPinnedReleaseKey;
import it.akai.customremote.ai.OtaReleaseChannel;
import it.akai.customremote.ai.OtaReleaseTrust;
import it.akai.customremote.ai.OtaSignedReleaseManifest;
import java.io.*;
import java.security.PublicKey;

public class OtaProvisioningE2ERunner {
    private static byte[] readAll(String path) throws IOException {
        try (FileInputStream fis = new FileInputStream(path)) {
            ByteArrayOutputStream baos = new ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int r;
            while ((r = fis.read(buf)) != -1) baos.write(buf, 0, r);
            return baos.toByteArray();
        }
    }

    private static void check(boolean cond, String msg) {
        if (!cond) throw new AssertionError("OTA_E2E_FAIL: " + msg);
    }

    public static void main(String[] args) throws Exception {
        String provApk = args[0];
        String unprovApk = args[1];
        String signerA = args[2];
        String v6Man = args[3];
        String v6Sig = args[4];
        String badSig = args[5];
        String wsMan = args[6];
        String wsSig = args[7];
        String uhMan = args[8];
        String uhSig = args[9];
        String htMan = args[10];
        String htSig = args[11];
        String dv4Man = args[12];
        String dv4Sig = args[13];

        Context provCtx = new Context(provApk);
        PublicKey key = OtaReleaseTrust.readBundledPublicKey(provCtx);
        check(key != null, "Provisioned APK must yield non-null bundled PublicKey");
        OtaReleaseChannel.Channel ch = OtaReleaseChannel.loadBundled(provCtx);
        check(ch != null, "Provisioned APK must yield non-null Channel");
        check("https://updates.akai-jarvis.example/releases/jarvis-v6.manifest".equals(ch.manifestUrl), "Unexpected manifestUrl: " + ch.manifestUrl);
        check(ch.trustedHosts.contains("updates.akai-jarvis.example"), "Trusted host missing");

        byte[] man6 = readAll(v6Man);
        byte[] sig6 = readAll(v6Sig);

        OtaSignedReleaseManifest.Result resOverV4 = OtaSignedReleaseManifest.verify(man6, sig6, key, 4, signerA, ch.trustedHosts);
        check(resOverV4.verified(), "v6 over v4 must verify: " + resOverV4.code);

        OtaSignedReleaseManifest.Result resOverRescueV5 = OtaSignedReleaseManifest.verify(man6, sig6, key, 5, signerA, ch.trustedHosts);
        check(resOverRescueV5.verified(), "v6 over A2 rescue v5 must verify: " + resOverRescueV5.code);

        OtaSignedReleaseManifest.Result resBadSig = OtaSignedReleaseManifest.verify(man6, readAll(badSig), key, 4, signerA, ch.trustedHosts);
        check(!resBadSig.verified(), "Tampered signature must be rejected");

        OtaSignedReleaseManifest.Result resWrongSigner = OtaSignedReleaseManifest.verify(readAll(wsMan), readAll(wsSig), key, 4, signerA, ch.trustedHosts);
        check(!resWrongSigner.verified(), "Wrong APK signer SHA-256 must be rejected");

        OtaSignedReleaseManifest.Result resUntrustedHost = OtaSignedReleaseManifest.verify(readAll(uhMan), readAll(uhSig), key, 4, signerA, ch.trustedHosts);
        check(!resUntrustedHost.verified(), "Untrusted host URL must be rejected");

        OtaSignedReleaseManifest.Result resHttp = OtaSignedReleaseManifest.verify(readAll(htMan), readAll(htSig), key, 4, signerA, ch.trustedHosts);
        check(!resHttp.verified(), "Cleartext HTTP APK URL must be rejected");

        OtaSignedReleaseManifest.Result resDowngradeOverRescue = OtaSignedReleaseManifest.verify(readAll(dv4Man), readAll(dv4Sig), key, 5, signerA, ch.trustedHosts);
        check(!resDowngradeOverRescue.verified(), "Downgrade v4 over A2 rescue v5 must be rejected");

        Context unprovCtx = new Context(unprovApk);
        check(OtaReleaseTrust.readBundledPublicKey(unprovCtx) == null, "Unprovisioned APK must return null PublicKey");
        check(OtaReleaseChannel.loadBundled(unprovCtx) == null, "Unprovisioned APK must return null Channel");

        for (int idx = 14; idx < args.length; idx++) {
            Context badChCtx = new Context(args[idx]);
            check(OtaReleaseChannel.loadBundled(badChCtx) == null,
                    "Unsafe OTA channel APK must be rejected by loadBundled: " + args[idx]);
        }

        System.out.println("JAVA_OTA_E2E_PASS");
    }
}
`);

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
    path.join(mockSrc, 'it', 'akai', 'customremote', 'OtaProvisioningE2ERunner.java')
  ];

  const javac = resolveJdkTool('javac');
  const java = resolveJdkTool('java');
  execFileSync(javac, ['-encoding', 'UTF-8', '-source', '8', '-target', '8', '-d', binDir, ...javaSources], { stdio: 'inherit' });
  const javaOut = execFileSync(java, [
    '-cp', binDir,
    'it.akai.customremote.OtaProvisioningE2ERunner',
    provisionedApk, unprovisionedApk, signerA,
    filesOut.v6Man, filesOut.v6Sig, filesOut.badSig,
    filesOut.wsMan, filesOut.wsSig,
    filesOut.uhMan, filesOut.uhSig,
    filesOut.htMan, filesOut.htSig,
    filesOut.dv4Man, filesOut.dv4Sig,
    ...badUrlApks,
    crlfChannelApk
  ], { encoding: 'utf8' });
  if (!javaOut.includes('JAVA_OTA_E2E_PASS')) {
    throw new Error('Unexpected Java runner output: ' + javaOut);
  }

  // 3. Verifica script 17 in modo provisioned vs unprovisioned senza toccare LOCALAPPDATA reale
  const readyBuildManifest = path.join(workDir, 'build_manifest_ready.json');
  fs.writeFileSync(readyBuildManifest, JSON.stringify({
    versionCode: 5,
    otaProvisioned: true,
    otaReleaseManifestUrl: manifestUrl,
    otaReleasePublicKeySha256: pubSha
  }));

  const unprovBuildManifest = path.join(workDir, 'build_manifest_unprov.json');
  fs.writeFileSync(unprovBuildManifest, JSON.stringify({
    versionCode: 4,
    otaProvisioned: false
  }));

  const ps = resolvePowerShell();
  const psExecArgs = process.platform === 'win32' ? ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File'] : ['-NoProfile', '-File'];
  const script17 = path.join(repoRoot, 'scripts', '17_check_ota_provisioning_readiness.ps1');
  const readyOut = execFileSync(ps, [
    ...psExecArgs, script17,
    '-ApkPath', provisionedApk,
    '-BuildManifestPath', readyBuildManifest,
    '-OtaReleasePublicKeyPath', pubDerPath,
    '-OtaReleaseManifestUrl', manifestUrl
  ], { encoding: 'utf8' });
  const readyJson = JSON.parse(readyOut);
  if (readyJson.otaReady !== true || readyJson.nextRecommendedReleaseVersionCode !== 6) {
    throw new Error('Script 17 did not report ready: ' + readyOut);
  }

  let rejectedUnprov = false;
  try {
    execFileSync(ps, [
      ...psExecArgs, script17,
      '-ApkPath', unprovisionedApk,
      '-BuildManifestPath', unprovBuildManifest,
      '-OtaReleasePublicKeyPath', path.join(workDir, 'missing_trust.der')
    ], { encoding: 'utf8', stdio: 'pipe' });
  } catch (err) {
    const out = (err.stdout || '').toString();
    const parsed = JSON.parse(out);
    if (err.status === 1 && parsed.otaReady === false && parsed.reasons.includes('MISSING_OTA_TRUST_PUBLIC_KEY')) {
      rejectedUnprov = true;
    }
  }
  if (!rejectedUnprov) {
    throw new Error('Script 17 failed to reject unprovisioned APK with exit 1');
  }

  // 4. Verifica ChannelProfile Staging + RescueVersionCode=8 => nextRecommendedReleaseVersionCode=9
  const stagingOut = execFileSync(ps, [
    ...psExecArgs, script17,
    '-ApkPath', provisionedApk,
    '-BuildManifestPath', readyBuildManifest,
    '-OtaReleasePublicKeyPath', pubDerPath,
    '-OtaReleaseManifestUrl', manifestUrl,
    '-ChannelProfile', 'Staging',
    '-RescueVersionCode', '8'
  ], { encoding: 'utf8' });
  const stagingJson = JSON.parse(stagingOut);
  if (stagingJson.otaReady !== true || stagingJson.nextRecommendedReleaseVersionCode !== 9) {
    throw new Error('Script 17 did not compute nextRecommendedReleaseVersionCode=9 for RescueVersionCode=8: ' + stagingOut);
  }

  // 5. Verifica rifiuto URL locali/IP privati su Script 17
  for (const badUrl of [
    'https://localhost/releases/jarvis.manifest',
    'https://192.168.50.10/releases/jarvis.manifest',
    'https://akai-tv.local/releases/jarvis.manifest'
  ]) {
    let rejectedBadUrl = false;
    try {
      execFileSync(ps, [
        ...psExecArgs, script17,
        '-OtaReleasePublicKeyPath', pubDerPath,
        '-OtaReleaseManifestUrl', badUrl
      ], { encoding: 'utf8', stdio: 'pipe' });
    } catch (err) {
      const parsedBad = JSON.parse((err.stdout || '').toString());
      if (err.status === 1 && parsedBad.otaReady === false && parsedBad.reasons.includes('INVALID_OTA_MANIFEST_URL_REQUIRES_PUBLIC_HTTPS')) {
        rejectedBadUrl = true;
      }
    }
    if (!rejectedBadUrl) {
      throw new Error('Script 17 failed to reject non-persistent/local OTA URL: ' + badUrl);
    }
  }

  // 6. Verifica Script 17 parita' runtime Android su CRLF, DER >1024B e mix buildProfile Staging/Release
  const expectScript17Rejection = (extraArgs, expectedReason) => {
    let rejected = false;
    try {
      execFileSync(ps, [
        ...psExecArgs, script17,
        '-OtaReleasePublicKeyPath', pubDerPath,
        '-OtaReleaseManifestUrl', manifestUrl,
        ...extraArgs
      ], { encoding: 'utf8', stdio: 'pipe' });
    } catch (err) {
      const parsed = JSON.parse((err.stdout || '').toString());
      if (err.status === 1 && parsed.otaReady === false && parsed.reasons.includes(expectedReason)) {
        rejected = true;
      }
    }
    if (!rejected) {
      throw new Error('Script 17 failed to reject with ' + expectedReason);
    }
  };

  expectScript17Rejection(['-ApkPath', crlfChannelApk], 'APK_INVALID_BUNDLED_OTA_CHANNEL_FORMAT');
  expectScript17Rejection(['-ApkPath', oversizedDerApk], 'APK_INVALID_BUNDLED_OTA_KEY');

  const releaseProfileManifest = path.join(workDir, 'build_manifest_release.json');
  fs.writeFileSync(releaseProfileManifest, JSON.stringify({
    versionCode: 9,
    buildProfile: 'Release',
    otaProvisioned: true,
    otaReleaseManifestUrl: manifestUrl,
    otaReleasePublicKeySha256: pubSha
  }));
  const diagProfileManifest = path.join(workDir, 'build_manifest_diag.json');
  fs.writeFileSync(diagProfileManifest, JSON.stringify({
    versionCode: 7,
    buildProfile: 'Diagnostic',
    otaProvisioned: true,
    otaReleaseManifestUrl: manifestUrl,
    otaReleasePublicKeySha256: pubSha
  }));
  expectScript17Rejection(
    ['-BuildManifestPath', releaseProfileManifest, '-ChannelProfile', 'Staging'],
    'STAGING_BUILD_MANIFEST_PROFILE_MISMATCH'
  );
  expectScript17Rejection(
    ['-BuildManifestPath', diagProfileManifest, '-ChannelProfile', 'Release'],
    'RELEASE_BUILD_MANIFEST_PROFILE_MISMATCH'
  );

  console.log('PASS: OTA Provisioning E2E (Java trust/channel/manifest/downgrade + Script 17 readiness, Staging & CRLF/DER/profile guards) OK');
} finally {
  fs.rmSync(workDir, { recursive: true, force: true });
}
