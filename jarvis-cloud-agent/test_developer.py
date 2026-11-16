import json
from pathlib import Path
import tempfile
import unittest
from developer import DeveloperError, extract_json, main, target_path, validate_change


class DeveloperTests(unittest.TestCase):
    TARGET = "akai-remote-tv/app/src/main/java/it/akai/customremote/ai/SafeSkill.java"

    def test_allowlisted_target(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertTrue(str(target_path(Path(d), self.TARGET)).endswith("SafeSkill.java"))

    def test_protect_remote_and_launcher(self):
        with tempfile.TemporaryDirectory() as d:
            for p in (
                "akai-remote-web/app.js",
                "akai-remote-tv/app/src/main/java/it/akai/customremote/RemoteServerService.java",
                "akai-remote-tv/app/src/main/java/it/akai/customremote/ai/../../RemoteServerService.java",
                "/etc/passwd",
                "akai-remote-tv/app/src/main/java/it/akai/customhome/Launcher.java",
            ):
                with self.subTest(p=p), self.assertRaises(DeveloperError):
                    target_path(Path(d), p)

    def test_reject_multiple_files(self):
        with self.assertRaises(DeveloperError):
            validate_change({"changes": [
                {"path": self.TARGET, "content": "A"},
                {"path": "other", "content": "B"},
            ]}, self.TARGET)

    def test_reject_mismatched_path(self):
        with self.assertRaises(DeveloperError):
            validate_change({"changes": [{"path": "README.md", "content": "bad"}]}, self.TARGET)

    def test_mock_end_to_end_writes_only_target(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            mocked = root / "mock.json"
            mocked.write_text(json.dumps({
                "summary": "Test proposal",
                "changes": [{"path": self.TARGET,
                             "content": "package it.akai.customremote.ai;\npublic class SafeSkill {}\n"}],
            }), encoding="utf-8")
            status = main([
                "--task", "Create safe skill", "--provider", "deepseek",
                "--target", self.TARGET, "--root", str(root), "--mock-json", str(mocked),
            ])
            self.assertEqual(status, 0)
            self.assertIn("public class SafeSkill", (root / self.TARGET).read_text(encoding="utf-8"))

    def test_fenced_json(self):
        fence = chr(96) * 3
        self.assertEqual(extract_json(fence + 'json\n{"changes": []}\n' + fence)["changes"], [])


if __name__ == "__main__":
    unittest.main()
