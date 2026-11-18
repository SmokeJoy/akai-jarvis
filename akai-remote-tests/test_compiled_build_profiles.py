#!/usr/bin/env python3
"""Fail-closed AAPT2 compiled-manifest tests for the owner's two release stages.

No TV, ADB, signing key, cloud API or distributable APK. This tool creates two
unsigned resource-only APKs in a temporary directory and inspects their *real*
compiled AndroidManifest.xml. Use CI after resources have been compiled.

Official semantics: https://developer.android.com/tools/aapt2
"""
from __future__ import annotations

import argparse
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

PACKAGE = "it.akai.customremote"
DEBUG_ATTR = re.compile(
    r"(?m)^\s*A:\s+(?:android:|http://schemas\.android\.com/apk/res/android:)"
    r"debuggable\(0x0101000f\)="
    r"(?:(?:\(type 0x12\)(0x[0-9a-fA-F]+))|(true|false))(?=\s|$)"
)

PACKAGE_LINE = re.compile(
    r"(?m)^package:\s+name='([^']+)'\s+versionCode='([0-9]+)'\s+versionName='([^']+)'(?:\s|$)"
)


def compiled_debug_value(xml_tree: str) -> bool:
    """Return compiled debuggable value; reject ambiguity/unknown values."""
    values = DEBUG_ATTR.findall(xml_tree)
    # Unrecognized textual variants are UNKNOWN, not equivalent to absent.
    if "android:debuggable" in xml_tree and len(values) != 1:
        observed_lines = [line.strip() for line in xml_tree.splitlines() if "debuggable" in line or "E: application" in line]
        raise ValueError(f"debuggable attribute absent from parser or ambiguous; observed={observed_lines[:5]!r}")
    if len(values) > 1:
        raise ValueError("duplicate debuggable attributes")
    if not values:
        return False  # Android's documented default
    encoded_hex, literal_boolean = values[0]
    if literal_boolean:
        return literal_boolean == "true"
    parsed = int(encoded_hex, 16)
    if parsed not in (0, 1, 0xFFFFFFFF):
        raise ValueError("non-boolean debuggable value")
    return parsed != 0


def check_badging(text: str, version: int, name: str) -> None:
    matches = PACKAGE_LINE.findall(text)
    if len(matches) != 1 or matches[0] != (PACKAGE, str(version), name):
        raise ValueError("APK package/version metadata missing, invalid or ambiguous")
    if not re.search(r"(?m)^sdkVersion:'21'\s*$", text):
        raise ValueError("wrong or missing min SDK")
    if not re.search(r"(?m)^targetSdkVersion:'28'\s*$", text):
        raise ValueError("wrong or missing target SDK")


def require_version_override(manifest_source: str, windows_builder: str, ci_test_source: str) -> None:
    # --version-code and --version-name inject only when attributes are absent.
    # A2 declares v3 explicitly, so v4/v5 must use --replace-version.
    if 'android:versionCode="3"' not in manifest_source:
        raise ValueError("A2 versionCode baseline changed: review upgrade policy")
    if 'android:versionName="1.2.0-a2-preview"' not in manifest_source:
        raise ValueError("A2 versionName baseline changed: review upgrade policy")
    if not re.search(r"(?m)^\s*\$linkArgs = @\(.*?'--replace-version'\)", windows_builder):
        raise ValueError("Owner builder missing version override")
    if not re.search(r'(?m)^\s*"--replace-version",\s*$', ci_test_source):
        raise ValueError("CI profile compiler missing version override")


