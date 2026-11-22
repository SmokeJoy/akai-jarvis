#!/usr/bin/env python3
"""Source-contract checks for P1 DTV/HDMI Android TIF fix and P2 Accessibility telemetry."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SRC_JAVA = ROOT / "akai-remote-tv/app/src/main/java/it/akai/customremote"
SAFE_SCRIPT = ROOT / "akai-remote-tests/05_safe_install_and_rollback.ps1"


class TvInputTifContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tv_controller = (SRC_JAVA / "TvController.java").read_text(encoding="utf-8")
        cls.policy = (SRC_JAVA / "TvInputIntentPolicy.java").read_text(encoding="utf-8")
        cls.router = (SRC_JAVA / "RestApiRouter.java").read_text(encoding="utf-8")
        cls.service = (SRC_JAVA / "RemoteServerService.java").read_text(encoding="utf-8")
        cls.main_activity = (SRC_JAVA / "MainActivity.java").read_text(encoding="utf-8")
        cls.acc_service = (SRC_JAVA / "AkaiAccessibilityService.java").read_text(encoding="utf-8")
        cls.perception = (SRC_JAVA / "ai/ScreenPerceptionEngine.java").read_text(encoding="utf-8")
        cls.ai_ctrl = (SRC_JAVA / "ai/AkaiAiController.java").read_text(encoding="utf-8")
        cls.verifier = (SRC_JAVA / "ai/GoalEvidenceVerifier.java").read_text(encoding="utf-8")
        cls.parser = (SRC_JAVA / "ai/LocalIntentParser.java").read_text(encoding="utf-8")
        cls.safe_ps1 = SAFE_SCRIPT.read_text(encoding="utf-8")

    def test_tv_controller_uses_tif_policy_and_zero_mtk_broadcasts(self):
        self.assertIn("TvInputIntentPolicy", self.tv_controller)
        self.assertIn("TvInputManager", self.tv_controller)
        self.assertIn("resolveActivity", self.tv_controller)
        self.assertIn("TIF_CHANNEL_MIME_TYPE", self.tv_controller)
        self.assertIn('executeTvInputAction("input_tv"', self.tv_controller)
        self.assertNotIn("com.mediatek.select", self.tv_controller)
        self.assertNotIn("sendMediaTekBroadcast", self.tv_controller)
        self.assertNotIn("launchTvInputUri", self.tv_controller)
        self.assertIn("TurnkeyUiMainActivity", self.policy)
        self.assertIn("content://android.media.tv/passthrough/", self.policy)

    def test_goal_verification_and_parser_cover_tv_inputs_and_oem_anr(self):
        self.assertIn('com.mediatek.wwtv.tvcenter', self.parser)
        self.assertIn('"input_source"', self.parser)
        self.assertIn("detectOemDialogAnomaly", self.verifier)
        self.assertIn("isTvCenterPackage", self.verifier)
        self.assertIn("hasPositiveDtvEvidence", self.verifier)
        self.assertIn("isInputsPanelActivity", self.verifier)
        self.assertIn("hasPositiveHdmiPortEvidence", self.verifier)
        self.assertIn("MAX_TV_INPUT_EVIDENCE_AGE_MS", self.verifier)
        self.assertIn("TYPE_WINDOW_STATE_CHANGED", self.acc_service)
        self.assertIn("getLastWindowClass", self.acc_service)
        self.assertIn("getLastWindowPackage", self.acc_service)
        self.assertIn("foregroundActivity", self.perception)
        self.assertIn("foregroundActivityTimestamp", self.perception)
        self.assertIn("getLastWindowEventAtMs", self.acc_service)
        self.assertIn("observedFinalStateOnly", self.verifier)
        self.assertIn("checkActivityEventFreshness", self.verifier)
        self.assertIn("needs_visual_confirmation", self.ai_ctrl)
        self.assertIn("observed_final_state_only", self.ai_ctrl)
        self.assertIn('"tv_input"', self.verifier)
        self.assertIn('"oem_dialog"', self.verifier)

    def test_status_telemetry_and_main_activity_report_accessibility_read_only(self):
        self.assertIn("isAccessibilityActive", self.router)
        self.assertIn('"accessibility_active"', self.router)
        self.assertIn("isAccessibilityActive", self.service)
        self.assertIn("AkaiAccessibilityService.getInstance()", self.service)
        self.assertIn("AkaiAccessibilityService.getInstance()", self.main_activity)
        self.assertIn("Accessibilit", self.main_activity)

    def test_safe_install_script_has_read_only_accessibility_check_and_no_settings_put(self):
        self.assertIn("Get-DeviceAccessibilityServiceStatus", self.safe_ps1)
        self.assertIn("Write-PostUpgradeAccessibilityAdvisory", self.safe_ps1)
        self.assertIn("settings get secure enabled_accessibility_services", self.safe_ps1)
        self.assertIsNone(
            re.search(r"settings\s+put\s+", self.safe_ps1, flags=re.IGNORECASE),
            "05_safe_install_and_rollback.ps1 must NEVER write Accessibility via ADB settings put!",
        )


if __name__ == "__main__":
    unittest.main()
