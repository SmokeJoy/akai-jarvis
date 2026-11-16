package it.akai.customremote.ai;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.Locale;

/**
 * A2: deterministic verifier that judges the user's FINAL goal separately
 * from the cloud planner's self-reported success_condition.
 *
 * This class never executes actions, opens network sockets, stores data or
 * trusts a planner's "reply" as evidence. Conservative failures are intentional:
 * a false "not verified" is preferable to claiming an unobserved result.
 */
public final class GoalEvidenceVerifier {
    private GoalEvidenceVerifier() {}

    public static final class Verdict {
        public final boolean verified;
        public final String reason;
        public final String evidence;

        Verdict(boolean verified, String reason, String evidence) {
            this.verified = verified;
            this.reason = reason;
            this.evidence = evidence;
        }
    }

    private static Verdict no(String reason) {
        return new Verdict(false, reason, "NO_FINAL_GOAL_EVIDENCE");
    }

    public static Verdict check(String userGoal, String conditionJson,
                                ScreenPerceptionEngine.PerceptionSnapshot snapshot) {
        if (snapshot == null || snapshot.foregroundPackage == null ||
                "unknown".equals(snapshot.foregroundPackage)) {
            return no("SCREEN_UNAVAILABLE");
        }
        if (snapshot.hasSensitiveFields) {
            return no("SENSITIVE_SCREEN");
        }
        if (conditionJson == null || conditionJson.trim().isEmpty()) {
            return no("NO_SUCCESS_CONDITION");
        }

        final JSONObject condition;
        try {
            condition = new JSONObject(conditionJson);
        } catch (Exception malformed) {
            return no("INVALID_SUCCESS_CONDITION");
        }
        final String type = condition.optString("type", "");
        if (!ScreenPerceptionEngine.evaluateSuccessCondition(snapshot, conditionJson)) {
            return no("CONDITION_NOT_OBSERVED");
        }

        String goal = userGoal == null ? "" : userGoal.toLowerCase(Locale.ITALIAN);
        if (requiresPlayback(goal)) {
            // Seeing an app/player control is NOT proof that the requested
            // video or audio is playing. Require player node + active audio,
            // plus visible expected content text. If content is hidden (DRM/
            // fullscreen) report unknown instead of inventing completion.
            if (!"player_active".equals(type)) {
                return no("INTERMEDIATE_SCREEN_NOT_PLAYBACK");
            }
            if (!snapshot.isPlayerActive || !snapshot.isMusicActive) {
                return no("PLAYBACK_NOT_OBSERVABLE");
            }
            String title = condition.optString("channel_text",
                    condition.optString("expected_text", "")).trim();
            if (title.isEmpty() || isGenericNavigationText(title)
                    || !snapshot.containsText(title, false)
                    || !titleHasGoalEvidence(goal, title)) {
                return no("REQUESTED_CONTENT_NOT_IDENTIFIED");
            }
            return new Verdict(true, "FINAL_PLAYBACK_OBSERVED",
                    "player_active+music_active+requested_content_visible");
        }

        if (requiresSearchResult(goal)) {
            // A search box, app foreground or navigation label only proves
            // that we navigated to a search UI, not that a specific result
            // was found. Reject weak planner-chosen success conditions.
            if ("pkg_is".equals(type) || "pkg_any_of".equals(type)
                    || "any_of_pkgs".equals(type) || "focused_is".equals(type)) {
                return no("SEARCH_RESULT_NOT_EVIDENCED");
            }
            if ("contains_text".equals(type)) {
                String expected = condition.optString("value", "");
                if (isGenericNavigationText(expected) || !titleHasGoalEvidence(goal, expected)) {
                    return no("SEARCH_RESULT_NOT_EVIDENCED");
                }
            } else if ("any_of_texts".equals(type)) {
                JSONArray values = condition.optJSONArray("values");
                boolean targetObserved = false;
                if (values != null) {
                    for (int i = 0; i < values.length(); i++) {
                        String expected = values.optString(i, "");
                        if (!isGenericNavigationText(expected)
                                && titleHasGoalEvidence(goal, expected)
                                && snapshot.containsText(expected, false)) {
                            targetObserved = true;
                            break;
                        }
                    }
                }
                if (!targetObserved) return no("SEARCH_RESULT_NOT_EVIDENCED");
            } else {
                return no("SEARCH_RESULT_NOT_EVIDENCED");
            }
        }

        return new Verdict(true, "FINAL_CONDITION_OBSERVED",
                "screen_condition_observed");
    }

    private static boolean requiresPlayback(String goal) {
        return goal.contains("riproduc") || goal.contains("riparti il video")
                || goal.contains("avvia un video") || goal.contains("avvia il video")
                || goal.contains("fai partire") || goal.contains("guarda ")
                || goal.contains("metti un video") || goal.contains("metti il video")
                || goal.contains("ascolta ") || goal.contains("avvia la riproduzione")
                || goal.contains("avviare un video");
    }

    private static boolean requiresSearchResult(String goal) {
        boolean requestedSearch = goal.contains("cerca ") || goal.contains("trova ")
                || goal.contains("ricerca ");
        if (!requestedSearch) return false;
        // "Apri Cerca" means reaching the search UI, not finding a named result.
        return !(goal.equals("apri ricerca") || goal.equals("apri cerca")
                || goal.equals("cerca youtube") || goal.equals("apri cerca youtube"));
    }

    private static boolean isGenericNavigationText(String value) {
        String v = value == null ? "" : value.trim().toLowerCase(Locale.ITALIAN);
        return v.isEmpty() || v.equals("cerca") || v.equals("search")
                || v.equals("youtube") || v.equals("home") || v.equals("video")
                || v.equals("risultati") || v.equals("ricerca")
                || v.equals("play") || v.equals("riproduci");
    }

    /** At least one substantial content word in the expected title must be in the actual goal. */
    private static boolean titleHasGoalEvidence(String goal, String title) {
        if (title == null || goal == null) return false;
        String[] words = title.toLowerCase(Locale.ITALIAN).split("[^\\p{L}\\p{N}]+");
        for (String word : words) {
            if (word.length() >= 4 && !isGenericNavigationText(word)
                    && goal.contains(word)) return true;
        }
        return false;
    }
}
