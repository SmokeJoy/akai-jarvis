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

    def test_projection_revocation_blocks_publication_and_frame_delivery(self):
        source = SOURCE.read_text(encoding="utf-8")
        self.assertIn("private volatile boolean projectionRevoked;", source)
        callback = source[source.index("@Override public void onStop()"):source.index("}, worker);", source.index("@Override public void onStop()"))]
        self.assertLess(callback.index("projectionRevoked = true;"), callback.index("handler.post("))
        self.assertIn("if (closed || projectionRevoked) throw new IllegalStateException(\"Projection revoked during startup\")", source)
        self.assertIn("if (closed || projectionRevoked) throw new IllegalStateException(\"Projection revoked before session install\")", source)
        self.assertIn("if (closed || projectionRevoked) return;", source)
        self.assertIn("service.projectionRevoked", source)

    def test_vision_upload_requires_live_session_and_monotonic_wait(self):
        # Source-contract test: hardware cancellation races still require a
        # separately approved Android 9 integration test.
        coordinator = (ROOT / "akai-remote-tv/app/src/main/java/it/akai/customremote/ai/"
                       "VisionSessionCoordinator.java").read_text(encoding="utf-8")
        self.assertIn("import android.os.SystemClock;", coordinator)
        self.assertIn("long begun = SystemClock.elapsedRealtime();", coordinator)
        self.assertIn("while (SystemClock.elapsedRealtime() - begun < FRAME_WAIT_MS)", coordinator)
        self.assertNotIn("System.currentTimeMillis()", coordinator)
        start = coordinator.index("if (!selectedProvider.equals(frame.provider)")
        upload = coordinator.index("AiProviderAdapter.VisionCloudResult described = adapter.describeScreenJpegOnce(", start)
        guard = coordinator[start:upload]
        self.assertIn("!VisualObservationProvider.active()", guard)
        self.assertIn("!VisualProjectionService.isSessionActive()", guard)
        self.assertIn("!adapter.hasCloudContextConsent()", guard)
        self.assertIn("cancel != null && cancel.isCancelled()", guard)
        self.assertIn('Observation.denied("SESSION_REVOKED_BEFORE_UPLOAD")', guard)

    def test_visual_goal_deadline_is_monotonic(self):
        controller = (ROOT / "akai-remote-tv/app/src/main/java/it/akai/customremote/ai/"
                      "AkaiAiController.java").read_text(encoding="utf-8")
        begin = controller.index("private JSONObject processVisualGoalLocked(")
        end = controller.index("private String buildReflectorContext(", begin)
        visual = controller[begin:end]
        self.assertIn("final long visualGoalStartedNs = System.nanoTime();", visual)
        self.assertIn("VisualStepPolicy.mayContinueElapsed(attempt, cloudCalls,", visual)
        self.assertIn("System.nanoTime() - visualGoalStartedNs", visual)
        self.assertNotIn("VisualStepPolicy.mayContinue(attempt, cloudCalls, startTime,", visual)

    def test_owner_stop_blocks_planning_action_and_skill_learning(self):
        controller = (ROOT / "akai-remote-tv/app/src/main/java/it/akai/customremote/ai/"
                      "AkaiAiController.java").read_text(encoding="utf-8")
        begin = controller.index("private JSONObject processVisualGoalLocked(")
        end = controller.index("private String buildReflectorContext(", begin)
        visual = controller[begin:end]
        plan = visual.index("AiProviderAdapter.AiResponse plan = aiAdapter.planActionSequence(")
        before_plan = visual[visual.index("JSONObject prefs = memoryEngine.getAllPreferences();"):plan]
        self.assertIn("!VisualObservationProvider.active()", before_plan)
        self.assertIn("!aiAdapter.hasCloudContextConsent()", before_plan)
        after_plan = visual[visual.index("costEur += plan.costEur;"):visual.index("if (!plan.success)", plan)]
        self.assertIn("!VisualObservationProvider.active()", after_plan)
        self.assertIn("!aiAdapter.hasCloudContextConsent()", after_plan)
        before_action = visual[visual.index("JSONArray single = new JSONArray()"):visual.index("StepwiseResult step = executeActionsStepwise(")]
        self.assertIn("!VisualObservationProvider.active()", before_action)
        before_learning = visual[visual.index("if (verified && !cancelled"):visual.index("memoryEngine.saveVerifiedProcedure(")]
        self.assertIn("!isTokenCancelled(token)", before_learning)
        self.assertIn("VisualObservationProvider.active()", before_learning)
        self.assertIn("aiAdapter.hasCloudContextConsent()", before_learning)

    def test_vision_coordinator_checks_interrupt_and_post_upload_revocation(self):
        coordinator = (ROOT / "akai-remote-tv/app/src/main/java/it/akai/customremote/ai/"
                       "VisionSessionCoordinator.java").read_text(encoding="utf-8")
        self.assertIn("Thread.currentThread().isInterrupted()", coordinator)
        after_upload = coordinator[coordinator.index("if (!described.success)"):]
        self.assertIn("!VisualObservationProvider.active()", after_upload)
        self.assertIn("!VisualProjectionService.isSessionActive()", after_upload)
        self.assertIn("!adapter.hasCloudContextConsent()", after_upload)
        self.assertIn('Observation.denied("SESSION_REVOKED_DURING_OBSERVATION")', after_upload)

    def test_reflector_visual_retry_uses_bridge_and_blocks_sensitive_screen(self):
        controller = (ROOT / "akai-remote-tv/app/src/main/java/it/akai/customremote/ai/"
                      "AkaiAiController.java").read_text(encoding="utf-8")
        start = controller.index("String reflectorContext = buildReflectorContext(")
        end = controller.index("if (stepExec.cancelled || isTokenCancelled(myToken))", start)
        reflector = controller[start:end]
        self.assertIn("VisualObservationBridge.publish(", reflector)
        self.assertIn("VisualObservationBridge.consume(", reflector)
        self.assertIn("VisualObservationBridge.clear()", reflector)
        self.assertNotIn('wrapper.put("untrusted_visual_description", retryImage.description)', reflector)
        self.assertIn("abortedForPrivacy", reflector)
        self.assertIn('"PRIVACY_BLOCKED"', reflector)
        self.assertIn("VisualStepPolicy.isCancellationOrRevocationReason(", reflector)

if __name__ == "__main__":
    unittest.main()
