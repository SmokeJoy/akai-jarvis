"""Cloud Developer safety/authorization tests, without network, GitHub, or API keys."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from developer import (
    DeveloperError, call_provider, main, target_path, validate_change,
)


class SafetyTests(unittest.TestCase):
    TARGET = "akai-remote-tv/app/src/main/java/it/akai/customremote/ai/SafeSkill.java"
    CONTENT = "package it.akai.customremote.ai;\npublic class SafeSkill {}\n"

    def test_core_and_test_sources_cannot_be_modified_by_llm(self):
        with tempfile.TemporaryDirectory() as directory:
            for path in (
                "akai-remote-tests/UnitTests.java",
                "akai-remote-tests/AgentFactMemoryTest.java",
                "akai-remote-tv/app/src/main/java/it/akai/customremote/ai/AkaiMemoryEngine.java",
                "akai-remote-tv/app/src/main/java/it/akai/customremote/ai/AkaiAiController.java",
                "akai-remote-tv/app/src/main/java/it/akai/customremote/ai/AiProviderAdapter.java",
                "akai-remote-tv/app/src/main/java/it/akai/customremote/ai/AgentFactMemory.java",
                "akai-remote-tv/app/src/main/java/it/akai/customremote/ai/AgentSkillGate.java",
            ):
                with self.subTest(path=path), self.assertRaises(DeveloperError):
                    target_path(Path(directory), path)

    def test_generated_source_must_use_exact_package_and_class(self):
        def proposal(source):
            return {"changes": [{"path": self.TARGET, "content": source}]}

        self.assertEqual(validate_change(proposal(self.CONTENT), self.TARGET), self.CONTENT)
        for malformed in (
            "package other;\npublic class SafeSkill {}\n",
            "package it.akai.customremote.ai;\npublic class DifferentSkill {}\n",
            "public class SafeSkill {}\n",
            "package it.akai.customremote.ai;\npackage other;\npublic class SafeSkill {}\n",
        ):
            with self.subTest(content=malformed), self.assertRaises(DeveloperError):
                validate_change(proposal(malformed), self.TARGET)

    def test_paid_call_refused_before_any_external_access(self):
        with patch.dict(os.environ, {"DEEPSEEK_API_KEY": "fake-test-key"}), \
                patch("developer.urllib.request.urlopen") as external:
            with self.assertRaisesRegex(DeveloperError, "owner approval"):
                call_provider("deepseek", "safe skill", self.TARGET, "")
            external.assert_not_called()

    def test_cli_without_owner_approval_has_zero_paid_requests(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.dict(os.environ, {"DEEPSEEK_API_KEY": "fake-test-key"}), \
                patch("developer.urllib.request.urlopen") as external:
            status = main([
                "--task", "safe skill", "--provider", "deepseek",
                "--target", self.TARGET, "--root", directory,
            ])
            self.assertEqual(status, 2)
            external.assert_not_called()
            self.assertFalse((Path(directory) / self.TARGET).exists())

    def test_mock_mode_remains_free_and_local(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch("developer.urllib.request.urlopen") as external:
            p = Path(directory) / "mock.json"
            p.write_text(json.dumps({
                "changes": [{"path": self.TARGET, "content": self.CONTENT}]
            }), encoding="utf-8")
            status = main([
                "--task", "safe skill", "--target", self.TARGET,
                "--root", directory, "--mock-json", str(p),
            ])
            self.assertEqual(status, 0)
            external.assert_not_called()
            self.assertEqual((Path(directory) / self.TARGET).read_text(), self.CONTENT)


if __name__ == "__main__":
    unittest.main()
