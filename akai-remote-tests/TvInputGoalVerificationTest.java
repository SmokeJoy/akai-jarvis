package it.akai.customremote;

import it.akai.customremote.ai.GoalEvidenceVerifier;
import it.akai.customremote.ai.LocalIntentParser;
import it.akai.customremote.ai.ScreenPerceptionEngine;
import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;

/**
 * Host verification for DTV / HDMI / Sources LocalIntentParser conditions,
 * GoalEvidenceVerifier independent TV input + OEM ANR verification, and
 * GET /api/status accessibility_active telemetry.
 */
public class TvInputGoalVerificationTest {
    private static void assertTrue(boolean cond, String msg) {
        if (!cond) {
            throw new AssertionError("TvInputGoalVerificationTest failed: " + msg);
        }
    }

    private static void assertEquals(Object expected, Object actual, String msg) {
        if (expected == null ? actual != null : !expected.equals(actual)) {
            throw new AssertionError("TvInputGoalVerificationTest failed [" + msg + "]: expected=" + expected + " actual=" + actual);
        }
    }

    private static ScreenPerceptionEngine.PerceptionSnapshot snap(String pkg, List<String> texts) {
        return new ScreenPerceptionEngine.PerceptionSnapshot(
                pkg,
                texts,
                Collections.<ScreenPerceptionEngine.ClickableElement>emptyList(),
                null,
                false,
                false,
                false);
    }

