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

    private VisualStepPolicy() {}

    public static JSONObject firstStep(JSONArray proposed) {
        if (proposed == null || proposed.length() == 0) return null;
        JSONObject step = proposed.optJSONObject(0);
        if (step == null || step.optString("type", "").trim().isEmpty()) return null;
        return step;
    }

    public static boolean mayContinue(int executedSteps, int cloudCalls,
            long startedAtMs, long nowMs) {
        return executedSteps >= 0 && executedSteps < MAX_ACTION_STEPS
                && cloudCalls >= 0 && cloudCalls < MAX_CLOUD_CALLS
                && startedAtMs > 0 && nowMs >= startedAtMs
                && nowMs - startedAtMs < MAX_GOAL_MS;
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
}
