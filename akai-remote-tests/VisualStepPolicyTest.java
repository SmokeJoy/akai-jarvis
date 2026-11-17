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
        check(VisualStepPolicy.repeatedWithoutProgress(
                "dpad_right", "same UI + image", "dpad_right", "same UI + image"),
                "identical action with unchanged screen blocked");
        check(!VisualStepPolicy.repeatedWithoutProgress(
                "dpad_right", "UI1", "dpad_right", "UI2"),
                "new UI state allows another press");
        check(!VisualStepPolicy.repeatedWithoutProgress(
                "dpad_right", "UI1", "dpad_left", "UI1"),
                "different action is different plan");
        System.out.println("VisualStepPolicyTest PASS: " + checks + " checks");
    }
}
