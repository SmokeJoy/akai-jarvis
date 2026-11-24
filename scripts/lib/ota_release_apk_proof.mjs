// Fail-closed source for OWNER-OFFLINE OTA publishing only.
// Cross-platform pure output parsing, independently testable on CI.
// A JSON handoff is a claim, NOT evidence of the Android APK certificate.
import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync } from 'node:fs';
import { resolve, join } from 'node:path';

export const EXPECTED_PACKAGE = 'it.akai.customremote';
export const EXPECTED_CERT = '21c2c41dc4c34576cca14ad5404e87d1c5a07ace961c0fab96d128c2164a51ed';

function must(ok, label) { if (!ok) throw new Error('APK_REJECTED_' + label); }

function auditApkCore({ signerReport, badging, manifestXml }) {
  must(typeof signerReport === 'string' && typeof badging === 'string' &&
       typeof manifestXml === 'string', 'EVIDENCE_MISSING');
  const signers = [...signerReport.matchAll(/Signer #([0-9]+) certificate SHA-256 digest:\s*([0-9a-f]{64})\s*$/gim)];
  must(signers.length === 1 && signers[0][1] === '1' &&
       signers[0][2].toLowerCase() === EXPECTED_CERT, 'REAL_SIGNER');
  // A truncated/contradictory apksigner report must never hide an extra signer.
  const signerCounts = [...signerReport.matchAll(/^Number of signers:\s*([0-9]+)\s*$/gim)];
  must(signerCounts.length === 1 && signerCounts[0][1] === '1', 'SIGNER_COUNT');
  const v2Reports = [...signerReport.matchAll(/^Verified using v2 scheme \(APK Signature Scheme v2\):\s*(true|false)\s*$/gim)];
  must(v2Reports.length === 1 && v2Reports[0][1].toLowerCase() === 'true',
       'APK_V2_SIGNATURE');
  const pkgs = [...badging.matchAll(/^package:\s+name='([^']+)'\s+versionCode='([0-9]+)'\s+versionName='([^']+)'(?:\s+[^\n]*)?$/gm)];
  must(pkgs.length === 1 && pkgs[0][1] === EXPECTED_PACKAGE, 'PACKAGE_VERSION');
  const actualVersionCode = Number(pkgs[0][2]);
  const actualVersionName = pkgs[0][3];
  must(Number.isSafeInteger(actualVersionCode) && actualVersionCode > 0 && actualVersionName.length > 0,
       'PACKAGE_VERSION');
  // Require exactly one declaration for each property. A second, conflicting
  // line must not be hidden by an otherwise valid first match.
  const sdkLines = [...badging.matchAll(/^sdkVersion:\s*'([^']*)'\s*$/gm)];
  const targetLines = [...badging.matchAll(/^targetSdkVersion:\s*'([^']*)'\s*$/gm)];
  const nativeLines = [...badging.matchAll(/^native-code:\s*(.*)$/gm)];
  must(sdkLines.length === 1 && sdkLines[0][1] === '21' &&
       targetLines.length === 1 && targetLines[0][1] === '28', 'ANDROID9_SDK');
  must(nativeLines.length === 1 && nativeLines[0][1].trim() === "'armeabi-v7a'", 'ANDROID_ARMV7');
  // aapt dump xmltree prints A: android:debuggable(...)=... (type 0x12)
  // A release must have the flag explicitly false.
  must(!/A:\s+android:debuggable(?:\(0x[0-9a-f]+\))?\s*=\s*\(type 0x12\)0xffffffff/im.test(manifestXml) &&
       !/A:\s+android:debuggable(?:\(0x[0-9a-f]+\))?\s*=\s*.*\btrue\b/im.test(manifestXml), 'DEBUGGABLE_TRUE');
  const debugAttributes = [...manifestXml.matchAll(/^\s*A:\s+android:debuggable(?:\(0x[0-9a-f]+\))?\s*=/gim)];
  must(debugAttributes.length === 1, 'DEBUGGABLE_ATTRIBUTE_COUNT');
  // The owner build recipe requires the AAPT2-produced boolean false, not
  // merely omitting the attribute and guessing the manifest default.
  must(/A:\s+android:debuggable(?:\(0x[0-9a-f]+\))?\s*=\s*\(type 0x12\)0x0(?:\s|$)/im.test(manifestXml),
       'DEBUGGABLE_FALSE_NOT_PROVEN');
  return { versionCode: actualVersionCode, versionName: actualVersionName };
}

/**
 * Parse actual stdout from apksigner verify --verbose --print-certs,
 * aapt dump badging, and aapt dump xmltree <apk> AndroidManifest.xml.
 * Callers MUST first check tool exit codes (execFileSync throws on failure).
 */
export function auditActualApkOutputs({ signerReport, badging, manifestXml, handoff }) {
  must(handoff && typeof handoff === 'object', 'EVIDENCE_MISSING');
  const actual = auditApkCore({ signerReport, badging, manifestXml });
  must(actual.versionCode === handoff.versionCode &&
       actual.versionName === handoff.versionName, 'PACKAGE_VERSION');
  return { verified: true, packageName: EXPECTED_PACKAGE, originalSignerSha256: EXPECTED_CERT };
}

/**
 * Audit actual Rescue APK outputs without requiring a separate JSON build handoff:
 * enforces expected owner signer, packageName, expectedVersionCode >= 5,
 * Android 9/ARMv7 metadata, and non-debuggable compiled manifest flag.
 */
export function auditActualRescueApkOutputs({ signerReport, badging, manifestXml, expectedVersionCode }) {
  must(Number.isInteger(expectedVersionCode) && expectedVersionCode >= 5, 'PACKAGE_VERSION');
  const actual = auditApkCore({ signerReport, badging, manifestXml });
  must(actual.versionCode === expectedVersionCode, 'PACKAGE_VERSION');
  return {
    verified: true,
    packageName: EXPECTED_PACKAGE,
    versionCode: expectedVersionCode,
    versionName: actual.versionName,
    originalSignerSha256: EXPECTED_CERT,
  };
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

function resolveApkTools({ repoRoot, allowSymbolicTools = false }) {
  const javaName = process.platform === 'win32' ? 'java.exe' : 'java';
  const aaptName = process.platform === 'win32' ? 'aapt.exe' : 'aapt';
  let signerJar;
  try {
    signerJar = findAndroidTool(repoRoot, 'lib/apksigner.jar');
  } catch (err) {
    if (!allowSymbolicTools) throw err;
    signerJar = 'apksigner.jar';
  }
  const javaExecutable = [
    process.env.JAVA_HOME ? join(process.env.JAVA_HOME, 'bin', javaName) : null,
    join(repoRoot, 'tools', 'jdk-17', 'bin', javaName),
  ].filter(Boolean).find(existsSync) || (allowSymbolicTools ? 'java' : (process.platform !== 'win32' ? 'java' : null));
  must(javaExecutable, 'JAVA_NOT_AVAILABLE');
  let aaptTool;
  try {
    aaptTool = findAndroidTool(repoRoot, aaptName);
  } catch (err) {
    if (!allowSymbolicTools) throw err;
    aaptTool = 'aapt';
  }
  return { signerJar, javaExecutable, aaptTool };
}

function collectRawApkToolOutputs({ repoRoot, apkPath, runner, allowSymbolicTools = false }) {
  if (typeof runner !== 'function') throw new Error('APK_REJECTED_EVIDENCE_MISSING');
  // Node execFileSync cannot directly launch .bat/.cmd on Windows.
  // Use the trusted SDK apksigner JAR with an argv vector, no shell.
  const { signerJar, javaExecutable, aaptTool } = resolveApkTools({ repoRoot, allowSymbolicTools });
  const opts = { encoding: 'utf8', timeout: 60000, maxBuffer: 8 * 1024 * 1024, windowsHide: true };
  // Every command is executed on EXACTLY the APK file on disk without a shell.
  const signerReport = runner(javaExecutable, ['-jar', signerJar, 'verify', '--verbose', '--print-certs', apkPath], opts);
  const badging = runner(aaptTool, ['dump', 'badging', apkPath], opts);
  const manifestXml = runner(aaptTool, ['dump', 'xmltree', apkPath, 'AndroidManifest.xml'], opts);
  return { signerReport, badging, manifestXml };
}

export function proveActualOwnerSignedApk({ repoRoot, apkPath, handoff, runner = execFileSync }) {
  const outputs = collectRawApkToolOutputs({ repoRoot, apkPath, runner, allowSymbolicTools: false });
  return auditActualApkOutputs({ ...outputs, handoff });
}

/**
 * Prove an actual A2 Rescue APK on disk via apksigner.jar + aapt:
 * verifies original owner cert, packageName, expectedVersionCode >= 5,
 * Android 9/ARMv7 metadata, and non-debuggable compiled manifest flag.
 */
export function proveActualRescueApk({ repoRoot, apkPath, expectedVersionCode, runner = execFileSync }) {
  must(typeof apkPath === 'string' && apkPath.length > 0 && existsSync(apkPath), 'EVIDENCE_MISSING');
  const allowSymbolicTools = runner !== execFileSync;
  const outputs = collectRawApkToolOutputs({ repoRoot, apkPath, runner, allowSymbolicTools });
  return auditActualRescueApkOutputs({ ...outputs, expectedVersionCode });
}
