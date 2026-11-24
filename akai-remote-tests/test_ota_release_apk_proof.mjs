// Critical OTA release publishing regressions. No real Android tool or key.
import assert from 'node:assert/strict';
import {
  auditActualApkOutputs,
  auditActualRescueApkOutputs,
  EXPECTED_CERT,
  EXPECTED_PACKAGE,
} from '../scripts/lib/ota_release_apk_proof.mjs';
import { validateReleaseHttpsUrl } from '../scripts/14_sign_ota_release_manifest.mjs';

const original = '21c2c41dc4c34576cca14ad5404e87d1c5a07ace961c0fab96d128c2164a51ed';
const alternate = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const fixture = {
  handoff: { packageName: 'it.akai.customremote', versionCode: 5, versionName: '1.3.0' },
  signerReport: 'Verifies\nVerified using v1 scheme (JAR signing): true\n' +
    'Verified using v2 scheme (APK Signature Scheme v2): true\n' +
    'Number of signers: 1\nSigner #1 certificate SHA-256 digest: ' + original + '\n',
  badging: "package: name='it.akai.customremote' versionCode='5' versionName='1.3.0' " +
    "platformBuildVersionName='9' platformBuildVersionCode='28'\n" +
    "sdkVersion:'21'\ntargetSdkVersion:'28'\nnative-code: 'armeabi-v7a'\n",
  manifestXml: 'E: manifest\n  E: application\n    A: android:debuggable(0x0101000f)=(type 0x12)0x0\n',
};

let count = 0;
function accept(input, label) {
  assert.equal(auditActualApkOutputs(input).verified, true, label);
  count++;
}
function reject(input, label) {
  assert.throws(() => auditActualApkOutputs(input), /APK_REJECTED_/, label);
  count++;
}
accept(fixture, 'original owner-signed v5 Android 9 ARMv7 release');
reject({ ...fixture, signerReport: fixture.signerReport.replace(original, alternate) },
       'fake JSON claims do not override WRONG ACTUAL APK CERT');
reject({ ...fixture, signerReport: fixture.signerReport.replace(
  'Verified using v2 scheme (APK Signature Scheme v2): true',
  'Verified using v2 scheme (APK Signature Scheme v2): false') },
       'apk v2 scheme unverified');
reject({ ...fixture, signerReport: fixture.signerReport + 'Verified using v2 scheme (APK Signature Scheme v2): false\n' },
       'contradictory duplicate v2 status');
reject({ ...fixture, signerReport: fixture.signerReport.replace(
  'Verified using v2 scheme (APK Signature Scheme v2): true',
  'Not Verified using v2 scheme (APK Signature Scheme v2): true') },
       'v2 status must be anchored to actual apksigner output');
reject({ ...fixture, manifestXml: fixture.manifestXml +
  '    A: android:debuggable(0x0101000f)=(type 0x12)0x0\n' },
       'duplicate compiled debuggable attributes');
reject({ ...fixture, signerReport: fixture.signerReport.replace('Number of signers: 1', 'Number of signers: 2') },
       'contradictory signer count even when only first certificate is printed');
reject({ ...fixture, signerReport: fixture.signerReport.replace('Number of signers: 1\n', '') },
       'missing actual signer count');
reject({ ...fixture, signerReport: fixture.signerReport + 'Number of signers: 1\n' },
       'duplicate signer count');
reject({ ...fixture, signerReport: fixture.signerReport.replace(
  'Number of signers: 1', 'Number of signers: 2') +
  'Signer #2 certificate SHA-256 digest: ' + alternate + '\n' },
       'APK with multiple signers rejected');
reject({ ...fixture, badging: fixture.badging.replace('it.akai.customremote', 'org.evil.tv') },
       'wrong actual APK package');
reject({ ...fixture, badging: fixture.badging.replace("versionCode='5'", "versionCode='4'") },
       'wrong real version');
reject({ ...fixture, badging: fixture.badging.replace("versionName='1.3.0'", "versionName='tampered'") },
       'wrong actual version name');
reject({ ...fixture, badging: fixture.badging.replace("sdkVersion:'21'", "sdkVersion:'29'") },
       'wrong min sdk');
reject({ ...fixture, badging: fixture.badging.replace("targetSdkVersion:'28'", "targetSdkVersion:'29'") },
       'wrong target sdk');
reject({ ...fixture, badging: fixture.badging.replace("native-code: 'armeabi-v7a'", "native-code: 'arm64-v8a'") },
       'wrong architecture');
reject({ ...fixture, badging: fixture.badging + "sdkVersion:'29'\n" },
       'duplicate contradictory minimum SDK must fail closed');
reject({ ...fixture, badging: fixture.badging + "targetSdkVersion:'29'\n" },
       'duplicate contradictory target SDK must fail closed');
reject({ ...fixture, badging: fixture.badging + "native-code: 'arm64-v8a'\n" },
       'duplicate contradictory ABI must fail closed');
