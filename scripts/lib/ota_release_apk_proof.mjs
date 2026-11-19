// Fail-closed source for OWNER-OFFLINE OTA publishing only.
// Cross-platform pure output parsing, independently testable on CI.
// A JSON handoff is a claim, NOT evidence of the Android APK certificate.
import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync } from 'node:fs';
import { resolve, join } from 'node:path';

const EXPECTED_PACKAGE = 'it.akai.customremote';
const EXPECTED_CERT = '21c2c41dc4c34576cca14ad5404e87d1c5a07ace961c0fab96d128c2164a51ed';

function must(ok, label) { if (!ok) throw new Error('APK_REJECTED_' + label); }

/**
 * Parse actual stdout from apksigner verify --verbose --print-certs,
 * aapt dump badging, and aapt dump xmltree <apk> AndroidManifest.xml.
 * Callers MUST first check tool exit codes (execFileSync throws on failure).
 */
export function auditActualApkOutputs({ signerReport, badging, manifestXml, handoff }) {
  must(typeof signerReport === 'string' && typeof badging === 'string' &&
       typeof manifestXml === 'string' && handoff, 'EVIDENCE_MISSING');
  const signers = [...signerReport.matchAll(/Signer #([0-9]+) certificate SHA-256 digest:\s*([0-9a-f]{64})\s*$/gim)];
  must(signers.length === 1 && signers[0][1] === '1' &&
       signers[0][2].toLowerCase() === EXPECTED_CERT, 'REAL_SIGNER');
  must(/Verified using v2 scheme \(APK Signature Scheme v2\): true/i.test(signerReport),
       'APK_V2_SIGNATURE');
  const pkgs = [...badging.matchAll(/^package:\s+name='([^']+)'\s+versionCode='([0-9]+)'\s+versionName='([^']+)'\s*$/gm)];
  must(pkgs.length === 1 &&
       pkgs[0][1] === EXPECTED_PACKAGE &&
       Number(pkgs[0][2]) === handoff.versionCode &&
       pkgs[0][3] === handoff.versionName, 'PACKAGE_VERSION');
  must(/^sdkVersion:'21'\s*$/m.test(badging) &&
       /^targetSdkVersion:'28'\s*$/m.test(badging), 'ANDROID9_SDK');
  must(/^native-code:\s*'armeabi-v7a'\s*$/m.test(badging), 'ANDROID_ARMV7');
  // aapt dump xmltree prints A: android:debuggable(...)=... (type 0x12)
  // A release must have the flag explicitly false OR omit it.
  must(!/A:\s+android:debuggable(?:\(0x[0-9a-f]+\))?\s*=\s*\(type 0x12\)0xffffffff/im.test(manifestXml) &&
       !/A:\s+android:debuggable(?:\(0x[0-9a-f]+\))?\s*=\s*.*\btrue\b/im.test(manifestXml), 'DEBUGGABLE_TRUE');
  // The owner build recipe requires the AAPT2-produced boolean false, not
  // merely omitting the attribute and guessing the manifest default.
  must(/A:\s+android:debuggable(?:\(0x[0-9a-f]+\))?\s*=\s*\(type 0x12\)0x0(?:\s|$)/im.test(manifestXml),
       'DEBUGGABLE_FALSE_NOT_PROVEN');
  return { verified: true, packageName: EXPECTED_PACKAGE, originalSignerSha256: EXPECTED_CERT };
}

function sdkCandidates(repoRoot) {
  return [
    process.env.ANDROID_SDK_ROOT,
    process.env.ANDROID_HOME,
    join(repoRoot, 'tools', 'android-sdk'),
  ].filter(Boolean).map(v => resolve(v));
}

export function findAndroidTool(repoRoot, executable) {
  for (const sdk of sdkCandidates(repoRoot)) {
    const toolsDir = join(sdk, 'build-tools');
    if (!existsSync(toolsDir)) continue;
    const versions = readdirSync(toolsDir, { withFileTypes: true })
      .filter(x => x.isDirectory()).map(x => x.name)
      .sort((a, b) => b.localeCompare(a, undefined, { numeric: true }));
    for (const version of versions) {
      const file = join(toolsDir, version, executable);
      if (existsSync(file)) return file;
    }
  }
  throw new Error('ANDROID_BUILD_TOOLS_MISSING_' + executable);
}

export function proveActualOwnerSignedApk({ repoRoot, apkPath, handoff, runner = execFileSync }) {
  // Node execFileSync cannot directly launch .bat/.cmd on Windows.
  // Use the trusted SDK apksigner JAR with an argv vector, no shell.
  const signerJar = findAndroidTool(repoRoot, 'lib/apksigner.jar');
  const javaExecutable = [
    process.env.JAVA_HOME ? join(process.env.JAVA_HOME, 'bin', 'java.exe') : null,
    join(repoRoot, 'tools', 'jdk-17', 'bin', 'java.exe'),
  ].filter(Boolean).find(existsSync);
  must(javaExecutable, 'JAVA_NOT_AVAILABLE');
  const aaptTool = findAndroidTool(repoRoot, 'aapt.exe');
  const opts = { encoding: 'utf8', timeout: 60000, maxBuffer: 8 * 1024 * 1024, windowsHide: true };
  // Every command is executed on EXACTLY the file later used for OTA signing.
  // Never build a shell command; process argument vectors prevent injection.
  const signerReport = runner(javaExecutable, ['-jar', signerJar, 'verify', '--verbose', '--print-certs', apkPath], opts);
  const badging = runner(aaptTool, ['dump', 'badging', apkPath], opts);
  const manifestXml = runner(aaptTool, ['dump', 'xmltree', apkPath, 'AndroidManifest.xml'], opts);
  return auditActualApkOutputs({ signerReport, badging, manifestXml, handoff });
}
