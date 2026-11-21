// Critical OTA release publishing regressions. No real Android tool or key.
import assert from 'node:assert/strict';
import { auditActualApkOutputs } from '../scripts/lib/ota_release_apk_proof.mjs';

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
console.log('test_ota_release_apk_proof PASS: ' + count +
            ' real-evidence parser cases; no local APK/signing key used');
