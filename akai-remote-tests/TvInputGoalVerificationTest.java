package it.akai.customremote;

import it.akai.customremote.ai.AiProviderAdapter;
import it.akai.customremote.ai.AkaiAiController;
import it.akai.customremote.ai.AkaiMemoryEngine;
import it.akai.customremote.ai.GoalEvidenceVerifier;
import it.akai.customremote.ai.LocalIntentParser;
import it.akai.customremote.ai.ScreenPerceptionEngine;
import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

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
        return snapWithActivity(pkg, null, texts, System.currentTimeMillis());
    }

    private static ScreenPerceptionEngine.PerceptionSnapshot snapWithActivity(
            String pkg, String activity, List<String> texts, long ts) {
        return new ScreenPerceptionEngine.PerceptionSnapshot(
                pkg,
                activity,
                texts,
                Collections.<ScreenPerceptionEngine.ClickableElement>emptyList(),
                null,
                false,
                false,
                false,
                ts);
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

        // 3b. ChatGPT P1 fail-closed regressions (directive 7078533358):
        //     Never certify DTV/HDMI/Sources merely from tvcenter foreground or ambiguous/stale UI.
        long nowMs = 1_700_000_000_000L;
        ScreenPerceptionEngine.PerceptionSnapshot dtvEmptyNullAct =
                snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE, null, Collections.<String>emptyList(), nowMs);
        assertTrue(!GoalEvidenceVerifier.verify("digitale terrestre", tvCond, dtvEmptyNullAct, nowMs, nowMs - 100L).satisfied,
                "DTV DENIED on tvcenter + zero texts (null activity)");

        ScreenPerceptionEngine.PerceptionSnapshot dtvEmptyMainAct =
                snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                        Collections.<String>emptyList(), nowMs);
        assertTrue(!GoalEvidenceVerifier.verify("digitale terrestre", tvCond, dtvEmptyMainAct, nowMs, nowMs - 100L).satisfied,
                "DTV DENIED on tvcenter + TurnkeyUiMainActivity + zero texts (expired HDMI OSD case)");

        ScreenPerceptionEngine.PerceptionSnapshot dtvExpiredHdmiOsd =
                snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                        Arrays.asList("1080p 60Hz"), nowMs);
        assertTrue(!GoalEvidenceVerifier.verify("digitale terrestre", tvCond, dtvExpiredHdmiOsd, nowMs, nowMs - 100L).satisfied,
                "DTV DENIED on tvcenter with HDMI resolution OSD only");

        for (String ambiguous : Arrays.asList("Nessun segnale", "No signal", "Uscita digitale", "LiveTV")) {
            ScreenPerceptionEngine.PerceptionSnapshot ambSnap =
                    snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                            Collections.singletonList(ambiguous), nowMs);
            assertTrue(!GoalEvidenceVerifier.verify("digitale terrestre", tvCond, ambSnap, nowMs, nowMs - 100L).satisfied,
                    "DTV DENIED on ambiguous text: " + ambiguous);
        }

        ScreenPerceptionEngine.PerceptionSnapshot dtvInputsPanelOpen =
                snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_INPUTS_ACTIVITY,
                        Arrays.asList("Ingressi", "DTV", "HDMI 1"), nowMs);
        assertTrue(!GoalEvidenceVerifier.verify("digitale terrestre", tvCond, dtvInputsPanelOpen, nowMs, nowMs - 100L).satisfied,
                "DTV DENIED while InputsPanelActivity is still open");

        ScreenPerceptionEngine.PerceptionSnapshot dtvStaleAge =
                snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                        Arrays.asList("Rai 1 HD", "DTV"), nowMs - 20_000L);
        assertTrue(!GoalEvidenceVerifier.verify("digitale terrestre", tvCond, dtvStaleAge, nowMs, 0L).satisfied,
                "DTV DENIED when snapshot age exceeds 15s freshness window");

        ScreenPerceptionEngine.PerceptionSnapshot dtvPreCommand =
                snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                        Arrays.asList("Rai 1 HD", "DTV"), nowMs - 50L);
        assertTrue(!GoalEvidenceVerifier.verify("digitale terrestre", tvCond, dtvPreCommand, nowMs, nowMs).satisfied,
                "DTV DENIED when snapshot predates command dispatch");

        ScreenPerceptionEngine.PerceptionSnapshot dtvCh001Ok =
                snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                        Arrays.asList("CH 001", "DTV"), nowMs);
        assertTrue(GoalEvidenceVerifier.verify("digitale terrestre", tvCond, dtvCh001Ok, nowMs, nowMs - 10L).satisfied,
                "DTV ALLOWED with fresh TurnkeyUiMainActivity + Rai/CH 001 + DTV");

        // HDMI 1 additional fail-closed cases
        ScreenPerceptionEngine.PerceptionSnapshot hdmi1InputsOpen =
                snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_INPUTS_ACTIVITY,
                        Arrays.asList("Ingressi", "HDMI 1", "HDMI 2"), nowMs);
        assertTrue(!GoalEvidenceVerifier.verify("hdmi 1", tvCond, hdmi1InputsOpen, nowMs, nowMs - 10L).satisfied,
                "HDMI 1 DENIED when InputsPanelActivity is open");

        ScreenPerceptionEngine.PerceptionSnapshot hdmiMultiPorts =
                snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                        Arrays.asList("HDMI 1", "HDMI 2"), nowMs);
        assertTrue(!GoalEvidenceVerifier.verify("hdmi 1", tvCond, hdmiMultiPorts, nowMs, nowMs - 10L).satisfied,
                "HDMI 1 DENIED when multiple HDMI ports appear simultaneously");

        assertTrue(!GoalEvidenceVerifier.verify("hdmi 1", tvCond,
                snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                        Collections.singletonList("Nessun segnale"), nowMs), nowMs, nowMs - 10L).satisfied,
                "HDMI 1 DENIED on Nessun segnale");
        assertTrue(!GoalEvidenceVerifier.verify("hdmi 1", tvCond,
                snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                        Arrays.asList("HDMI 1", "1920x1080"), nowMs - 20_000L), nowMs, 0L).satisfied,
                "HDMI 1 DENIED on stale snapshot");
        assertTrue(GoalEvidenceVerifier.verify("hdmi 1", tvCond,
                snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                        Arrays.asList("HDMI 1", "1920x1080"), nowMs), nowMs, nowMs - 10L).satisfied,
                "HDMI 1 ALLOWED on fresh TurnkeyUiMainActivity + HDMI 1 OSD");

        // input_source ("ingressi" / "sorgenti") fail-closed verification
        assertTrue(!GoalEvidenceVerifier.verify("ingressi", tvCond,
                snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                        Collections.<String>emptyList(), nowMs), nowMs, nowMs - 10L).satisfied,
                "input_source DENIED on TurnkeyUiMainActivity + []");
        assertTrue(!GoalEvidenceVerifier.verify("sorgenti", tvCond,
                snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                        Arrays.asList("Rai 1 HD", "DTV"), nowMs), nowMs, nowMs - 10L).satisfied,
                "input_source DENIED on TurnkeyUiMainActivity + DTV");
        assertTrue(!GoalEvidenceVerifier.verify("ingressi", tvCond,
                snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                        Collections.singletonList("Nessun segnale"), nowMs), nowMs, nowMs - 10L).satisfied,
                "input_source DENIED on TurnkeyUiMainActivity + Nessun segnale");
        assertTrue(!GoalEvidenceVerifier.verify("ingressi", tvCond,
                snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                        Arrays.asList("Ingressi", "TV", "HDMI 1", "HDMI 2"), nowMs), nowMs, nowMs - 10L).satisfied,
                "input_source DENIED when foregroundActivity is TurnkeyUiMainActivity despite text");
        assertTrue(!GoalEvidenceVerifier.verify("ingressi", tvCond,
                snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE, null, Collections.<String>emptyList(), nowMs),
                nowMs, nowMs - 10L).satisfied,
                "input_source DENIED on null activity + []");
        assertTrue(!GoalEvidenceVerifier.verify("ingressi", tvCond,
                snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE, null, Collections.singletonList("HDMI 1"), nowMs),
                nowMs, nowMs - 10L).satisfied,
                "input_source DENIED on null activity + HDMI 1");
        assertTrue(!GoalEvidenceVerifier.verify("ingressi", tvCond,
                snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_INPUTS_ACTIVITY,
                        Collections.<String>emptyList(), nowMs - 20_000L), nowMs, 0L).satisfied,
                "input_source DENIED on stale InputsPanelActivity");
        assertTrue(GoalEvidenceVerifier.verify("ingressi", tvCond,
                snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_INPUTS_ACTIVITY,
                        Collections.<String>emptyList(), nowMs), nowMs, nowMs - 10L).satisfied,
                "input_source ALLOWED on fresh InputsPanelActivity");
        assertTrue(GoalEvidenceVerifier.verify("sorgenti", tvCond,
                snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE, null,
                        Arrays.asList("Ingressi", "TV", "HDMI 1", "HDMI 2"), nowMs), nowMs, nowMs - 10L).satisfied,
                "input_source ALLOWED on null activity + fresh multi-source UI panel cues");

        // 3c. End-to-end AkaiAiController.createForTest verification (fast-path & autonomous planner)
        boolean prevStrictLocal = AkaiAiController.isStrictLocalOnly();
        android.content.Context testCtx = new android.content.Context() {};
        AkaiMemoryEngine memEngine = AkaiMemoryEngine.getInstance(testCtx);
        memEngine.resetForTest();
        try {
            AkaiAiController.setDefaultPollIntervalMsForTest(0L);
            final List<ScreenPerceptionEngine.PerceptionSnapshot> nextPostSnaps = new ArrayList<>();
            final AtomicInteger postIndex = new AtomicInteger(0);
            final boolean[] captureAtCallTime = new boolean[] { true };
            final ScreenPerceptionEngine.PerceptionSnapshot[] fixedPost = new ScreenPerceptionEngine.PerceptionSnapshot[1];

            AkaiAiController.PerceptionAndExecutionBridge mockBridge = new AkaiAiController.PerceptionAndExecutionBridge() {
                @Override
                public ScreenPerceptionEngine.PerceptionSnapshot capture(android.content.Context c) {
                    if (fixedPost[0] != null && !captureAtCallTime[0]) {
                        return fixedPost[0];
                    }
                    int idx = postIndex.getAndIncrement();
                    if (idx == 0) {
                        return snapWithActivity("it.akai.customhome.v8", null, Collections.singletonList("Home"), System.currentTimeMillis());
                    }
                    if (!nextPostSnaps.isEmpty()) {
                        ScreenPerceptionEngine.PerceptionSnapshot tmpl = nextPostSnaps.get(0);
                        return snapWithActivity(tmpl.foregroundPackage, tmpl.foregroundActivity, tmpl.visibleTexts, System.currentTimeMillis());
                    }
                    return snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE, null, Collections.<String>emptyList(), System.currentTimeMillis());
                }

                @Override
                public TvController.CommandResult executeActions(JSONArray actions) {
                    return new TvController.CommandResult(true, "Richiesta ingresso inviata");
                }

                @Override
                public void sleepMs(long ms) {}
            };

            AiProviderAdapter mockCloudAdapter = new AiProviderAdapter(testCtx) {
                @Override public String getActiveProvider() { return AiProviderAdapter.PROVIDER_DEEPSEEK; }
                @Override public String getApiKey(String provider) { return "mock-test-credential"; }
                @Override public boolean hasCloudContextConsent() { return true; }
                @Override public boolean isBudgetExceeded() { return false; }
                @Override public double getTotalSpentEur() { return 0.0; }
                @Override public double getRemainingBudgetEur() { return 5.0; }
                @Override
                public AiResponse planActionSequence(String userGoal, String screenContext, JSONObject preferences, JSONArray conversationHistory) {
                    JSONArray acts = new JSONArray();
                    try {
                        acts.put(new JSONObject().put("type", "command").put("action", "input_tv"));
                    } catch (Exception ignored) {}
                    return new AiResponse(
                            true,
                            "Passo al digitale terrestre...",
                            acts,
                            "autonomous_dtv_switch",
                            userGoal,
                            tvCond,
                            true,
                            12,
                            8,
                            20,
                            0.0,
                            null,
                            null);
                }
            };

            AkaiAiController ctrl = AkaiAiController.createForTest(testCtx, new TvController(), memEngine, mockCloudAdapter, mockBridge);

            // Fast-path DTV unverified cases -> COMMAND_SENT, COMPLETED_UNVERIFIED, needs_visual_confirmation=true, 0 procedures saved
            for (List<String> unverifiedTexts : Arrays.asList(
                    Collections.<String>emptyList(),
                    Collections.singletonList("Nessun segnale"),
                    Collections.singletonList("1080p 60Hz"))) {
                memEngine.resetForTest();
                postIndex.set(0);
                captureAtCallTime[0] = true;
                nextPostSnaps.clear();
                nextPostSnaps.add(snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE,
                        TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY, unverifiedTexts, System.currentTimeMillis()));
                JSONObject res = ctrl.processQuery("digitale terrestre", false);
                assertEquals(false, res.optBoolean("success", true), "fast-path DTV unverified success=false: " + unverifiedTexts);
                assertEquals(false, res.optBoolean("verified", true), "fast-path DTV verified=false: " + unverifiedTexts);
                assertEquals(AkaiAiController.OUTCOME_COMMAND_SENT, res.optString("execution_outcome"), "fast-path DTV outcome=COMMAND_SENT");
                assertEquals("COMPLETED_UNVERIFIED", res.optString("status"), "fast-path DTV status=COMPLETED_UNVERIFIED");
                assertEquals(true, res.optBoolean("needs_visual_confirmation"), "fast-path DTV needs_visual_confirmation=true");
                String replyLower = res.optString("reply", "").toLowerCase();
                assertTrue(replyLower.contains("confermare visivamente") || replyLower.contains("conferma visiva"),
                        "fast-path DTV visual confirmation prompt: " + replyLower);
                assertEquals(0, memEngine.getAllProcedures().length(), "fast-path DTV saves 0 procedures");
            }

            // Fast-path input_source on TurnkeyUiMainActivity -> COMMAND_SENT / COMPLETED_UNVERIFIED
            memEngine.resetForTest();
            postIndex.set(0);
            captureAtCallTime[0] = true;
            nextPostSnaps.clear();
            nextPostSnaps.add(snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE,
                    TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY, Collections.<String>emptyList(), System.currentTimeMillis()));
            JSONObject srcFailRes = ctrl.processQuery("ingressi", false);
            assertEquals(false, srcFailRes.optBoolean("success", true), "ingressi unverified on TurnkeyUiMainActivity");
            assertEquals(AkaiAiController.OUTCOME_COMMAND_SENT, srcFailRes.optString("execution_outcome"), "ingressi outcome=COMMAND_SENT");
            assertEquals("COMPLETED_UNVERIFIED", srcFailRes.optString("status"), "ingressi status=COMPLETED_UNVERIFIED");
            assertEquals(true, srcFailRes.optBoolean("needs_visual_confirmation"), "ingressi needs_visual_confirmation=true");
            assertEquals(0, memEngine.getAllProcedures().length(), "ingressi saves 0 procedures");

            // Fast-path input_source on fresh InputsPanelActivity -> STATE_VERIFIED
            postIndex.set(0);
            nextPostSnaps.clear();
            nextPostSnaps.add(snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE,
                    TvInputIntentPolicy.TV_CENTER_INPUTS_ACTIVITY, Collections.<String>emptyList(), System.currentTimeMillis()));
            JSONObject srcOkRes = ctrl.processQuery("ingressi", false);
            assertEquals(true, srcOkRes.optBoolean("success"), "ingressi verified on fresh InputsPanelActivity");
            assertEquals(true, srcOkRes.optBoolean("verified"), "ingressi verified=true");
            assertEquals(AkaiAiController.OUTCOME_STATE_VERIFIED, srcOkRes.optString("execution_outcome"), "ingressi STATE_VERIFIED");
            assertEquals("SUCCESS_VERIFIED", srcOkRes.optString("status"), "ingressi SUCCESS_VERIFIED");
            assertEquals(false, srcOkRes.optBoolean("needs_visual_confirmation", true), "ingressi verified no visual ask");

            // Stale pre-command snapshot (even with Rai 1 HD + DTV) MUST remain COMMAND_SENT / COMPLETED_UNVERIFIED
            postIndex.set(0);
            captureAtCallTime[0] = false;
            fixedPost[0] = snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE,
                    TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY, Arrays.asList("Rai 1 HD", "DTV"),
                    System.currentTimeMillis() - 5000L);
            JSONObject stalePostRes = ctrl.processQuery("digitale terrestre", false);
            assertEquals(false, stalePostRes.optBoolean("success", true), "stale pre-command snapshot cannot verify DTV");
            assertEquals(AkaiAiController.OUTCOME_COMMAND_SENT, stalePostRes.optString("execution_outcome"), "stale DTV COMMAND_SENT");
            assertEquals("COMPLETED_UNVERIFIED", stalePostRes.optString("status"), "stale DTV COMPLETED_UNVERIFIED");

            // Fresh post-command DTV with Rai 1 HD + DTV -> STATE_VERIFIED
            postIndex.set(0);
            captureAtCallTime[0] = true;
            fixedPost[0] = null;
            nextPostSnaps.clear();
            nextPostSnaps.add(snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE,
                    TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY, Arrays.asList("Rai 1 HD", "DTV"), System.currentTimeMillis()));
            JSONObject dtvVerifiedRes = ctrl.processQuery("digitale terrestre", false);
            assertEquals(true, dtvVerifiedRes.optBoolean("success"), "fresh DTV Rai 1 + DTV verified");
            assertEquals(AkaiAiController.OUTCOME_STATE_VERIFIED, dtvVerifiedRes.optString("execution_outcome"), "fresh DTV STATE_VERIFIED");
            assertEquals("SUCCESS_VERIFIED", dtvVerifiedRes.optString("status"), "fresh DTV SUCCESS_VERIFIED");

            // Autonomous/cloud-planned TV input without DTV UI proof -> COMMAND_SENT, learned_new_procedure=false, 0 SQLite procedures
            AkaiAiController.setStrictLocalOnly(false);
            memEngine.resetForTest();
            postIndex.set(0);
            captureAtCallTime[0] = true;
            nextPostSnaps.clear();
            nextPostSnaps.add(snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE,
                    TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY, Collections.<String>emptyList(), System.currentTimeMillis()));
            JSONObject autoDtvRes = ctrl.processQuery("metti per favore il tuner dell antenna", false);
            assertEquals(false, autoDtvRes.optBoolean("success", true), "autonomous DTV unverified -> success=false");
            assertEquals(false, autoDtvRes.optBoolean("verified", true), "autonomous DTV unverified -> verified=false");
            assertEquals(false, autoDtvRes.optBoolean("learned_new_procedure", true), "autonomous DTV unverified never learns procedure");
            assertEquals(AkaiAiController.OUTCOME_COMMAND_SENT, autoDtvRes.optString("execution_outcome"), "autonomous DTV COMMAND_SENT");
            assertEquals("COMPLETED_UNVERIFIED", autoDtvRes.optString("status"), "autonomous DTV COMPLETED_UNVERIFIED");
            assertEquals(true, autoDtvRes.optBoolean("needs_visual_confirmation"), "autonomous DTV needs_visual_confirmation=true");
            assertEquals(0, memEngine.getAllProcedures().length(), "autonomous DTV unverified saves 0 procedures");
        } finally {
            AkaiAiController.setStrictLocalOnly(prevStrictLocal);
            AkaiAiController.setDefaultPollIntervalMsForTest(150L);
            memEngine.resetForTest();
        }

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