    public static void main(String[] args) throws Exception {
        // 1. LocalIntentParser must attach pkg_is com.mediatek.wwtv.tvcenter to all TV inputs + catalog
        for (String q : Arrays.asList("digitale terrestre", "hdmi 1", "passa a hdmi 2", "metti hdmi 3", "ingressi")) {
            LocalIntentParser.ParsedIntent p = LocalIntentParser.parse(null, q);
            assertTrue(p.matched, "query matched: " + q);
            assertTrue(p.successCondition != null && !p.successCondition.trim().isEmpty(), "has successCondition: " + q);
            JSONObject cond = new JSONObject(p.successCondition);
            assertEquals("pkg_is", cond.optString("type"), "cond type for " + q);
            assertEquals(TvInputIntentPolicy.TV_CENTER_PACKAGE, cond.optString("value"), "cond pkg for " + q);
        }
        String catalogStr = LocalIntentParser.getSupportedCatalog().toString();
        assertTrue(catalogStr.contains("\"input_source\""), "catalog contains input_source");

        String tvCond = "{\"type\":\"pkg_is\",\"value\":\"com.mediatek.wwtv.tvcenter\"}";

        // 2. DTV verification: PASS on clean tvcenter; FAIL on Home, HDMI banner, or OEM ANR/crash
        ScreenPerceptionEngine.PerceptionSnapshot dtvOkSnap =
                snap(TvInputIntentPolicy.TV_CENTER_PACKAGE, Arrays.asList("Rai 1 HD", "DTV"));
        GoalEvidenceVerifier.Verdict dtvOk = GoalEvidenceVerifier.verify("digitale terrestre", tvCond, dtvOkSnap);
        assertTrue(dtvOk.satisfied && ScreenPerceptionEngine.evaluateSuccessCondition(dtvOkSnap, tvCond),
                "DTV STATE_VERIFIED on clean tvcenter");

        ScreenPerceptionEngine.PerceptionSnapshot homeSnap =
                snap("it.akai.customhome.v8", Arrays.asList("DTV", "HDMI 1"));
        assertTrue(!GoalEvidenceVerifier.verify("digitale terrestre", tvCond, homeSnap).satisfied,
                "DTV denied when stuck on Home");

        ScreenPerceptionEngine.PerceptionSnapshot wrongHdmiBanner =
                snap(TvInputIntentPolicy.TV_CENTER_PACKAGE, Arrays.asList("HDMI 1", "1080p 60Hz"));
        assertTrue(!GoalEvidenceVerifier.verify("digitale terrestre", tvCond, wrongHdmiBanner).satisfied,
                "DTV denied when LiveTV displays HDMI banner");

        ScreenPerceptionEngine.PerceptionSnapshot oemAnrSnap =
                snap("android", Arrays.asList("LiveTV non risponde", "Chiudi app", "Attendi"));
        GoalEvidenceVerifier.Verdict anrVerdict = GoalEvidenceVerifier.verify("digitale terrestre", tvCond, oemAnrSnap);
        assertTrue(!anrVerdict.satisfied, "DTV denied on OEM ANR dialog");
        assertEquals("oem_dialog", anrVerdict.goalKind, "OEM ANR goalKind");

        // 3. HDMI 1 verification: requires tvcenter + whole-word OSD HDMI 1 (rejects missing OSD, HDMI 10, HDMI 2, ANR)
        ScreenPerceptionEngine.PerceptionSnapshot hdmi1Ok =
                snap(TvInputIntentPolicy.TV_CENTER_PACKAGE, Arrays.asList("HDMI 1", "1920x1080"));
        GoalEvidenceVerifier.Verdict h1Pass = GoalEvidenceVerifier.verify("hdmi 1", tvCond, hdmi1Ok);
        assertTrue(h1Pass.satisfied && ScreenPerceptionEngine.evaluateSuccessCondition(hdmi1Ok, tvCond),
                "HDMI 1 STATE_VERIFIED with OSD label");

        ScreenPerceptionEngine.PerceptionSnapshot hdmiNoOsd =
                snap(TvInputIntentPolicy.TV_CENTER_PACKAGE, Arrays.asList("Nessun segnale"));
        assertTrue(!GoalEvidenceVerifier.verify("hdmi 1", tvCond, hdmiNoOsd).satisfied,
                "HDMI 1 stays unverified without port OSD proof");

        ScreenPerceptionEngine.PerceptionSnapshot hdmiWrongPort =
                snap(TvInputIntentPolicy.TV_CENTER_PACKAGE, Arrays.asList("HDMI 2", "1920x1080"));
        assertTrue(!GoalEvidenceVerifier.verify("hdmi 1", tvCond, hdmiWrongPort).satisfied,
                "HDMI 1 rejects HDMI 2 OSD");

        ScreenPerceptionEngine.PerceptionSnapshot hdmiTenTrap =
                snap(TvInputIntentPolicy.TV_CENTER_PACKAGE, Arrays.asList("HDMI 10"));
        assertTrue(!GoalEvidenceVerifier.verify("hdmi 1", tvCond, hdmiTenTrap).satisfied,
                "HDMI 1 rejects HDMI 10 substring");

        ScreenPerceptionEngine.PerceptionSnapshot oemCrashSnap =
                snap(TvInputIntentPolicy.TV_CENTER_PACKAGE, Arrays.asList("com.mediatek.wwtv.tvcenter continua a interrompersi"));
        GoalEvidenceVerifier.Verdict crashVerdict = GoalEvidenceVerifier.verify("hdmi 1", tvCond, oemCrashSnap);
        assertTrue(!crashVerdict.satisfied && "oem_dialog".equals(crashVerdict.goalKind),
                "HDMI 1 detects OEM crash dialog separately");

        // 4. GET /api/status reports accessibility_active cleanly
        final boolean[] accFlag = new boolean[] { false };
        RestApiRouter.CommandHandler cmdHandler = new RestApiRouter.CommandHandler() {
            @Override public CommandResult executeCommand(String action) { return new CommandResult(true, "OK"); }
            @Override public CommandResult injectText(String text) { return new CommandResult(true, "OK"); }
            @Override public boolean isUInputReady() { return true; }
            @Override public boolean isAccessibilityActive() { return accFlag[0]; }
        };
        RestApiRouter.MemoryHandler memHandler = new RestApiRouter.MemoryHandler() {
            @Override public JSONArray getAllProcedures() { return new JSONArray(); }
            @Override public JSONObject getAllPreferences() { return new JSONObject(); }
            @Override public JSONObject getAllStats() { return new JSONObject(); }
            @Override public JSONArray getRecentConversations(int limit) { return new JSONArray(); }
            @Override public long getDatabaseSizeBytes() { return 0L; }
            @Override public boolean isGuestMode() { return false; }
            @Override public void setGuestMode(boolean enabled) {}
            @Override public void resetProcedures() {}
            @Override public void clearPersonalPreferencesOnly() {}
        };
        RestApiRouter.PinHandler pinHandler = new RestApiRouter.PinHandler() {
            @Override public void showPin(String pin, int remainingSeconds, String serverUrl) {}
            @Override public void dismissPin() {}
        };
        RestApiRouter.AiHandler aiHandler = new RestApiRouter.AiHandler() {
            @Override public JSONObject processQuery(String query, boolean speak) { return new JSONObject(); }
            @Override public boolean isStrictLocalOnly() { return true; }
            @Override public JSONArray getSupportedCatalog() { return LocalIntentParser.getSupportedCatalog(); }
        };

        RestApiRouter router = new RestApiRouter(new SecurityManager(), cmdHandler, memHandler, pinHandler, aiHandler, "127.0.0.1", 8088);

        for (boolean expectedAcc : new boolean[] { false, true }) {
            accFlag[0] = expectedAcc;
            ByteArrayOutputStream baos = new ByteArrayOutputStream();
            router.routeRequest("GET", "/api/status", new HashMap<String, String>(), "", "10.0.0.50", baos, false);
            String raw = new String(baos.toByteArray(), StandardCharsets.UTF_8);
            int bodyIdx = raw.indexOf("\r\n\r\n");
            assertTrue(bodyIdx > 0, "HTTP status response valid");
            JSONObject statusJson = new JSONObject(raw.substring(bodyIdx + 4));
            assertTrue(statusJson.has("accessibility_active"), "/api/status contains accessibility_active");
            assertEquals(expectedAcc, statusJson.getBoolean("accessibility_active"), "accessibility_active=" + expectedAcc);
        }

        System.out.println("TvInputGoalVerificationTest PASS: DTV/HDMI/Sources verification, OEM ANR separation & /api/status accessibility_active OK.");
    }
}
