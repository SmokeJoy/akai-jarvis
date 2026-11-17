"""Host source-contract regression: STOP must work before active publication."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "akai-remote-tv/app/src/main/java/it/akai/customremote/VisualProjectionService.java"

class VisualStopSourceTest(unittest.TestCase):
    def test_stop_during_startup_is_enqueued(self):
        source = SOURCE.read_text(encoding="utf-8")
        match = re.search(r"public static void stopOwnerSession\(Context ctx\)\s*\{(.*?)\n    \}", source, re.S)
        self.assertIsNotNone(match)
        body = match.group(1)
        self.assertIn("ACTION_STOP", body)
        self.assertIn("ctx.startService(stop)", body)
        self.assertNotRegex(body, r"if\s*\(\s*(?:active|s)\s*==\s*null\s*\)\s*return")

if __name__ == "__main__":
    unittest.main()
