#!/usr/bin/env python3
"""Source-contract checks for owner-confirmed Android 9 OTA UI wiring.

Proves MainActivity wires OtaUpdatePreparation -> OtaAndroidInstallPreflight ->
two-checkbox AlertDialog -> OtaOwnerPackageInstaller only on physical TV input,
while REST API, AI controller, BootReceiver, and Manifest stay fail-closed.
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SRC = ROOT / "akai-remote-tv/app/src/main"
JAVA = SRC / "java/it/akai/customremote"


class OtaOwnerUiWiringTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.main_activity = (JAVA / "MainActivity.java").read_text(encoding="utf-8")
        cls.layout = (SRC / "res/layout/activity_main.xml").read_text(encoding="utf-8")
        cls.manifest = (SRC / "AndroidManifest.xml").read_text(encoding="utf-8")
        cls.installer = (JAVA / "ai/OtaOwnerPackageInstaller.java").read_text(encoding="utf-8")
        cls.receiver = (JAVA / "OtaInstallResultReceiver.java").read_text(encoding="utf-8")
        cls.router = (JAVA / "RestApiRouter.java").read_text(encoding="utf-8")
        cls.service = (JAVA / "RemoteServerService.java").read_text(encoding="utf-8")
        cls.boot = (JAVA / "BootReceiver.java").read_text(encoding="utf-8")
        cls.ai = (JAVA / "ai/AkaiAiController.java").read_text(encoding="utf-8")

    def test_layout_has_hidden_focusable_owner_ota_controls(self):
        self.assertIn('android:id="@+id/btn_ota_check"', self.layout)
        self.assertIn('android:id="@+id/tv_ota_status"', self.layout)
        self.assertIn('android:id="@+id/btn_ota_permission"', self.layout)
        self.assertIn('android:id="@+id/btn_ota_install_confirmed"', self.layout)
        for btn_id in ('btn_ota_permission', 'btn_ota_install_confirmed'):
            block = self.layout.split(btn_id, 1)[1].split('/>', 1)[0]
            self.assertIn('android:focusable="true"', block)
            self.assertIn('android:enabled="false"', block)
            self.assertIn('android:visibility="gone"', block)

    def test_btn_ota_check_never_invokes_package_installer_directly(self):
        check_block = self.main_activity.split('btnOtaCheck.setOnClickListener', 1)[1]
        check_block = check_block.split('btnOtaPermission.setOnClickListener', 1)[0]
        self.assertIn('OtaUpdatePreparation.prepare(', check_block)
        self.assertIn('OtaAndroidInstallPreflight.inspect(', check_block)
        self.assertNotIn('OtaOwnerPackageInstaller', check_block)
        self.assertNotIn('submitAfterPhysicalOwnerApproval', check_block)

    def test_two_checkbox_dialog_and_permission_intent_guards(self):
        self.assertIn('Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES', self.main_activity)
        self.assertIn('ActivityNotFoundException', self.main_activity)
        self.assertIn('ANDROID_UNKNOWN_SOURCE_PERMISSION_REQUIRED', self.main_activity)
        self.assertIn('OtaInstallResultReceiver.lastResult(this)', self.main_activity)

        dialog_fn = self.main_activity.split('openOtaOwnerConfirmDialog(', 1)[1]
        self.assertGreaterEqual(dialog_fn.count('new CheckBox('), 2)
        self.assertEqual(dialog_fn.count('.setChecked(false)'), 2)
        self.assertIn('positive.setEnabled(false)', dialog_fn)
        self.assertIn('chkBackup.isChecked() && chkRecovery.isChecked()', dialog_fn)
        self.assertIn('OtaOwnerPackageInstaller.submitAfterPhysicalOwnerApproval(', dialog_fn)
        self.assertIn('OtaOwnerPackageInstaller.Outcome', dialog_fn)

    def test_no_remote_ai_or_boot_caller_can_invoke_ota_installer(self):
        for forbidden_caller in (self.router, self.service, self.boot, self.ai):
            self.assertNotIn('OtaOwnerPackageInstaller', forbidden_caller)
            self.assertNotIn('submitAfterPhysicalOwnerApproval', forbidden_caller)
            self.assertNotIn('OtaUpdatePreparation', forbidden_caller)

    def test_manifest_and_receiver_remain_non_exported_no_silent_install(self):
        self.assertNotIn('android.permission.INSTALL_PACKAGES', self.manifest)
        self.assertIn('android.permission.REQUEST_INSTALL_PACKAGES', self.manifest)
        rx_tag = self.manifest.split('android:name=".OtaInstallResultReceiver"', 1)[1].split('/>', 1)[0]
        self.assertIn('android:exported="false"', rx_tag)
        self.assertIn('EXTRA_EXPECTED_SESSION_ID', self.receiver)
        self.assertIn('STATUS_PENDING_USER_ACTION', self.receiver)
        self.assertIn('OtaInstallReadinessGate.evaluate(', self.installer)


if __name__ == "__main__":
    unittest.main()
