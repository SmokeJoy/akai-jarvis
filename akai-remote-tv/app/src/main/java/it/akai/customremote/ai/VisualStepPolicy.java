package it.akai.customremote.ai;

import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Bounded visual planning: a cloud answer may propose a longer route, but
 * JARVIS executes at most ONE step before observing the screen again.
 * No local model; JSON action shape is already validated by AiProviderAdapter.
 */
public final class VisualStepPolicy {
    public static final int MAX_ACTION_STEPS = 8;
    public static final long MAX_GOAL_MS = 120_000L;
    public static final int MAX_CLOUD_CALLS = 16;
    public static final int MAX_TRANSIENT_OBSERVATION_RETRIES = 2;
    public static final int MAX_CONSECUTIVE_ACTION_FAILURES = 2;
    public static final long TRANSIENT_RETRY_DELAY_MS = 800L;

    private VisualStepPolicy() {}

    public static JSONObject firstStep(JSONArray proposed) {
        if (proposed == null || proposed.length() == 0) return null;
        JSONObject step = proposed.optJSONObject(0);
        if (step == null || step.optString("type", "").trim().isEmpty()) return null;
        return step;
    }

    /**
     * Evaluate a goal against elapsed duration, not wall-clock time. The caller
     * must supply a monotonic interval (System.nanoTime() in production).
     * Changing the TV clock must never grant extra cloud planning time.
     */
    public static boolean mayContinueElapsed(int executedSteps, int cloudCalls, long elapsedMs) {
        return executedSteps >= 0 && executedSteps < MAX_ACTION_STEPS
                && cloudCalls >= 0 && cloudCalls < MAX_CLOUD_CALLS
                && elapsedMs >= 0 && elapsedMs < MAX_GOAL_MS;
    }

    /** Compatibility for existing deterministic tests and legacy callers. */
    public static boolean mayContinue(int executedSteps, int cloudCalls,
            long startedAtMs, long nowMs) {
        return startedAtMs > 0 && nowMs >= startedAtMs
                && mayContinueElapsed(executedSteps, cloudCalls, nowMs - startedAtMs);
    }

    /**
     * If the exact same step is proposed on an unchanged perceived state
     * and unchanged remote image description, decline a potentially endless
     * click/dpad loop rather than blindly retrying.
     */
    public static boolean repeatedWithoutProgress(String previousAction,
            String previousState, String currentAction, String currentState) {
        return previousAction != null && currentAction != null
                && previousState != null && currentState != null
                && previousAction.equals(currentAction)
                && previousState.equals(currentState);
    }

    /**
     * Narrow allowlist of transient single-step observation/frame hiccups that
     * may recover on a fresh capture. Security, privacy, DRM, consent, budget,
     * cancellation, revocation, and hard frame-cap errors are never retried.
     */
    public static boolean isTransientObservationFailure(String reason) {
        if (reason == null) return false;
        switch (reason) {
            case "FRAME_RATE_LIMIT":
            case "FRAME_FOREGROUND_CHANGED":
            case "UI_CHANGED_BEFORE_UPLOAD":
            case "NO_NEW_FRAME_TIMEOUT":
            case "FRAME_TIMEOUT":
            case "FRAME_REQUEST_BUSY":
                return true;
            default:
                return false;
        }
    }

    /** Explicit STOP, session revocation/closure, or consent revocation. */
    public static boolean isCancellationOrRevocationReason(String reason) {
        if (reason == null) return false;
        switch (reason) {
            case "TASK_CANCELLED":
            case "SESSION_REVOKED_DURING_OBSERVATION":
            case "SESSION_REVOKED_BEFORE_UPLOAD":
            case "SESSION_STOPPED":
            case "SESSION_CLOSED":
            case "CLOUD_CONSENT_REVOKED":
                return true;
            default:
                return false;
        }
    }

    public static boolean mayRetryTransientObservation(int consecutiveTransientFailures,
            int executedSteps, int cloudCalls, long elapsedMs) {
        return consecutiveTransientFailures >= 0
                && consecutiveTransientFailures < MAX_TRANSIENT_OBSERVATION_RETRIES
                && mayContinueElapsed(executedSteps, cloudCalls, elapsedMs);
    }

    public static boolean mayContinueAfterActionFailure(int consecutiveActionFailures,
            int executedSteps, int cloudCalls, long elapsedMs) {
        return consecutiveActionFailures >= 0
                && consecutiveActionFailures < MAX_CONSECUTIVE_ACTION_FAILURES
                && mayContinueElapsed(executedSteps, cloudCalls, elapsedMs);
    }
}
