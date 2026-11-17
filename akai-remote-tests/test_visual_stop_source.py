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

    def test_session_duration_uses_monotonic_clock(self):
        source = SOURCE.read_text(encoding="utf-8")
        self.assertIn("import android.os.SystemClock;", source)
        self.assertRegex(source, r"VisualCaptureSessionGate\.begin\(\s*true, true, targetProvider, SystemClock\.elapsedRealtime\(\)\)")
        self.assertRegex(source, r"gate\.reserveNextFrame\(\s*expectedProvider, cloudConsent, sensitive, false, SystemClock\.elapsedRealtime\(\)\)")
        # Wall-clock jumps must not extend or prematurely expire the consented session.
        self.assertNotRegex(source, r"(?:VisualCaptureSessionGate\.begin|gate\.reserveNextFrame)\([^;]*System\.currentTimeMillis\(\)")

if __name__ == "__main__":
    unittest.main()