class ParserNegativeTests(unittest.TestCase):
    def test_existing_a2_version_overridden_in_both_builds(self):
        root = Path(__file__).resolve().parents[1]
        manifest = (root / "akai-remote-tv/app/src/main/AndroidManifest.xml").read_text(encoding="utf-8")
        builder = (root / "scripts/12_build_jarvis_final_candidate.ps1").read_text(encoding="utf-8-sig")
        ci_source = Path(__file__).read_text(encoding="utf-8")
        require_version_override(manifest, builder, ci_source)

    def test_missing_replace_version_fails_closed(self):
        root = Path(__file__).resolve().parents[1]
        manifest = (root / "akai-remote-tv/app/src/main/AndroidManifest.xml").read_text(encoding="utf-8")
        builder = (root / "scripts/12_build_jarvis_final_candidate.ps1").read_text(encoding="utf-8-sig")
        ci_source = Path(__file__).read_text(encoding="utf-8")
        self.assertIn("'--replace-version'", builder)
        with self.assertRaises(ValueError):
            require_version_override(manifest, builder.replace("'--replace-version'", ""), ci_source)
        self.assertIn('"--replace-version",', ci_source)
        with self.assertRaises(ValueError):
            require_version_override(manifest, builder, ci_source.replace('"--replace-version",', '"--keep-old-version",'))


    def test_android_true_encodings(self):
        for value in ("0x1", "0xffffffff"):
            with self.subTest(value=value):
                self.assertTrue(compiled_debug_value(
                    f"E: application (line=1)\n    A: android:debuggable(0x0101000f)=(type 0x12){value}\n"
                ))

    def test_modern_aapt2_xmltree_boolean_encodings(self):
        # Android build-tools 37 prints a full namespace and symbolic bool.
        self.assertTrue(compiled_debug_value(
            "E: application (line=33)\n"
            " A: http://schemas.android.com/apk/res/android:debuggable(0x0101000f)=true\n"
        ))
        self.assertFalse(compiled_debug_value(
            "E: application (line=33)\n"
            " A: http://schemas.android.com/apk/res/android:debuggable(0x0101000f)=false\n"
        ))
        with self.assertRaises(ValueError):
            compiled_debug_value(
                "E: application\n A: http://schemas.android.com/apk/res/android:debuggable(0x0101000f)=garbage\n"
            )

    def test_false_and_absent(self):
        self.assertFalse(compiled_debug_value(
            "E: application (line=1)\n    A: android:debuggable(0x0101000f)=(type 0x12)0x0\n"))
        self.assertFalse(compiled_debug_value("E: application (line=1)\n"))

    def test_malformed_values_are_not_silent_false(self):
        for value in ("0x2", "garbage", "(type 0x10)0x1"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                compiled_debug_value(
                    "E: application\n A: android:debuggable(0x0101000f)=" + value + "\n"
                )

    def test_duplicate_flag_rejected(self):
        with self.assertRaises(ValueError):
            compiled_debug_value(
                "E: application\n A: android:debuggable(0x0101000f)=(type 0x12)0x1\n"
                " A: android:debuggable(0x0101000f)=(type 0x12)0x0\n"
            )

    def test_metadata_negative_cases(self):
        valid = ("package: name='it.akai.customremote' versionCode='4' "
                 "versionName='1.3.0-diagnostic-rc1'\n"
                 "sdkVersion:'21'\ntargetSdkVersion:'28'\n")
        check_badging(valid, 4, "1.3.0-diagnostic-rc1")
        for broken in (
            valid.replace("it.akai.customremote", "untrusted.package"),
            valid.replace("versionCode='4'", "versionCode='3'"),
            valid.replace("sdkVersion:'21'", "sdkVersion:'29'"),
            valid.replace("targetSdkVersion:'28'", "targetSdkVersion:'35'"),
            valid + valid.splitlines()[0] + "\n",
            "package: name='it.akai.customremote'",
        ):
            with self.subTest(text=broken[:65]), self.assertRaises(ValueError):
                check_badging(broken, 4, "1.3.0-diagnostic-rc1")


def checked(argv: list[str]) -> str:
    try:
        process = subprocess.run(argv, text=True, capture_output=True, timeout=90, check=False)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"timeout: {argv[1]}") from error
    if process.returncode:
        raise RuntimeError(
            f"command failed ({argv[1]}), exit {process.returncode}: "
            + (process.stderr + process.stdout)[-1500:]
        )
    return process.stdout


def build_and_check(aapt2: Path, android_jar: Path, compiled: Path,
                    manifest: Path, out_dir: Path, *,
                    profile: str, version: int, version_name: str) -> None:
    apk = out_dir / (profile + ".apk")
    argv = [
        str(aapt2), "link", "-I", str(android_jar),
        "--manifest", str(manifest), "-o", str(apk),
        str(compiled), "--auto-add-overlay",
        "--min-sdk-version", "21", "--target-sdk-version", "28",
        "--version-code", str(version), "--version-name", version_name,
        # Manifest source explicitly contains A2 v3; without this AAPT2 keeps it.
        "--replace-version",
    ]
    if profile == "Diagnostic":
        argv.append("--debug-mode")
    elif profile != "Release":
        raise ValueError("unknown build profile")
    checked(argv)
    if not apk.is_file() or not apk.stat().st_size:
        raise RuntimeError(f"missing compiled APK for {profile}")
    tree = checked([str(aapt2), "dump", "xmltree", str(apk), "--file", "AndroidManifest.xml"])
    observed = compiled_debug_value(tree)
    expected = profile == "Diagnostic"
    if observed != expected:
        raise RuntimeError(f"{profile} compiled debuggable={observed}; expected {expected}")
    badging = checked([str(aapt2), "dump", "badging", str(apk)])
    check_badging(badging, version, version_name)
    print(f"[PASS] {profile} v{version}: actual compiled debuggable={observed}, "
          "package, SDK and version verified; unsigned CI-only APK.", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--aapt2", type=Path)
    parser.add_argument("--android-jar", type=Path)
    parser.add_argument("--compiled-res", type=Path)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--self-test-only", action="store_true")
    args = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(ParserNegativeTests)
    )
    if not result.wasSuccessful():
        return 1
    if args.self_test_only:
        print("[PASS] parser negative tests only; compiled APK tests NOT RUN.")
        return 0
    paths = (args.aapt2, args.android_jar, args.compiled_res, args.manifest)
    if any(value is None or not value.is_file() for value in paths):
        parser.error("all four existing Android tooling/source files are required")
    with tempfile.TemporaryDirectory(prefix="jarvis_profiles_") as directory:
        try:
            build_and_check(*paths, Path(directory),
                            profile="Diagnostic", version=4,
                            version_name="1.3.0-diagnostic-rc1")
            build_and_check(*paths, Path(directory),
                            profile="Release", version=5,
                            version_name="1.3.0-final")
        except (RuntimeError, ValueError, OSError) as exc:
            print(f"[NO-GO] Compiled profiles not verified: {exc}", file=sys.stderr)
            return 1
    print("[PASS] Both compiled profile manifests verified. No signing / TV deployment.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
