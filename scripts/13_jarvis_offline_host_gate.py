#!/usr/bin/env python3
"""JARVIS strict OFFLINE host checks; does not build/sign/install an APK.

This runner is a local alternative while GitHub-hosted CI has no assigned
runner. It NEVER invokes ADB, connects to the TV, reads signing keys, uses a
cloud AI provider or claims that Android hardware was tested. It does NOT
replace the CI Android APK/ARMv7 build and mocked rollback suite.
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

PURE_PYTHON = (
    "akai-remote-tests/test_visual_stop_source.py",
    "akai-remote-tests/test_android_jni_ci_contract.py",
    "akai-remote-tests/test_backup_memory_transport_policy.py",
    "akai-remote-tests/test_visual_projection_request_serialization.py",
    "akai-remote-tests/test_visual_projection_idle_surface.py",
    "akai-remote-tests/test_free_italian_voice_source.py",
    "akai-remote-tests/test_speech_owner_policy.py",
    "akai-remote-tests/test_sqlite_memory.py",
    "akai-remote-tests/test_agent_sqlite_a0.py",
    "akai-remote-tests/test_rollback_offline_simulation.py",
)

PURE_NODE = (
    ("syntax", "akai-remote-web/app.js"),
    ("syntax", "akai-remote-web/sw.js"),
    ("test", "akai-remote-tests/test_web_ai_feedback.js"),
    ("test", "akai-remote-tests/test_web_local_italian_voice.js"),
)

JAVA_MOCK_DIRS = (
    "akai-remote-tests/host_mock/android/content",
    "akai-remote-tests/host_mock/android/content/pm",
    "akai-remote-tests/host_mock/android/graphics",
    "akai-remote-tests/host_mock/android/media",
    "akai-remote-tests/host_mock/android/security/keystore",
    "akai-remote-tests/host_mock/android/util",
    "akai-remote-tests/host_mock/android/view/accessibility",
    "akai-remote-tests/host_mock/org/json",
    "akai-remote-tests/host_mock/it/akai/customremote",
    "akai-remote-tests/host_mock/it/akai/customremote/ai",
    "akai-remote-tv/app/src/main/java/it/akai/customremote/qr",
)

JAVA_MAIN = (
    "ServiceStateListener", "HttpsRebindController", "SecurityManager",
    "UInputDriver", "CommandResult", "TvAppPackages", "TlsCertificateManager",
    "RestApiRouter",
)

JAVA_AI = (
    "LocalIntentParser", "AgentSkillGate", "AgentFactMemory",
    "KeystoreSecurityHelper", "CloudProviderPolicy",
    "CloudVisionRequestPolicy", "FreeItalianTtsPolicy",
    "VisualObservationBridge", "VisualCaptureSessionGate",
    "FrameSequenceGate", "ProcedureGoalMatcher",
    "VisualObservationProvider", "VisualStepPolicy",
    "AiProviderAdapter", "ScreenPerceptionEngine",
    "GoalEvidenceVerifier", "UiClickTargetGate", "VisionCapturePolicy",
    "RgbaFramePacker", "AkaiAiController",
)

JAVA_TESTS = (
    "akai-remote-tests/UnitTests.java",
    "akai-remote-tests/AgentSkillGateTest.java",
    "akai-remote-tests/AgentFactMemoryTest.java",
)

JAVA_TEST_CLASSES = (
    "it.akai.customremote.UnitTests",
    "it.akai.customremote.AgentSkillGateTest",
    "it.akai.customremote.AgentFactMemoryTest",
)


def assert_release_contract() -> None:
    builder_path = ROOT / "scripts/12_build_jarvis_final_candidate.ps1"
    installer_path = ROOT / "akai-remote-tests/05_safe_install_and_rollback.ps1"
    manifest_path = ROOT / "akai-remote-tv/app/src/main/AndroidManifest.xml"
    for path in (builder_path, installer_path, manifest_path):
        if not path.is_file():
            raise AssertionError(f"Missing critical source: {path.relative_to(ROOT)}")
    builder = builder_path.read_text(encoding="utf-8-sig")
    installer = installer_path.read_text(encoding="utf-8-sig")
    manifest = manifest_path.read_text(encoding="utf-8-sig")
    required_builder = (
        "[string]$BuildProfile", "[int]$VersionCode = 4",
        "$BuildProfile -eq 'Diagnostic'", "$VersionCode -ne 4",
        "$BuildProfile -eq 'Release'", "$VersionCode -lt 5",
        "$VersionName -match '(?i)(diagnostic|debug)'",
        "$VersionName -notmatch '(?i)diagnostic'",
        "$linkArgs += '--debug-mode'", "'--replace-version'", "$compiledDebugTrue",
        "$compiledDebugFalse", "DIAGNOSTIC FAIL-CLOSED",
        "RELEASE FAIL-CLOSED", "ExpectedCiHeadSha",
        "JARVIS_SIGNING_STOREPASS", "JARVIS_SIGNING_KEYPASS",
        "FIRMA DIVERSA DA TV", "apksigner",
        "buildProfile = $BuildProfile",
    )
    for needle in required_builder:
        if needle not in builder:
            raise AssertionError(f"Builder safety contract missing: {needle}")
    if not re.search(r"debuggable\s*=\s*\(\$BuildProfile\s+-eq\s+'Diagnostic'\)", builder):
        raise AssertionError("Builder manifest must report debug profile exactly")
    if re.search(r"(?i)\badb(?:\.exe)?\s+(?:install|push|pull|root|shell|connect)\b", builder):
        raise AssertionError("Builder must never touch a physical TV")
    if not re.search(r'android:debuggable="false"', manifest):
        raise AssertionError("Canonical production manifest must stay non-debuggable")
    installer_requirements = (
        "function Test-PackageUpgradeGate", "aapt dump badging obbligatorio",
        "metadata package/versionCode assenti o ambigui",
        "versionCode installato assente o ambiguo",
        "$candidateVersionCode -le $installedVersionCode",
        "Get-ApkCertificateFingerprint", "Backup-DeviceTlsIdentity",
        "-AllowHardwareExecution",
    )
    for needle in installer_requirements:
        if needle not in installer:
            raise AssertionError(f"Installer safety contract missing: {needle}")


def check_required_tools() -> tuple[str, str, str]:
    python = sys.executable
    node = shutil.which("node")
    java = shutil.which("java")
    javac = shutil.which("javac")
    missing = [name for name, value in (("Node.js", node), ("java", java), ("javac", javac)) if not value]
    if missing:
        raise RuntimeError("Missing mandatory local host test tools: " + ", ".join(missing))
    return python, node or "", javac or ""


def run_checked(label: str, command: list[str], timeout: int = 180) -> None:
    # Hard whitelist to prevent accidental use of connected-TV tools.
    executable = Path(command[0]).name.lower()
    permitted = {"python", "python3", "python.exe", "python3.exe",
                 "node", "node.exe", "java", "java.exe", "javac", "javac.exe"}
    if executable not in permitted and not re.fullmatch(r"python3?\.\d+(?:\.exe)?", executable):
        raise RuntimeError(f"Unexpected executable in offline gate: {command[0]}")
    print(f"[RUN] {label}", flush=True)
    try:
        result = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, errors="replace",
                                timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"{label}: timed out after {timeout} seconds") from None
    if result.returncode != 0:
        print(result.stdout[-6000:], flush=True)
        raise RuntimeError(f"{label}: FAILED with exit code {result.returncode}")
    print(f"[PASS] {label}", flush=True)


def compile_java_host(javac: str, out_dir: Path) -> None:
    all_files: list[str] = []
    for directory in JAVA_MOCK_DIRS:
        folder = ROOT / directory
        if not folder.is_dir():
            raise RuntimeError(f"Missing Java mock directory: {directory}")
        all_files.extend(str(p) for p in sorted(folder.glob("*.java")))
    main_root = ROOT / "akai-remote-tv/app/src/main/java/it/akai/customremote"
    ai_root = main_root / "ai"
    all_files += [str(main_root / f"{name}.java") for name in JAVA_MAIN]
    all_files += [str(ai_root / f"{name}.java") for name in JAVA_AI]
    all_files += [str(ROOT / name) for name in JAVA_TESTS]
    absent = [p for p in all_files if not Path(p).is_file()]
    if absent:
        raise RuntimeError("Missing Java inputs: " + ", ".join(absent[:5]))
    if len(all_files) != len(set(all_files)):
        raise RuntimeError("Duplicate Java source in offline build")
    run_checked("Java host compilation (Android mocks, no SDK/TV)", [javac, "-encoding",
                "UTF-8", "-d", str(out_dir), *all_files], timeout=240)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-java", action="store_true", help="Not allowed in strict release gate")
    args = parser.parse_args()
    if args.no_java:
        print("[BLOCKED] Java tests cannot be skipped in strict mode", file=sys.stderr)
        return 2
    print("JARVIS strict HOST/OFFLINE gate — NO ADB, NO CLOUD API, NO SIGNING, NO TV")
    print("This gate cannot substitute the complete GitHub CI or real Android tests.")
    try:
        assert_release_contract()
        print("[PASS] Static diagnostic-v4 / production-v5 / installer source safety gates")
        python, node, javac = check_required_tools()
        for path in PURE_PYTHON:
            run_checked(f"Python {path}", [python, str(ROOT / path)], timeout=240)
        for mode, path in PURE_NODE:
            node_args = ["--check"] if mode == "syntax" else []
            run_checked(f"Node {path}", [node, *node_args, str(ROOT / path)], timeout=240)
        with tempfile.TemporaryDirectory(prefix="jarvis_host_gate_") as directory:
            out = Path(directory) / "java"
            out.mkdir()
            compile_java_host(javac, out)
            for cls in JAVA_TEST_CLASSES:
                run_checked(f"Java {cls}", [shutil.which("java") or "java", "-cp",
                            str(out), cls], timeout=240)
    except (OSError, AssertionError, RuntimeError) as exc:
        print(f"[NO-GO] HOST VALIDATION FAILED: {exc}", file=sys.stderr, flush=True)
        return 1
    print("[PASS] Offline HOST checks completed. NOT full CI, NOT APK build, NOT TV GO.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
