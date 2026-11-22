package it.akai.customremote.ai;

import org.json.JSONArray;
import org.json.JSONObject;

/**
 * A0 skill quality gate: lets JARVIS grow its procedural memory without
 * promoting an unverified plan into an automatically replayable skill.
 *
 * This policy has no Android services, threads or database dependencies.
 * It is evaluated only when learning or retrieving a procedure.
 */
public final class AgentSkillGate {
    public static final int MAX_LEARNED_STEPS = 10;
    public static final int QUARANTINE_MIN_FAILURES = 3;

    private AgentSkillGate() {}

    public static boolean canLearn(boolean stateVerified, JSONArray actions, String successCondition) {
        if (!stateVerified || actions == null || actions.length() < 1
                || actions.length() > MAX_LEARNED_STEPS || successCondition == null) {
            return false;
        }

        try {
            JSONObject condition = new JSONObject(successCondition);
            if (!hasObservableSuccessCondition(condition)) return false;

            boolean hasEffectiveAction = false;
            for (int i = 0; i < actions.length(); i++) {
                JSONObject action = actions.optJSONObject(i);
                if (action == null) return false;
                String type = action.optString("type", "");
                switch (type) {
                    case "launch_app":
                    case "open_app":
                        if (!hasText(action.optString("pkg", action.optString("package", "")))) return false;
                        hasEffectiveAction = true;
                        break;
                    case "command":
                    case "press_key":
                        if (!hasText(action.optString("action", action.optString("key", "")))) return false;
                        hasEffectiveAction = true;
                        break;
                    case "click_text":
                    case "click_accessibility_node":
                        if (!hasText(action.optString("text", ""))) return false;
                        hasEffectiveAction = true;
                        break;
                    case "set_volume":
                    case "volume_set":
                        if (!action.has("level") || action.optInt("level", -1) < 0
                                || action.optInt("level", -1) > 100) return false;
                        hasEffectiveAction = true;
                        break;
                    case "select_channel":
                    case "tune_channel":
                        int ch = action.optInt("number", -1);
                        if (ch < 1 || ch > 9999) return false;
                        hasEffectiveAction = true;
                        break;
                    case "wait":
                        if (action.optLong("ms", -1) < 0 || action.optLong("ms", -1) > 5000) return false;
                        break;
                    case "read_ui_state":
                    case "finish_task":
                        break;
                    default:
                        return false;
                }
            }
            return hasEffectiveAction;
        } catch (Exception malformed) {
            return false;
        }
    }

    private static boolean hasObservableSuccessCondition(JSONObject condition) {
        String type = condition.optString("type", "");
        switch (type) {
            case "player_active":
                return true;
            case "contains_text":
            case "pkg_is":
            case "focused_is":
                return hasText(condition.optString("value", ""));
            case "pkg_any_of":
            case "any_of_pkgs":
            case "any_of_texts":
                JSONArray values = condition.optJSONArray("values");
                if (values == null || values.length() == 0) return false;
                for (int i = 0; i < values.length(); i++) {
                    if (!hasText(values.optString(i, ""))) return false;
                }
                return true;
            default:
                return false;
        }
    }

    private static boolean hasText(String value) {
        return value != null && !value.trim().isEmpty();
    }

    /**
     * Quarantine only after repeated failures; keep untried built-in templates
     * available. Recovery is possible when an owner-approved relearning
     * replaces the skill with a newly verified procedure.
     */
    public static boolean shouldReplay(int successes, int failures) {
        if (failures < QUARANTINE_MIN_FAILURES) return true;
        return (long) failures <= 2L * Math.max(1, successes);
    }
}
