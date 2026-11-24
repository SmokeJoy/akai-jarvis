package it.akai.customremote;

import org.json.JSONArray;
import org.json.JSONObject;
import it.akai.customremote.ai.VisualStepPolicy;

public final class VisualStepPolicyTest {
    private static int checks;
    private static void check(boolean yes, String what) {
        checks++;
        if (!yes) throw new AssertionError(what);
    }

    public static void main(String[] args) throws Exception {
        JSONArray proposals = new JSONArray()
                .put(new JSONObject().put("type", "launch_app").put("pkg", "it.mediaset.infinitytv"))
                .put(new JSONObject().put("type", "click_text").put("text", "Diretta"));
        JSONObject one = VisualStepPolicy.firstStep(proposals);
        check(one != null && "launch_app".equals(one.optString("type")), "only first atomic step");
        check(VisualStepPolicy.firstStep(new JSONArray()) == null, "no empty action plan");
        check(VisualStepPolicy.firstStep(null) == null, "no missing plan");
        check(VisualStepPolicy.firstStep(new JSONArray().put(new JSONObject())) == null,
                "step type required");
        check(VisualStepPolicy.mayContinue(0, 0, 100, 100), "initial state allowed");
        check(VisualStepPolicy.mayContinue(VisualStepPolicy.MAX_ACTION_STEPS - 1,
                10, 100, 120), "last step allowed");
        check(!VisualStepPolicy.mayContinue(VisualStepPolicy.MAX_ACTION_STEPS,
                10, 100, 120), "step limit enforced");
        check(!VisualStepPolicy.mayContinue(0,
                VisualStepPolicy.MAX_CLOUD_CALLS, 100, 120), "cloud call limit");
        check(!VisualStepPolicy.mayContinue(0, 0, 100,
                100 + VisualStepPolicy.MAX_GOAL_MS), "timeout");
        check(!VisualStepPolicy.mayContinue(0, 0, 100, 99), "clock rollback");
        check(VisualStepPolicy.mayContinueElapsed(0, 0, 0),
                "monotonic start of goal allowed");
        check(VisualStepPolicy.mayContinueElapsed(7, 15,
                VisualStepPolicy.MAX_GOAL_MS - 1), "last elapsed millisecond allowed");
        check(!VisualStepPolicy.mayContinueElapsed(0, 0,
                VisualStepPolicy.MAX_GOAL_MS), "monotonic deadline enforced");
        check(!VisualStepPolicy.mayContinueElapsed(0, 0, -1L),
                "invalid negative elapsed time denied");
        check(!VisualStepPolicy.mayContinueElapsed(8, 0, 1L),
                "action limit applies to elapsed-only gate");
        check(!VisualStepPolicy.mayContinueElapsed(0, 16, 1L),
                "cloud limit applies to elapsed-only gate");
        check(VisualStepPolicy.repeatedWithoutProgress(
                "dpad_right", "same UI + image", "dpad_right", "same UI + image"),
                "identical action with unchanged screen blocked");
        check(!VisualStepPolicy.repeatedWithoutProgress(
                "dpad_right", "UI1", "dpad_right", "UI2"),
                "new UI state allows another press");
        check(!VisualStepPolicy.repeatedWithoutProgress(
                "dpad_right", "UI1", "dpad_left", "UI1"),
                "different action is different plan");
        for (String transientErr : new String[] {
                "FRAME_RATE_LIMIT", "FRAME_FOREGROUND_CHANGED", "UI_CHANGED_BEFORE_UPLOAD",
                "NO_NEW_FRAME_TIMEOUT", "FRAME_TIMEOUT", "FRAME_REQUEST_BUSY" }) {
            check(VisualStepPolicy.isTransientObservationFailure(transientErr),
                    "transient observation error allowed: " + transientErr);
        }
        for (String terminalErr : new String[] {
                null, "", "UNKNOWN_CODE", "BLACK_OR_DRM_PROTECTED_FRAME",
                "SENSITIVE_OR_UNKNOWN_SCREEN", "NO_CONSENTED_SESSION", "UNSAFE_OBSERVATION_REQUEST",
                "CLOUD_CONSENT_REVOKED", "FRAME_LIMIT_REACHED", "SESSION_EXPIRED",
                "PROVIDER_CHANGED", "SESSION_REVOKED_DURING_OBSERVATION", "TASK_CANCELLED" }) {
            check(!VisualStepPolicy.isTransientObservationFailure(terminalErr),
                    "terminal/security/revocation error never retried: " + terminalErr);
        }
        for (String cancelErr : new String[] {
                "TASK_CANCELLED", "SESSION_REVOKED_DURING_OBSERVATION",
                "SESSION_REVOKED_BEFORE_UPLOAD", "SESSION_STOPPED",
                "SESSION_CLOSED", "CLOUD_CONSENT_REVOKED" }) {
            check(VisualStepPolicy.isCancellationOrRevocationReason(cancelErr),
                    "cancellation/revocation classified: " + cancelErr);
        }
        check(!VisualStepPolicy.isCancellationOrRevocationReason("FRAME_TIMEOUT"),
                "FRAME_TIMEOUT is transient, not cancellation");
        check(VisualStepPolicy.mayRetryTransientObservation(0, 0, 0, 1L),
                "first transient retry permitted");
        check(VisualStepPolicy.mayRetryTransientObservation(
                VisualStepPolicy.MAX_TRANSIENT_OBSERVATION_RETRIES - 1, 1, 2, 100L),
                "second transient retry permitted");
        check(!VisualStepPolicy.mayRetryTransientObservation(
                VisualStepPolicy.MAX_TRANSIENT_OBSERVATION_RETRIES, 2, 2, 100L),
                "transient retry cap enforced");
        check(!VisualStepPolicy.mayRetryTransientObservation(-1, 0, 0, 1L),
                "negative retry count denied");
        check(!VisualStepPolicy.mayRetryTransientObservation(0,
                VisualStepPolicy.MAX_ACTION_STEPS, 0, 1L),
                "transient retry honors step limit");
        check(VisualStepPolicy.mayContinueAfterActionFailure(0, 1, 2, 100L),
                "initial action failure state allowed");
        check(VisualStepPolicy.mayContinueAfterActionFailure(
                VisualStepPolicy.MAX_CONSECUTIVE_ACTION_FAILURES - 1, 1, 2, 100L),
                "single action failure permits bounded recovery");
        check(!VisualStepPolicy.mayContinueAfterActionFailure(
                VisualStepPolicy.MAX_CONSECUTIVE_ACTION_FAILURES, 2, 4, 100L),
                "consecutive action failure cap enforced");
        System.out.println("VisualStepPolicyTest PASS: " + checks + " checks");
    }
}
