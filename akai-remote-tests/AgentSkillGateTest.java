package it.akai.customremote;

import it.akai.customremote.ai.AgentSkillGate;
import org.json.JSONArray;
import org.json.JSONObject;

/** Pure host tests: no ADB, Android device, network or API credentials. */
public final class AgentSkillGateTest {
    private static int passed = 0;

    private static void expect(boolean actual, boolean expected, String description) {
        if (actual != expected) throw new AssertionError(description + " (expected=" + expected + ", actual=" + actual + ")");
        passed++;
    }

    private static JSONArray action(String type, String field, Object value) throws Exception {
        JSONObject obj = new JSONObject().put("type", type);
        if (field != null) obj.put(field, value);
        return new JSONArray().put(obj);
    }

    public static void main(String[] args) throws Exception {
        String verifiedPackage = "{\"type\":\"pkg_is\",\"value\":\"com.google.android.youtube.tv\"}";
        JSONArray openYoutube = action("launch_app", "pkg", "com.google.android.youtube.tv");

        expect(AgentSkillGate.canLearn(true, openYoutube, verifiedPackage), true, "verified app launch learnable");
        expect(AgentSkillGate.canLearn(false, openYoutube, verifiedPackage), false, "command sent is not verified");
        expect(AgentSkillGate.canLearn(true, openYoutube, null), false, "missing success condition");
        expect(AgentSkillGate.canLearn(true, openYoutube, "{}"), false, "unknown success condition type");
        expect(AgentSkillGate.canLearn(true, openYoutube, "{malformed"), false, "malformed JSON condition");
        expect(AgentSkillGate.canLearn(true, new JSONArray(), verifiedPackage), false, "empty action plan");
        expect(AgentSkillGate.canLearn(true, action("run_shell", "cmd", "echo no"), verifiedPackage), false, "arbitrary shell forbidden");
        expect(AgentSkillGate.canLearn(true, action("click_text", "text", ""), verifiedPackage), false, "empty UI selector forbidden");
        expect(AgentSkillGate.canLearn(true, action("wait", "ms", 100), verifiedPackage), false, "no-op only plan");
        expect(AgentSkillGate.canLearn(true, action("wait", "ms", -1), verifiedPackage), false, "negative wait forbidden");
        expect(AgentSkillGate.canLearn(true, action("command", "action", "home"), "{\"type\":\"pkg_any_of\",\"values\":[\"it.akai.customhome.v8\",\"it.akai.customhome\"]}"), true, "Home v8/v7 allowed");
        expect(AgentSkillGate.canLearn(true, openYoutube, "{\"type\":\"contains_text\",\"value\":\"\"}"), false, "empty success value");
        expect(AgentSkillGate.canLearn(true, openYoutube, "{\"type\":\"any_of_pkgs\",\"values\":[]}"), false, "empty package list");
        expect(AgentSkillGate.canLearn(true, openYoutube, "{\"type\":\"player_active\"}"), true, "player verification allowed");
        String tvCenterPkg = "{\"type\":\"pkg_is\",\"value\":\"com.mediatek.wwtv.tvcenter\"}";
        expect(AgentSkillGate.canLearn(true, action("tune_channel", "number", 105), tvCenterPkg), true, "valid DTV tune_channel 105 learnable when verified");
        expect(AgentSkillGate.canLearn(false, action("tune_channel", "number", 105), tvCenterPkg), false, "unverified DTV tune_channel never learnable");
        expect(AgentSkillGate.canLearn(true, action("tune_channel", "number", 0), tvCenterPkg), false, "DTV tune_channel 0 rejected");
        expect(AgentSkillGate.canLearn(true, action("select_channel", "number", 10000), tvCenterPkg), false, "DTV select_channel > 9999 rejected");
        JSONArray tooLong = new JSONArray();
        for (int i = 0; i < 11; i++) tooLong.put(new JSONObject().put("type", "command").put("action", "back"));
        expect(AgentSkillGate.canLearn(true, tooLong, verifiedPackage), false, "bounded learned plan");
        expect(AgentSkillGate.shouldReplay(0, 0), true, "legacy never-attempted template");
        expect(AgentSkillGate.shouldReplay(1, 2), true, "first two failures do not quarantine");
        expect(AgentSkillGate.shouldReplay(1, 3), false, "repeated failed skill quarantined");
        expect(AgentSkillGate.shouldReplay(10, 3), true, "high confidence skill remains usable");
        expect(AgentSkillGate.shouldReplay(0, 3), false, "bad never-successful template quarantined");
        System.out.println("[PASS] AgentSkillGateTest: " + passed + "/" + passed + " host assertions");
    }
}