reject({ ...fixture, manifestXml: fixture.manifestXml.replace('(type 0x12)0x0', '(type 0x12)0xffffffff') },
       'debuggable true');
reject({ ...fixture, manifestXml: 'E: manifest\n E: application\n' },
       'no actual debuggable=false evidence');
reject({ ...fixture, manifestXml: fixture.manifestXml.replace('(type 0x12)0x0', '(type 0x12)0x1') },
       'non-false boolean (unknown value)');
reject({ ...fixture, signerReport: '' }, 'missing signer report');
reject({ ...fixture, badging: '' }, 'missing badging report');
reject({ ...fixture, manifestXml: '' }, 'missing manifest report');
reject({ ...fixture, handoff: { ...fixture.handoff, versionCode: 6 } },
       'wrong JSON expected version');

assert.equal(validateReleaseHttpsUrl('https://updates.akai-jarvis.example/releases/v5.manifest', '.manifest').hostname, 'updates.akai-jarvis.example');
count++;
assert.equal(validateReleaseHttpsUrl('https://updates.akai-jarvis.example/releases/jarvis-v5.apk', '.apk').pathname, '/releases/jarvis-v5.apk');
count++;
for (const badUrl of [
  'http://updates.akai-jarvis.example/releases/v5.apk',
  'https://updates.akai-jarvis.example:8443/releases/v5.apk',
  'https://updates.akai-jarvis.example/releases/v5.apk?x=1',
  'https://updates.akai-jarvis.example/releases/v5.apk#frag',
  'https://user@updates.akai-jarvis.example/releases/v5.apk',
  'https://updates.akai-jarvis.example/releases/../v5.apk',
  'https://updates.akai-jarvis.example/releases/%2e%2e/v5.apk',
  'https://localhost/releases/v5.apk',
  'https://127.0.0.1/releases/v5.apk',
  'https://192.168.1.50/releases/v5.apk',
  'https://[::1]/releases/v5.apk',
  'https://jarvis.local/releases/v5.apk',
  'https://router.lan/releases/v5.apk',
  'https://host.internal/releases/v5.apk',
  'https://tv.home/releases/v5.apk',
  'https://singlelabel/releases/v5.apk',
]) {
  assert.throws(() => validateReleaseHttpsUrl(badUrl, '.apk'), /RELEASE_URL_REJECTED_/, 'reject unsafe release URL: ' + badUrl);
  count++;
}

// Rescue APK audit checks (cert, package, expected versionCode, debuggable=false)
const rescueBadgingV9 = fixture.badging.replace("versionCode='5' versionName='1.3.0'", "versionCode='9' versionName='1.3.0-rescue-v9'");
const rescueOk = auditActualRescueApkOutputs({
  signerReport: fixture.signerReport,
  badging: rescueBadgingV9,
  manifestXml: fixture.manifestXml,
  expectedVersionCode: 9,
});
assert.equal(rescueOk.verified, true);
assert.equal(rescueOk.packageName, EXPECTED_PACKAGE);
assert.equal(rescueOk.versionCode, 9);
assert.equal(rescueOk.originalSignerSha256, EXPECTED_CERT);
count++;

assert.throws(
  () => auditActualRescueApkOutputs({
    signerReport: fixture.signerReport.replace(original, alternate),
    badging: rescueBadgingV9,
    manifestXml: fixture.manifestXml,
    expectedVersionCode: 9,
  }),
  /APK_REJECTED_REAL_SIGNER/,
  'reject rescue APK with wrong signing certificate'
);
count++;

assert.throws(
  () => auditActualRescueApkOutputs({
    signerReport: fixture.signerReport,
    badging: rescueBadgingV9.replace('it.akai.customremote', 'org.evil.rescue'),
    manifestXml: fixture.manifestXml,
    expectedVersionCode: 9,
  }),
  /APK_REJECTED_PACKAGE_VERSION/,
  'reject rescue APK with wrong package'
);
count++;

assert.throws(
  () => auditActualRescueApkOutputs({
    signerReport: fixture.signerReport,
    badging: rescueBadgingV9.replace("versionCode='9'", "versionCode='8'"),
    manifestXml: fixture.manifestXml,
    expectedVersionCode: 9,
  }),
  /APK_REJECTED_PACKAGE_VERSION/,
  'reject rescue APK with mismatched versionCode'
);
count++;

assert.throws(
  () => auditActualRescueApkOutputs({
    signerReport: fixture.signerReport,
    badging: rescueBadgingV9,
    manifestXml: fixture.manifestXml.replace('(type 0x12)0x0', '(type 0x12)0xffffffff'),
    expectedVersionCode: 9,
  }),
  /APK_REJECTED_DEBUGGABLE_TRUE/,
  'reject debuggable rescue APK'
);
count++;

console.log('test_ota_release_apk_proof PASS: ' + count +
            ' real-evidence parser and PC-off URL cases; no local APK/signing key used');
