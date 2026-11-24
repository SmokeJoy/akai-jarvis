#!/usr/bin/env python3
"""Source-level regressions for Android9 ABI and no-secret APK packaging.

These tests do NOT compile JNI or an APK. They prove only that the current
CI + Windows builder retain the mandatory Android NDK and secret-exclusion
gates. Android builds and real TV checks remain separate requirements.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
CI = ROOT / ".github/workflows/ci.yml"
WIN = ROOT / "scripts/12_build_jarvis_final_candidate.ps1"


def require_native_policy(ci: str, windows: str) -> None:
    if re.search(r"(?m)^\s*(?:sudo\s+)?(?:apt-get\s+install|arm-linux-gnueabihf-gcc)\b", ci):
        raise ValueError("Generic Linux/GNU ARM compiler can introduce glibc into Android JNI")
    requirements = (
        "armv7a-linux-androideabi21-clang",
        'if [ -z "$NDK_CLANG" ] || [ ! -x "$NDK_CLANG" ]; then',
        'NO-GO: Android NDK ARMv7 API21 clang required',
        "libc\\.so\\.6|libgcc_s\\.so|ld-linux|glibc",
        "liblog\\.so",
        "Machine:[[:space:]]*ARM",
        "Class:[[:space:]]*ELF32",
        "NO-GO: Android 9 platform API28 is required",
    )
    for token in requirements:
        if token not in ci:
            raise ValueError("JNI/ABI gate missing: " + token)
    # Shared-library linking should resolve __android_log_print from -llog:
    # for --as-needed linkers the library belongs AFTER the source/object.
    source = "akai-remote-tv/app/src/main/jni/uinput_jni.c"
    if source + " -llog" not in ci:
        raise ValueError("CI must link liblog after the JNI source")
    if '-O2 `"$jniSrc`" -llog' not in windows:
        raise ValueError("Owner Windows NDK must link liblog after the JNI source")


def require_apk_secrets_policy(ci: str) -> None:
    if re.search(r"(?m)^\s*keytool -genkeypair\s+-alias akaiserver\b", ci):
        raise ValueError("CI must not embed a TLS signing key into its APK")
    if re.search(r"(?m)^\s*grep .*assets/server_keystore\.p12", ci):
        raise ValueError("CI must not require a bundled private TLS key")
    for token in (
        "unzip -Z1 build_ci/app-ci-test-nondistributable.apk",
        "NO-GO: APK contains TLS/private signing material",
        "TlsCertificateManager",
    ):
        if token not in ci:
            raise ValueError("Mandatory secret-free packaging gate missing: " + token)


def require_owner_signing_handoff_policy(windows: str) -> None:
    # A successful signing invocation is NOT the same as an owner-approved
    # production release, and a failed invocation must not leave an APK.
    for token in (
        "productionReady = $false",
        "ownerTvApproved = $false",
        "recoveryVerified = $false",
        "productionProfile = ($BuildProfile -eq 'Release')",
    ):
        if token not in windows:
            raise ValueError("Unsigned/unapproved release may be mislabeled: " + token)
    failed = windows.split("if ($LASTEXITCODE -ne 0 -or -not (Test-Path $releaseApk)) {", 1)
    if len(failed) != 2:
        raise ValueError("Signer failure branch missing")
    branch = failed[1].split("# There is only ONE signed candidate", 1)[0]
    for token in (
        "Remove-Item -LiteralPath $releaseApk -Force",
        "throw 'Firma APK finale fallita.",
    ):
        if token not in branch:
            raise ValueError("Partial APK not cleaned after signer failure: " + token)


class NativeAndPackagingSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ci = CI.read_text(encoding="utf-8-sig")
        cls.windows = WIN.read_text(encoding="utf-8-sig")

    def test_ci_rejects_linux_cross_compiler(self):
        require_native_policy(self.ci, self.windows)

    def test_fails_if_glibc_compiler_is_reintroduced(self):
        with self.assertRaises(ValueError):
            require_native_policy(self.ci + "\narm-linux-gnueabihf-gcc -shared x.c\n", self.windows)

    def test_fails_if_android_liblog_link_order_is_reversed(self):
        corrupted = self.ci.replace(
            "akai-remote-tv/app/src/main/jni/uinput_jni.c -llog",
            "-llog akai-remote-tv/app/src/main/jni/uinput_jni.c")
        self.assertNotEqual(corrupted, self.ci)
        with self.assertRaises(ValueError):
            require_native_policy(corrupted, self.windows)

    def test_ci_never_packages_test_tls_private_keys(self):
        require_apk_secrets_policy(self.ci)

    def test_builder_handoff_is_not_automatically_released(self):
        require_owner_signing_handoff_policy(self.windows)

    def test_rejects_false_production_ready(self):
        invalid = self.windows.replace("productionReady = $false",
                                       "productionReady = ($BuildProfile -eq 'Release')")
        self.assertNotEqual(invalid, self.windows)
        with self.assertRaises(ValueError):
            require_owner_signing_handoff_policy(invalid)

    def test_rejects_partially_signed_apk_without_cleanup(self):
        invalid = self.windows.replace("Remove-Item -LiteralPath $releaseApk -Force -ErrorAction SilentlyContinue",
                                       "Write-Host 'Leave partially signed output'")
        self.assertNotEqual(invalid, self.windows)
        with self.assertRaises(ValueError):
            require_owner_signing_handoff_policy(invalid)

    def test_fails_if_ci_embeds_keystore(self):
        with self.assertRaises(ValueError):
            require_apk_secrets_policy(
                self.ci + "\nkeytool -genkeypair -alias akaiserver -keystore build_ci/assets/server_keystore.p12\n"
            )


if __name__ == "__main__":
    unittest.main()
