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

  // 3. Verifica script 17 in modo strict (senza toccare LOCALAPPDATA reale):
  //    - Le fixture ZIP sintetiche host (non firmate col certificato reale owner) sono classificate
  //      come OTA_SYNTHETIC_FIXTURE_NOT_OWNER_SIGNED_APK (otaReady=false, exit 1).
  //    - Con evidenza binaria autoritativa apksigner + aapt badging + aapt xmltree coerente
  //      con manifest e profilo, script 17 restituisce OTA_PROVISIONED_READY (otaReady=true, exit 0).
  const readyBuildManifest = path.join(workDir, 'build_manifest_ready.json');
  fs.writeFileSync(readyBuildManifest, JSON.stringify({
    packageName: 'it.akai.customremote',
    versionCode: 9,
    versionName: '1.3.0-final',
    buildProfile: 'Release',
    debuggable: false,
    signerSha256: signerA,
    otaProvisioned: true,
    otaReleaseManifestUrl: manifestUrl,
    otaReleasePublicKeySha256: pubSha
  }));

  const readyStagingManifest = path.join(workDir, 'build_manifest_staging_ready.json');
  fs.writeFileSync(readyStagingManifest, JSON.stringify({
    packageName: 'it.akai.customremote',
    versionCode: 7,
    versionName: '1.3.0-diagnostic-ota-stage-v7',
    buildProfile: 'Diagnostic',
    debuggable: true,
    signerSha256: signerA,
    otaProvisioned: true,
    otaReleaseManifestUrl: manifestUrl,
    otaReleasePublicKeySha256: pubSha
  }));

  const unprovBuildManifest = path.join(workDir, 'build_manifest_unprov.json');
  fs.writeFileSync(unprovBuildManifest, JSON.stringify({
    versionCode: 4,
    buildProfile: 'Diagnostic',
    debuggable: true,
    signerSha256: signerA,
    otaProvisioned: false
  }));

  const mockSignerOwner = path.join(workDir, 'mock_apksigner_owner.txt');
  fs.writeFileSync(mockSignerOwner,
    'Verifies\n' +
    'Verified using v1 scheme (JAR signing): true\n' +
    'Verified using v2 scheme (APK Signature Scheme v2): true\n' +
    'Number of signers: 1\n' +
    'Signer #1 certificate SHA-256 digest: ' + signerA + '\n'
  );
  const mockSignerWrong = path.join(workDir, 'mock_apksigner_wrong.txt');
  fs.writeFileSync(mockSignerWrong,
    'Verifies\n' +
    'Verified using v1 scheme (JAR signing): true\n' +
    'Verified using v2 scheme (APK Signature Scheme v2): true\n' +
    'Number of signers: 1\n' +
    'Signer #1 certificate SHA-256 digest: ' + signerB + '\n'
  );

  const mockBadgingRelV9 = path.join(workDir, 'mock_badging_rel_v9.txt');
  fs.writeFileSync(mockBadgingRelV9,
    "package: name='it.akai.customremote' versionCode='9' versionName='1.3.0-final' platformBuildVersionName='9'\n" +
    "sdkVersion:'21'\n" +
    "targetSdkVersion:'28'\n" +
    "native-code: 'armeabi-v7a'\n"
  );
  const mockBadgingStageV7 = path.join(workDir, 'mock_badging_stage_v7.txt');
  fs.writeFileSync(mockBadgingStageV7,
    "package: name='it.akai.customremote' versionCode='7' versionName='1.3.0-diagnostic-ota-stage-v7' platformBuildVersionName='9'\n" +
    "sdkVersion:'21'\n" +
    "targetSdkVersion:'28'\n" +
    "native-code: 'armeabi-v7a'\n"
  );
  const mockBadgingForgedV4 = path.join(workDir, 'mock_badging_forged_v4.txt');
  fs.writeFileSync(mockBadgingForgedV4,
    "package: name='it.akai.customremote' versionCode='4' versionName='1.3.0-final' platformBuildVersionName='9'\n" +
    "sdkVersion:'21'\n" +
    "targetSdkVersion:'28'\n" +
    "native-code: 'armeabi-v7a'\n"
  );

  const mockXmlRelease = path.join(workDir, 'mock_xml_release.txt');
  fs.writeFileSync(mockXmlRelease,
    'E: manifest\n  E: application\n    A: android:debuggable(0x0101000f)=(type 0x12)0x0\n'
  );
  const mockXmlStaging = path.join(workDir, 'mock_xml_staging.txt');
  fs.writeFileSync(mockXmlStaging,
    'E: manifest\n  E: application\n    A: android:debuggable(0x0101000f)=(type 0x12)0xffffffff\n'
  );

  const ps = resolvePowerShell();
  const psExecArgs = process.platform === 'win32' ? ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File'] : ['-NoProfile', '-File'];
  const script17 = path.join(repoRoot, 'scripts', '17_check_ota_provisioning_readiness.ps1');

  // 3a. Negative test P1 (#7089748886 + #7090527341 + #7091423949): Synthetic ZIP + valid trust/channel + complete build manifest (v9 > Rescue v7 & MaxInstalled v7)
  //     + forged matching apksigner/aapt mock outputs MUST NEVER produce otaReady=true,
  //     apkBinaryProven=true, or exit 0. It must exit 1 with status=OTA_MOCK_EVIDENCE_NOT_AUTHORITATIVE.
  let rejectedMockRelease = false;
  try {
    execFileSync(ps, [
      ...psExecArgs, script17,
      '-ApkPath', provisionedApk,
      '-BuildManifestPath', readyBuildManifest,
      '-OtaReleasePublicKeyPath', pubDerPath,
      '-OtaReleaseManifestUrl', manifestUrl,
      '-RescueVersionCode', '7',
      '-MaxInstalledOrPreparedVersionCode', '7',
      '-MockApksignerReportPath', mockSignerOwner,
      '-MockAaptBadgingPath', mockBadgingRelV9,
      '-MockAaptXmltreePath', mockXmlRelease
    ], { encoding: 'utf8', stdio: 'pipe' });
  } catch (err) {
    const out = (err.stdout || '').toString();
    const parsed = JSON.parse(out);
    if (err.status === 1 &&
        parsed.otaReady === false &&
        parsed.apkBinaryProven === false &&
        parsed.mockEvidenceInjected === true &&
        parsed.realToolsVerified === false &&
        parsed.rescueFloorSupplied === true &&
        parsed.maxInstalledFloorSupplied === true &&
        parsed.versionFloorPhysicallyAttested === false &&
        parsed.rescueVersionCode === 7 &&
        parsed.maxInstalledOrPreparedVersionCode === 7 &&
        parsed.effectiveVersionFloor === 7 &&
        parsed.status === 'OTA_MOCK_EVIDENCE_NOT_AUTHORITATIVE' &&
        parsed.apkArtifactClass === 'MOCK_EVIDENCE_NON_AUTHORITATIVE' &&
        parsed.reasons.length === 1 &&
        parsed.reasons[0] === 'APK_MOCK_EVIDENCE_NOT_AUTHORITATIVE' &&
        parsed.nextRecommendedReleaseVersionCode === 10) {
      rejectedMockRelease = true;
    }
  }
  if (!rejectedMockRelease) {
    throw new Error('Script 17 failed to block forged matching mock reports from producing otaReady=true');
  }

  // 3a-bis. Partial/missing mock report paths must also fail closed with APK_AUTHORITATIVE_MOCK_EVIDENCE_MISSING
  let rejectedPartialMock = false;
  try {
    execFileSync(ps, [
      ...psExecArgs, script17,
      '-ApkPath', provisionedApk,
      '-BuildManifestPath', readyBuildManifest,
      '-OtaReleasePublicKeyPath', pubDerPath,
      '-OtaReleaseManifestUrl', manifestUrl,
      '-RescueVersionCode', '7',
      '-MaxInstalledOrPreparedVersionCode', '7',
      '-MockApksignerReportPath', mockSignerOwner
    ], { encoding: 'utf8', stdio: 'pipe' });
  } catch (err) {
    const parsed = JSON.parse((err.stdout || '').toString());
    if (err.status === 1 &&
        parsed.otaReady === false &&
        parsed.apkBinaryProven === false &&
        parsed.status === 'OTA_MOCK_EVIDENCE_NOT_AUTHORITATIVE' &&
        parsed.apkArtifactClass === 'REJECTED_INCOMPLETE_MOCK_EVIDENCE' &&
        parsed.reasons.includes('APK_MOCK_EVIDENCE_NOT_AUTHORITATIVE') &&
        parsed.reasons.includes('APK_AUTHORITATIVE_MOCK_EVIDENCE_MISSING')) {
      rejectedPartialMock = true;
    }
  }
  if (!rejectedPartialMock) {
    throw new Error('Script 17 failed to reject partial mock evidence paths with exit 1');
  }

  // 3b. Modalita' esplicita -InventoryOnly: exit 0 senza -RescueVersionCode e senza -MaxInstalledOrPreparedVersionCode,
  //     ma otaReady=false, rescueFloorSupplied=false, versionFloorPhysicallyAttested=false,
  //     nextRecommendedReleaseVersionCode=null e status=OTA_TRUST_INVENTORY_ONLY
  const invOut = execFileSync(ps, [
    ...psExecArgs, script17,
    '-InventoryOnly',
    '-OtaReleasePublicKeyPath', pubDerPath,
    '-OtaReleaseManifestUrl', manifestUrl
  ], { encoding: 'utf8' });
  const invJson = JSON.parse(invOut);
  if (invJson.otaReady !== false ||
      invJson.inventoryOnly !== true ||
      invJson.inventoryReady !== true ||
      invJson.rescueFloorSupplied !== false ||
      invJson.versionFloorPhysicallyAttested !== false ||
      invJson.nextRecommendedReleaseVersionCode !== null ||
      invJson.status !== 'OTA_TRUST_INVENTORY_ONLY') {
    throw new Error('Script 17 -InventoryOnly must never report otaReady=true, READY, or a guessed version floor: ' + invOut);
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
    if (err.status === 1 &&
        parsed.otaReady === false &&
        parsed.status === 'OTA_UNPROVISIONED_NOT_READY' &&
        parsed.reasons.includes('MISSING_OTA_TRUST_PUBLIC_KEY')) {
      rejectedUnprov = true;
    }
  }
  if (!rejectedUnprov) {
    throw new Error('Script 17 failed to reject unprovisioned APK with exit 1');
  }

  // 4. Verifica ChannelProfile Staging + RescueVersionCode=8 => nextRecommendedReleaseVersionCode=9
  //    Con mock reports deve comunque uscire con exit 1, otaReady=false, apkBinaryProven=false,
  //    status=OTA_MOCK_EVIDENCE_NOT_AUTHORITATIVE e calcolare nextRecommendedReleaseVersionCode=9.
  let rejectedMockStaging = false;
  try {
    execFileSync(ps, [
      ...psExecArgs, script17,
      '-ApkPath', provisionedApk,
      '-BuildManifestPath', readyStagingManifest,
      '-OtaReleasePublicKeyPath', pubDerPath,
      '-OtaReleaseManifestUrl', manifestUrl,
      '-ChannelProfile', 'Staging',
      '-RescueVersionCode', '8',
      '-MockApksignerReportPath', mockSignerOwner,
      '-MockAaptBadgingPath', mockBadgingStageV7,
      '-MockAaptXmltreePath', mockXmlStaging
    ], { encoding: 'utf8', stdio: 'pipe' });
  } catch (err) {
    const stagingJson = JSON.parse((err.stdout || '').toString());
    if (err.status === 1 &&
        stagingJson.otaReady === false &&
        stagingJson.apkBinaryProven === false &&
        stagingJson.status === 'OTA_MOCK_EVIDENCE_NOT_AUTHORITATIVE' &&
        stagingJson.reasons.length === 1 &&
        stagingJson.reasons[0] === 'APK_MOCK_EVIDENCE_NOT_AUTHORITATIVE' &&
        stagingJson.nextRecommendedReleaseVersionCode === 9) {
      rejectedMockStaging = true;
    }
  }
  if (!rejectedMockStaging) {
    throw new Error('Script 17 did not enforce non-authoritative mock exit 1 with nextRecommendedReleaseVersionCode=9 for Staging');
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
      if (err.status === 1 &&
          parsedBad.otaReady === false &&
          parsedBad.status === 'OTA_UNPROVISIONED_NOT_READY' &&
          parsedBad.reasons.includes('INVALID_OTA_MANIFEST_URL_REQUIRES_PUBLIC_HTTPS')) {
        rejectedBadUrl = true;
      }
    }
    if (!rejectedBadUrl) {
      throw new Error('Script 17 failed to reject non-persistent/local OTA URL: ' + badUrl);
    }
  }

  // 6. Verifica Script 17 parita' runtime Android + 7 classi di test negativi P1 (#7088998327)
  const expectScript17Rejection = (extraArgs, expectedReason, expectedStatus = 'OTA_UNPROVISIONED_NOT_READY') => {
    let rejected = false;
    let lastOut = '';
    try {
      lastOut = execFileSync(ps, [
        ...psExecArgs, script17,
        '-OtaReleasePublicKeyPath', pubDerPath,
        '-OtaReleaseManifestUrl', manifestUrl,
        ...extraArgs
      ], { encoding: 'utf8', stdio: 'pipe' });
    } catch (err) {
      lastOut = (err.stdout || '').toString();
      const parsed = JSON.parse(lastOut);
      if (err.status === 1 &&
          parsed.otaReady === false &&
          parsed.status === expectedStatus &&
          parsed.reasons.includes(expectedReason)) {
        rejected = true;
      }
    }
    if (!rejected) {
      throw new Error('Script 17 failed to reject with ' + expectedReason + ' / ' + expectedStatus + ': ' + lastOut);
    }
  };

  // (1) Key + URL only (both -ApkPath and -BuildManifestPath and version floors omitted without -InventoryOnly)
  expectScript17Rejection([], 'MISSING_APK_PATH');
  expectScript17Rejection([], 'MISSING_BUILD_MANIFEST_PATH');
  expectScript17Rejection([], 'OTA_RESCUE_VERSION_FLOOR_UNKNOWN');
  expectScript17Rejection([], 'OTA_MAX_INSTALLED_VERSION_FLOOR_UNKNOWN');

  // (1-bis) Omitted or invalid/zero -RescueVersionCode in Release and Staging
  expectScript17Rejection(['-ApkPath', provisionedApk, '-BuildManifestPath', readyBuildManifest, '-MaxInstalledOrPreparedVersionCode', '7'], 'OTA_RESCUE_VERSION_FLOOR_UNKNOWN');
  expectScript17Rejection(['-ApkPath', provisionedApk, '-BuildManifestPath', readyBuildManifest, '-RescueVersionCode', '0', '-MaxInstalledOrPreparedVersionCode', '7'], 'OTA_RESCUE_VERSION_FLOOR_UNKNOWN');
  expectScript17Rejection(['-ApkPath', provisionedApk, '-BuildManifestPath', readyBuildManifest, '-RescueVersionCode', '4', '-MaxInstalledOrPreparedVersionCode', '7'], 'OTA_RESCUE_VERSION_FLOOR_UNKNOWN');
  expectScript17Rejection(['-ApkPath', provisionedApk, '-BuildManifestPath', readyStagingManifest, '-ChannelProfile', 'Staging'], 'OTA_RESCUE_VERSION_FLOOR_UNKNOWN');

  // (1-ter) Omitted or invalid/zero -MaxInstalledOrPreparedVersionCode in strict Release mode (#7091423949)
  expectScript17Rejection(['-ApkPath', provisionedApk, '-BuildManifestPath', readyBuildManifest, '-RescueVersionCode', '7'], 'OTA_MAX_INSTALLED_VERSION_FLOOR_UNKNOWN');
  expectScript17Rejection(['-ApkPath', provisionedApk, '-BuildManifestPath', readyBuildManifest, '-RescueVersionCode', '7', '-MaxInstalledOrPreparedVersionCode', '0'], 'OTA_MAX_INSTALLED_VERSION_FLOOR_UNKNOWN');
  expectScript17Rejection(['-ApkPath', provisionedApk, '-BuildManifestPath', readyBuildManifest, '-RescueVersionCode', '7', '-MaxInstalledOrPreparedVersionCode', '3'], 'OTA_MAX_INSTALLED_VERSION_FLOOR_UNKNOWN');
  expectScript17Rejection(['-ApkPath', provisionedApk, '-BuildManifestPath', readyStagingManifest, '-ChannelProfile', 'Staging', '-RescueVersionCode', '8', '-MaxInstalledOrPreparedVersionCode', '3'], 'OTA_MAX_INSTALLED_VERSION_FLOOR_UNKNOWN');

  // (2) APK omitted (-BuildManifestPath and floors provided, -ApkPath omitted)
  expectScript17Rejection(['-BuildManifestPath', readyBuildManifest, '-RescueVersionCode', '7', '-MaxInstalledOrPreparedVersionCode', '7'], 'MISSING_APK_PATH');

  // (3) Manifest omitted (-ApkPath and floors provided, -BuildManifestPath omitted)
  expectScript17Rejection(['-ApkPath', provisionedApk, '-RescueVersionCode', '7', '-MaxInstalledOrPreparedVersionCode', '7'], 'MISSING_BUILD_MANIFEST_PATH');

  // (4) Omitted mandatory manifest fields: otaProvisioned, buildProfile, debuggable, signerSha256, versionCode
  const baseCompleteMan = {
    versionCode: 9,
    buildProfile: 'Release',
    debuggable: false,
    signerSha256: signerA,
    otaProvisioned: true,
    otaReleaseManifestUrl: manifestUrl,
    otaReleasePublicKeySha256: pubSha
  };
  for (const [omittedField, expectedReason] of [
    ['versionCode', 'BUILD_MANIFEST_MISSING_VERSION_CODE'],
    ['buildProfile', 'BUILD_MANIFEST_MISSING_BUILD_PROFILE'],
    ['debuggable', 'BUILD_MANIFEST_MISSING_DEBUGGABLE'],
    ['signerSha256', 'BUILD_MANIFEST_MISSING_SIGNER_SHA256'],
    ['otaProvisioned', 'BUILD_MANIFEST_MISSING_OTA_PROVISIONED']
  ]) {
    const partialObj = { ...baseCompleteMan };
    delete partialObj[omittedField];
    const partialPath = path.join(workDir, `build_manifest_omit_${omittedField}.json`);
    fs.writeFileSync(partialPath, JSON.stringify(partialObj));
    expectScript17Rejection(
      ['-ApkPath', provisionedApk, '-BuildManifestPath', partialPath, '-RescueVersionCode', '7', '-MaxInstalledOrPreparedVersionCode', '7'],
      expectedReason
    );
  }

  // (5) Forged metadata: JSON manifest claims Release v9 debuggable=false signerA,
  //     but apksigner/aapt binary inspection shows version/debuggable/signer/apkSha256 mismatch
  expectScript17Rejection(
    [
      '-ApkPath', provisionedApk,
      '-BuildManifestPath', readyBuildManifest,
      '-RescueVersionCode', '7',
      '-MaxInstalledOrPreparedVersionCode', '7',
      '-MockApksignerReportPath', mockSignerOwner,
      '-MockAaptBadgingPath', mockBadgingForgedV4,
      '-MockAaptXmltreePath', mockXmlRelease
    ],
    'APK_BINARY_VERSION_CODE_MISMATCH_WITH_MANIFEST',
    'OTA_MOCK_EVIDENCE_NOT_AUTHORITATIVE'
  );
  expectScript17Rejection(
    [
      '-ApkPath', provisionedApk,
      '-BuildManifestPath', readyBuildManifest,
      '-RescueVersionCode', '7',
      '-MaxInstalledOrPreparedVersionCode', '7',
      '-MockApksignerReportPath', mockSignerOwner,
      '-MockAaptBadgingPath', mockBadgingRelV9,
      '-MockAaptXmltreePath', mockXmlStaging
    ],
    'APK_BINARY_RELEASE_DEBUGGABLE_FORBIDDEN',
    'OTA_MOCK_EVIDENCE_NOT_AUTHORITATIVE'
  );
  expectScript17Rejection(
    [
      '-ApkPath', provisionedApk,
      '-BuildManifestPath', readyBuildManifest,
      '-RescueVersionCode', '7',
      '-MaxInstalledOrPreparedVersionCode', '7',
      '-MockApksignerReportPath', mockSignerWrong,
      '-MockAaptBadgingPath', mockBadgingRelV9,
      '-MockAaptXmltreePath', mockXmlRelease
    ],
    'APK_BINARY_SIGNER_MISMATCH',
    'OTA_MOCK_EVIDENCE_NOT_AUTHORITATIVE'
  );
  const forgedApkShaMan = path.join(workDir, 'build_manifest_forged_apksha.json');
  fs.writeFileSync(forgedApkShaMan, JSON.stringify({
    ...baseCompleteMan,
    apkSha256: '0000000000000000000000000000000000000000000000000000000000000000'
  }));
  expectScript17Rejection(
    [
      '-ApkPath', provisionedApk,
      '-BuildManifestPath', forgedApkShaMan,
      '-RescueVersionCode', '7',
      '-MaxInstalledOrPreparedVersionCode', '7',
      '-MockApksignerReportPath', mockSignerOwner,
      '-MockAaptBadgingPath', mockBadgingRelV9,
      '-MockAaptXmltreePath', mockXmlRelease
    ],
    'BUILD_MANIFEST_APK_SHA256_MISMATCH',
    'OTA_MOCK_EVIDENCE_NOT_AUTHORITATIVE'
  );

  // (6) Wrong embedded key or wrong embedded channel inside APK
  const { publicKey: otherPubDer } = crypto.generateKeyPairSync('rsa', {
    modulusLength: 3072,
    publicKeyEncoding: { type: 'spki', format: 'der' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' }
  });
  const wrongBundledKeyApk = path.join(workDir, 'wrong-bundled-key.apk');
  writeStoredZip(wrongBundledKeyApk, [
    ['AndroidManifest.xml', Buffer.from('DUMMY_MANIFEST')],
    ['classes.dex', Buffer.from('DUMMY_DEX')],
    ['assets/ota-release-public.der', otherPubDer],
    ['assets/ota-release-channel.txt', Buffer.from(manifestUrl + '\n', 'utf8')]
  ]);
  const wrongBundledChannelApk = path.join(workDir, 'wrong-bundled-channel.apk');
  writeStoredZip(wrongBundledChannelApk, [
    ['AndroidManifest.xml', Buffer.from('DUMMY_MANIFEST')],
    ['classes.dex', Buffer.from('DUMMY_DEX')],
    ['assets/ota-release-public.der', pubDer],
    ['assets/ota-release-channel.txt', Buffer.from('https://other-host.akai-jarvis.example/releases/jarvis-v6.manifest\n', 'utf8')]
  ]);
  expectScript17Rejection(
    [
      '-ApkPath', wrongBundledKeyApk,
      '-BuildManifestPath', readyBuildManifest,
      '-RescueVersionCode', '7',
      '-MaxInstalledOrPreparedVersionCode', '7',
      '-MockApksignerReportPath', mockSignerOwner,
      '-MockAaptBadgingPath', mockBadgingRelV9,
      '-MockAaptXmltreePath', mockXmlRelease
    ],
    'APK_PUBLIC_KEY_MISMATCH_WITH_TRUST_DIR',
    'OTA_MOCK_EVIDENCE_NOT_AUTHORITATIVE'
  );
  expectScript17Rejection(
    [
      '-ApkPath', wrongBundledChannelApk,
      '-BuildManifestPath', readyBuildManifest,
      '-RescueVersionCode', '7',
      '-MaxInstalledOrPreparedVersionCode', '7',
      '-MockApksignerReportPath', mockSignerOwner,
      '-MockAaptBadgingPath', mockBadgingRelV9,
      '-MockAaptXmltreePath', mockXmlRelease
    ],
    'APK_CHANNEL_URL_MISMATCH',
    'OTA_MOCK_EVIDENCE_NOT_AUTHORITATIVE'
  );
  expectScript17Rejection(
    ['-ApkPath', wrongBundledKeyApk, '-BuildManifestPath', readyBuildManifest, '-RescueVersionCode', '7', '-MaxInstalledOrPreparedVersionCode', '7'],
    'APK_PUBLIC_KEY_MISMATCH_WITH_TRUST_DIR'
  );
  expectScript17Rejection(
    ['-ApkPath', wrongBundledChannelApk, '-BuildManifestPath', readyBuildManifest, '-RescueVersionCode', '7', '-MaxInstalledOrPreparedVersionCode', '7'],
    'APK_CHANNEL_URL_MISMATCH'
  );
  expectScript17Rejection(
    ['-ApkPath', crlfChannelApk, '-BuildManifestPath', readyBuildManifest, '-RescueVersionCode', '7', '-MaxInstalledOrPreparedVersionCode', '7'],
    'APK_INVALID_BUNDLED_OTA_CHANNEL_FORMAT'
  );
  expectScript17Rejection(
    ['-ApkPath', oversizedDerApk, '-BuildManifestPath', readyBuildManifest, '-RescueVersionCode', '7', '-MaxInstalledOrPreparedVersionCode', '7'],
    'APK_INVALID_BUNDLED_OTA_KEY'
  );

  // (7) Valid synthetic host fixture (provisionedApk + readyBuildManifest + explicit -RescueVersionCode 7 + -MaxInstalledOrPreparedVersionCode 8, without real owner APK signature):
  //     When real Android SDK tools run against the synthetic ZIP fixture, it must be classified
  //     as OTA_SYNTHETIC_FIXTURE_NOT_OWNER_SIGNED_APK (or ANDROID_SDK_AUTHORITATIVE_TOOLS_UNAVAILABLE if no SDK),
  //     NEVER OTA_PROVISIONED_READY and ALWAYS exit 1 with otaReady=false.
  let syntheticClassified = false;
  try {
    execFileSync(ps, [
      ...psExecArgs, script17,
      '-ApkPath', provisionedApk,
      '-BuildManifestPath', readyBuildManifest,
      '-OtaReleasePublicKeyPath', pubDerPath,
      '-OtaReleaseManifestUrl', manifestUrl,
      '-RescueVersionCode', '7',
      '-MaxInstalledOrPreparedVersionCode', '8'
    ], { encoding: 'utf8', stdio: 'pipe' });
  } catch (err) {
    const parsedSyn = JSON.parse((err.stdout || '').toString());
    if (err.status === 1 &&
        parsedSyn.otaReady === false &&
        parsedSyn.apkBinaryProven === false &&
        parsedSyn.rescueFloorSupplied === true &&
        parsedSyn.maxInstalledFloorSupplied === true &&
        parsedSyn.versionFloorPhysicallyAttested === false &&
        parsedSyn.rescueVersionCode === 7 &&
        parsedSyn.maxInstalledOrPreparedVersionCode === 8 &&
        parsedSyn.effectiveVersionFloor === 8 &&
        parsedSyn.nextRecommendedReleaseVersionCode === 10 &&
        ((parsedSyn.status === 'OTA_SYNTHETIC_FIXTURE_NOT_OWNER_SIGNED_APK' &&
          parsedSyn.apkArtifactClass === 'SYNTHETIC_HOST_FIXTURE' &&
          parsedSyn.reasons.includes('APK_SYNTHETIC_FIXTURE_NOT_OWNER_SIGNED')) ||
         (parsedSyn.status === 'OTA_UNPROVISIONED_NOT_READY' &&
          parsedSyn.reasons.includes('ANDROID_SDK_AUTHORITATIVE_TOOLS_UNAVAILABLE')))) {
      syntheticClassified = true;
    }
  }
  if (!syntheticClassified) {
    throw new Error('Script 17 failed to classify synthetic host fixture as non-ready (exit 1)');
  }

  // (7-bis) MaxInstalledOrPreparedVersionCode > RescueVersionCode and > candidate (e.g. candidate=9, Rescue=7, MaxInstalled=10):
  //         must reject with RELEASE_VERSION_NOT_ABOVE_MAX_INSTALLED and compute effectiveVersionFloor=10, nextRecommendedReleaseVersionCode=11
  let maxAboveRescueChecked = false;
  try {
    execFileSync(ps, [
      ...psExecArgs, script17,
      '-ApkPath', provisionedApk,
      '-BuildManifestPath', readyBuildManifest,
      '-OtaReleasePublicKeyPath', pubDerPath,
      '-OtaReleaseManifestUrl', manifestUrl,
      '-RescueVersionCode', '7',
      '-MaxInstalledOrPreparedVersionCode', '10'
    ], { encoding: 'utf8', stdio: 'pipe' });
  } catch (err) {
    const parsedMax = JSON.parse((err.stdout || '').toString());
    if (err.status === 1 &&
        parsedMax.otaReady === false &&
        parsedMax.effectiveVersionFloor === 10 &&
        parsedMax.nextRecommendedReleaseVersionCode === 11 &&
        parsedMax.reasons.includes('RELEASE_VERSION_NOT_ABOVE_MAX_INSTALLED')) {
      maxAboveRescueChecked = true;
    }
  }
  if (!maxAboveRescueChecked) {
    throw new Error('Script 17 failed to enforce MaxInstalledOrPreparedVersionCode=10 > RescueVersionCode=7 over candidate v9');
  }

  const releaseProfileManifest = path.join(workDir, 'build_manifest_release.json');
  fs.writeFileSync(releaseProfileManifest, JSON.stringify({
    versionCode: 9,
    buildProfile: 'Release',
    debuggable: false,
    signerSha256: signerA,
    otaProvisioned: true,
    otaReleaseManifestUrl: manifestUrl,
    otaReleasePublicKeySha256: pubSha
  }));
  const diagProfileManifest = path.join(workDir, 'build_manifest_diag.json');
  fs.writeFileSync(diagProfileManifest, JSON.stringify({
    versionCode: 7,
    buildProfile: 'Diagnostic',
    debuggable: true,
    signerSha256: signerA,
    otaProvisioned: true,
    otaReleaseManifestUrl: manifestUrl,
    otaReleasePublicKeySha256: pubSha
  }));
  expectScript17Rejection(
    ['-ApkPath', provisionedApk, '-BuildManifestPath', releaseProfileManifest, '-ChannelProfile', 'Staging', '-RescueVersionCode', '10'],
    'STAGING_BUILD_MANIFEST_PROFILE_MISMATCH'
  );
  expectScript17Rejection(
    ['-ApkPath', provisionedApk, '-BuildManifestPath', diagProfileManifest, '-ChannelProfile', 'Release', '-RescueVersionCode', '5', '-MaxInstalledOrPreparedVersionCode', '5'],
    'RELEASE_BUILD_MANIFEST_PROFILE_MISMATCH'
  );
  expectScript17Rejection(
    ['-ApkPath', provisionedApk, '-BuildManifestPath', diagProfileManifest, '-ChannelProfile', 'Staging', '-RescueVersionCode', '7'],
    'STAGING_RESCUE_VERSION_NOT_ABOVE_CANDIDATE'
  );
  expectScript17Rejection(
    ['-ApkPath', provisionedApk, '-BuildManifestPath', diagProfileManifest, '-ChannelProfile', 'Staging', '-RescueVersionCode', '6'],
    'STAGING_RESCUE_VERSION_NOT_ABOVE_CANDIDATE'
  );
  expectScript17Rejection(
    ['-ApkPath', provisionedApk, '-BuildManifestPath', releaseProfileManifest, '-ChannelProfile', 'Release', '-RescueVersionCode', '9', '-MaxInstalledOrPreparedVersionCode', '7'],
    'RELEASE_VERSION_NOT_ABOVE_RESCUE'
  );
  expectScript17Rejection(
    ['-ApkPath', provisionedApk, '-BuildManifestPath', releaseProfileManifest, '-ChannelProfile', 'Release', '-RescueVersionCode', '10', '-MaxInstalledOrPreparedVersionCode', '7'],
    'RELEASE_VERSION_NOT_ABOVE_RESCUE'
  );
  expectScript17Rejection(
    ['-ApkPath', provisionedApk, '-BuildManifestPath', releaseProfileManifest, '-ChannelProfile', 'Release', '-RescueVersionCode', '7', '-MaxInstalledOrPreparedVersionCode', '9'],
    'RELEASE_VERSION_NOT_ABOVE_MAX_INSTALLED'
  );

  const nonDebuggableStagingMan = path.join(workDir, 'build_manifest_stage_nodbg.json');
  fs.writeFileSync(nonDebuggableStagingMan, JSON.stringify({
    versionCode: 7,
    buildProfile: 'Diagnostic',
    debuggable: false,
    signerSha256: signerA,
    otaProvisioned: true,
    otaReleaseManifestUrl: manifestUrl,
    otaReleasePublicKeySha256: pubSha
  }));
  expectScript17Rejection(
    ['-ApkPath', provisionedApk, '-BuildManifestPath', nonDebuggableStagingMan, '-ChannelProfile', 'Staging', '-RescueVersionCode', '8'],
    'STAGING_BUILD_MANIFEST_NOT_DEBUGGABLE'
  );

  const debuggableReleaseMan = path.join(workDir, 'build_manifest_rel_dbg.json');
  fs.writeFileSync(debuggableReleaseMan, JSON.stringify({
    versionCode: 9,
    buildProfile: 'Release',
    debuggable: true,
    signerSha256: signerA,
    otaProvisioned: true,
    otaReleaseManifestUrl: manifestUrl,
    otaReleasePublicKeySha256: pubSha
  }));
  expectScript17Rejection(
    ['-ApkPath', provisionedApk, '-BuildManifestPath', debuggableReleaseMan, '-ChannelProfile', 'Release', '-RescueVersionCode', '7', '-MaxInstalledOrPreparedVersionCode', '7'],
    'RELEASE_BUILD_MANIFEST_DEBUGGABLE_FORBIDDEN'
  );

  const wrongSignerMan = path.join(workDir, 'build_manifest_wrong_signer.json');
  fs.writeFileSync(wrongSignerMan, JSON.stringify({
    versionCode: 9,
    buildProfile: 'Release',
    debuggable: false,
    signerSha256: signerB,
    otaProvisioned: true,
    otaReleaseManifestUrl: manifestUrl,
    otaReleasePublicKeySha256: pubSha
  }));
  expectScript17Rejection(
    ['-ApkPath', provisionedApk, '-BuildManifestPath', wrongSignerMan, '-ChannelProfile', 'Release', '-RescueVersionCode', '7', '-MaxInstalledOrPreparedVersionCode', '7'],
    'BUILD_MANIFEST_SIGNER_MISMATCH'
  );

  const lowStageVcMan = path.join(workDir, 'build_manifest_low_stage_vc.json');
  fs.writeFileSync(lowStageVcMan, JSON.stringify({
    versionCode: 4,
    buildProfile: 'Diagnostic',
    debuggable: true,
    signerSha256: signerA,
    otaProvisioned: true,
    otaReleaseManifestUrl: manifestUrl,
    otaReleasePublicKeySha256: pubSha
  }));
  expectScript17Rejection(
    ['-ApkPath', provisionedApk, '-BuildManifestPath', lowStageVcMan, '-ChannelProfile', 'Staging', '-RescueVersionCode', '8'],
    'STAGING_VERSION_CODE_OUT_OF_RANGE'
  );

  console.log('PASS: OTA Provisioning E2E (Java trust/channel/manifest/downgrade + Script 17 strict readiness, -InventoryOnly, synthetic fixture & binary proof guards) OK');
} finally {
  fs.rmSync(workDir, { recursive: true, force: true });
}
