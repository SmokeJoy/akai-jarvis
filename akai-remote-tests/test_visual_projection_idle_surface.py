"""Host source-contract tests for low-CPU MediaProjection on AKAI Android 9.

The API supports VirtualDisplay.setSurface(null) since API 20. This checks
that JARVIS does NOT continuously render frames while the agent is idle.
These are not a substitute for a real TV/device resource measurement.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "akai-remote-tv/app/src/main/java/it/akai/customremote/VisualProjectionService.java"


class VisualIdleSurfaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SRC.read_text(encoding="utf-8")

    def method(self, start, end):
        s = self.source
        return s[s.index(start):s.index(end, s.index(start))]

    def test_initial_virtual_display_has_no_surface(self):
        startup = self.method('projection.createVirtualDisplay("jarvis-on-demand"', 'if (display == null)')
        self.assertIn('null, null, worker)', startup)
        self.assertNotIn('reader.getSurface(), null, worker)', startup)

    def test_attach_only_for_reserved_request(self):
        request = self.method('private void requestOnWorker(', 'private void consumeOnlyOnDemand(')
        reserve = request.index('gate.reserveNextFrame(')
        pending = request.index('pending = callback;')
        attach = request.index('display.setSurface(reader.getSurface())')
        self.assertLess(reserve, pending)
        self.assertLess(pending, attach)
        self.assertIn('FRAME_SURFACE_ATTACH_FAILED', request)
        self.assertIn('finishRequest(FrameResult.denied("FRAME_SURFACE_ATTACH_FAILED"))', request)

    def test_detach_before_callback_and_cloud_work(self):
        completed = self.method('private void finishRequest(', 'private synchronized void stopCapture(')
        self.assertLess(completed.index('display.setSurface(null)'), completed.index('deliver.onFrame(result)'))
        self.assertIn('gate.completeFrame(result.ok())', completed)

    def test_teardown_serialized_across_main_and_worker(self):
        self.assertIn('private synchronized void stopCapture()', self.source)
        cleanup = self.method('private synchronized void stopCapture()', '@Override public void onDestroy()')
        self.assertLess(cleanup.index('closed = true;'), cleanup.index('display.release()'))
        self.assertLess(cleanup.index('closed = true;'), cleanup.index('reader.close()'))
        self.assertLess(cleanup.index('closed = true;'), cleanup.index('old.stop()'))

    def test_stale_late_frame_drained_without_encoding(self):
        capture = self.method('private void consumeOnlyOnDemand(', 'private static boolean mostlyBlack(')
        self.assertIn('if (pending == null || closed)', capture)
        self.assertIn('source.acquireLatestImage()', capture)
        self.assertIn('if (stale != null) stale.close()', capture)
        idle = capture[capture.index('if (pending == null || closed)'):capture.index('Image image = null;')]
        self.assertNotIn('Bitmap.createBitmap', idle)
        self.assertNotIn('bitmap.compress', idle)


    def test_concurrent_stop_cannot_crash_frame_finally_cleanup(self):
        capture = self.method('private void consumeOnlyOnDemand(', 'private static boolean mostlyBlack(')
        cleanup = capture[capture.index('} finally {', capture.index('Bitmap bitmap = null;')):]
        self.assertRegex(cleanup, r'if \(image != null\) \{\s*try \{ image\.close\(\); \} catch \(RuntimeException ignored\)')
        self.assertRegex(cleanup, r'if \(bitmap != null\) \{\s*try \{ bitmap\.recycle\(\); \} catch \(RuntimeException ignored\)')


if __name__ == "__main__":
    unittest.main()
