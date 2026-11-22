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

    private static ScreenPerceptionEngine.PerceptionSnapshot snapFull(
            String pkg, String activity, long activityTs, List<String> texts, long captureTs) {
        return new ScreenPerceptionEngine.PerceptionSnapshot(
                pkg,
                activity,
                activityTs,
                texts,
                Collections.<ScreenPerceptionEngine.ClickableElement>emptyList(),
                null,
                false,
                false,
                false,
                captureTs);
    }

    public static void main(String[] args) throws Exception {
        // 1. LocalIntentParser must attach pkg_is com.mediatek.wwtv.tvcenter to all TV inputs + numeric/named channels + catalog
        for (String q : Arrays.asList("digitale terrestre", "hdmi 1", "passa a hdmi 2", "metti hdmi 3", "ingressi", "canale 5", "metti rai 1")) {
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

        // 3b-bis. ChatGPT PR #18 residual edge-cases (#issuecomment-7078866992):
        //   (1) Bare channel labels without DTV/tuner/EPG origin fail closed
        for (String bareChannel : Arrays.asList("Rai 1 HD", "Canale 5", "CH 001")) {
            ScreenPerceptionEngine.PerceptionSnapshot bareSnap =
                    snapFull(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                            nowMs, Collections.singletonList(bareChannel), nowMs);
            GoalEvidenceVerifier.Verdict bareV = GoalEvidenceVerifier.verify(
                    "digitale terrestre", tvCond, bareSnap, nowMs, nowMs - 10L);
            assertTrue(!bareV.satisfied && "tv_input".equals(bareV.goalKind),
                    "DTV DENIED on bare channel label without DTV/tuner/EPG origin: " + bareChannel);
        }
        for (List<String> corroborated : Arrays.asList(
                Arrays.asList("Rai 1 HD", "DTV"),
                Arrays.asList("Canale 5", "DVB-T2"),
                Arrays.asList("Guida TV", "Rai 1"))) {
            ScreenPerceptionEngine.PerceptionSnapshot corrSnap =
                    snapFull(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                            nowMs, corroborated, nowMs);
            assertTrue(GoalEvidenceVerifier.verify("digitale terrestre", tvCond, corrSnap, nowMs, nowMs - 10L).satisfied,
                    "DTV ALLOWED with corroborated DTV/tuner/EPG origin: " + corroborated);
        }

        //   (2a) Stale intra-package Activity event vs fresh snapshot capture timestamp
        ScreenPerceptionEngine.PerceptionSnapshot staleActBeyondWindow =
                snapFull(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_INPUTS_ACTIVITY,
                        nowMs - 20_000L, Collections.<String>emptyList(), nowMs);
        GoalEvidenceVerifier.Verdict staleActV1 = GoalEvidenceVerifier.verify(
                "ingressi", tvCond, staleActBeyondWindow, nowMs, 0L);
        assertTrue(!staleActV1.satisfied && staleActV1.observedFinalStateOnly,
                "input_source DENIED when capture is fresh but activityTs > 15s old (observedFinalStateOnly=true)");

        ScreenPerceptionEngine.PerceptionSnapshot staleActBeforeCmd =
                snapFull(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_INPUTS_ACTIVITY,
                        nowMs - 50L, Collections.<String>emptyList(), nowMs);
        GoalEvidenceVerifier.Verdict staleActV2 = GoalEvidenceVerifier.verify(
                "ingressi", tvCond, staleActBeforeCmd, nowMs, nowMs);
        assertTrue(!staleActV2.satisfied && staleActV2.observedFinalStateOnly,
                "input_source DENIED when capture >= cmdTs but intra-package activityTs < cmdTs");

        ScreenPerceptionEngine.PerceptionSnapshot freshActOk =
                snapFull(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_INPUTS_ACTIVITY,
                        nowMs, Collections.<String>emptyList(), nowMs);
        assertTrue(GoalEvidenceVerifier.verify("ingressi", tvCond, freshActOk, nowMs, nowMs).satisfied,
                "input_source ALLOWED when both activityTs and captureTs >= cmdTs");

        //   (2b) Observed unchanged final state vs command-attributed transition
        ScreenPerceptionEngine.PerceptionSnapshot preDtvIdentical =
                snapFull(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                        nowMs - 200L, Arrays.asList("Rai 1 HD", "DTV"), nowMs - 200L);
        ScreenPerceptionEngine.PerceptionSnapshot postDtvIdentical =
                snapFull(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                        nowMs - 200L, Arrays.asList("Rai 1 HD", "DTV"), nowMs);
        GoalEvidenceVerifier.Verdict unchangedDtvV = GoalEvidenceVerifier.verify(
                "digitale terrestre", tvCond, preDtvIdentical, postDtvIdentical, nowMs, nowMs - 10L);
        assertTrue(!unchangedDtvV.satisfied && unchangedDtvV.observedFinalStateOnly,
                "Identical pre/post DTV snapshot denied as observedFinalStateOnly=true");

        ScreenPerceptionEngine.PerceptionSnapshot preHome =
                snapFull("it.akai.customhome.v8", "it.akai.customhome.MainActivity",
                        nowMs - 200L, Collections.singletonList("Home"), nowMs - 200L);
        GoalEvidenceVerifier.Verdict changedDtvV = GoalEvidenceVerifier.verify(
                "digitale terrestre", tvCond, preHome, postDtvIdentical, nowMs, nowMs - 10L);
        assertTrue(changedDtvV.satisfied && !changedDtvV.observedFinalStateOnly,
                "Pre Home -> Post DTV transition verified (observedFinalStateOnly=false)");

        ScreenPerceptionEngine.PerceptionSnapshot preHdmiIdentical =
                snapFull(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                        nowMs - 200L, Arrays.asList("HDMI 1", "1920x1080"), nowMs - 200L);
        ScreenPerceptionEngine.PerceptionSnapshot postHdmiIdentical =
                snapFull(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                        nowMs - 200L, Arrays.asList("HDMI 1", "1920x1080"), nowMs);
        GoalEvidenceVerifier.Verdict unchangedHdmiV = GoalEvidenceVerifier.verify(
                "hdmi 1", tvCond, preHdmiIdentical, postHdmiIdentical, nowMs, nowMs - 10L);
        assertTrue(!unchangedHdmiV.satisfied && unchangedHdmiV.observedFinalStateOnly,
                "Identical pre/post HDMI 1 snapshot denied as observedFinalStateOnly=true");

        //   (3) Keyword precedence & action-aware tune_channel / select_channel verifier tests
        ScreenPerceptionEngine.PerceptionSnapshot playerActiveEmptyTv = new ScreenPerceptionEngine.PerceptionSnapshot(
                TvInputIntentPolicy.TV_CENTER_PACKAGE,
                TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                nowMs,
                Collections.<String>emptyList(),
                Collections.<ScreenPerceptionEngine.ClickableElement>emptyList(),
                null,
                false,
                true,
                true,
                nowMs);
        for (String bypassPhrase : Arrays.asList("guarda hdmi 1", "guarda il digitale terrestre", "elenco canali")) {
            GoalEvidenceVerifier.Verdict bypassV = GoalEvidenceVerifier.verify(
                    bypassPhrase, tvCond, preHome, playerActiveEmptyTv, nowMs, nowMs - 10L, null);
            assertTrue(!bypassV.satisfied && "tv_input".equals(bypassV.goalKind),
                    "TV input precedence blocks mentionsPlayback bypass for: " + bypassPhrase);
        }
        ScreenPerceptionEngine.PerceptionSnapshot raiPlayOk = new ScreenPerceptionEngine.PerceptionSnapshot(
                "it.rainet.androidtv", null, nowMs, Collections.singletonList("Rai 1 HD"),
                Collections.<ScreenPerceptionEngine.ClickableElement>emptyList(), null, false, true, true, nowMs);
        assertTrue(GoalEvidenceVerifier.verify("metti Rai 1 in diretta", null, preHome, raiPlayOk, nowMs, nowMs - 10L, null).satisfied,
                "Streaming app RaiPlay goal preserves playback verdict");

        JSONArray tuneCh5 = new JSONArray().put(new JSONObject().put("type", "tune_channel").put("number", 5));
        JSONArray selectCh5 = new JSONArray().put(new JSONObject().put("type", "select_channel").put("number", 5));
        JSONArray badCh0 = new JSONArray().put(new JSONObject().put("type", "tune_channel").put("number", 0));
        JSONArray badCh10000 = new JSONArray().put(new JSONObject().put("type", "select_channel").put("number", 10000));
        ScreenPerceptionEngine.PerceptionSnapshot ch5Ok = snapFull(
                TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                nowMs, Arrays.asList("DTV", "CH 005", "Canale 5"), nowMs);
        assertTrue(GoalEvidenceVerifier.verify("vai su Mediaset", tvCond, preHome, ch5Ok, nowMs, nowMs - 10L, tuneCh5).satisfied,
                "Action-aware tune_channel 5 verified with fresh transitioned DTV+CH005");
        assertTrue(GoalEvidenceVerifier.verify("vai su Mediaset", tvCond, preHome, ch5Ok, nowMs, nowMs - 10L, selectCh5).satisfied,
                "Action-aware select_channel 5 verified with fresh transitioned DTV+CH005");
        assertTrue(!GoalEvidenceVerifier.verify("canale 5", tvCond, preHome, snapFull(
                TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                nowMs, Collections.<String>emptyList(), nowMs), nowMs, nowMs - 10L, tuneCh5).satisfied,
                "tune_channel 5 denied on bare empty tvcenter");
        assertTrue(!GoalEvidenceVerifier.verify("canale 5", tvCond, preHome, snapFull(
                TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                nowMs, Collections.singletonList("Canale 5"), nowMs), nowMs, nowMs - 10L, tuneCh5).satisfied,
                "tune_channel 5 denied on bare Canale 5 without DTV origin");
        assertTrue(!GoalEvidenceVerifier.verify("canale 5", tvCond, preHome, snapFull(
                TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                nowMs, Arrays.asList("DTV", "CH 050"), nowMs), nowMs, nowMs - 10L, tuneCh5).satisfied,
                "tune_channel 5 denied on wrong channel CH 050");
        assertTrue(!GoalEvidenceVerifier.verify("canale 5", tvCond, preHome, snapFull(
                TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                nowMs, Arrays.asList("Guida TV", "CH 001", "CH 005"), nowMs), nowMs, nowMs - 10L, tuneCh5).satisfied,
                "tune_channel 5 denied on multi-channel EPG list");
        assertTrue(!GoalEvidenceVerifier.verify("canale 5", tvCond, preHome, snapFull(
                TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                nowMs, Arrays.asList("DTV", "19:05"), nowMs), nowMs, nowMs - 10L, tuneCh5).satisfied,
                "tune_channel 5 denied when only clock 19:05 is visible");
        assertTrue(!GoalEvidenceVerifier.verify("canale 5", tvCond, preHome, snapFull(
                TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                nowMs, Arrays.asList("HDMI 1", "DTV", "CH 005"), nowMs), nowMs, nowMs - 10L, tuneCh5).satisfied,
                "tune_channel 5 denied when HDMI 1 external source visible");
        assertTrue(!GoalEvidenceVerifier.verify("canale 5", tvCond, preHome, dtvInputsPanelOpen, nowMs, nowMs - 10L, tuneCh5).satisfied,
                "tune_channel 5 denied while InputsPanelActivity open");
        assertTrue(!GoalEvidenceVerifier.verify("canale 5", tvCond, preHome, snapFull(
                TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                nowMs - 50L, Arrays.asList("DTV", "CH 005"), nowMs - 50L), nowMs, nowMs, tuneCh5).satisfied,
                "tune_channel 5 denied on stale pre-command snapshot");
        GoalEvidenceVerifier.Verdict unchangedCh5V = GoalEvidenceVerifier.verify("canale 5", tvCond,
                snapFull(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                        nowMs - 200L, Arrays.asList("DTV", "CH 005", "Canale 5"), nowMs - 200L),
                snapFull(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                        nowMs - 200L, Arrays.asList("DTV", "CH 005", "Canale 5"), nowMs),
                nowMs, nowMs - 10L, tuneCh5);
        assertTrue(!unchangedCh5V.satisfied && unchangedCh5V.observedFinalStateOnly,
                "Identical pre/post channel 5 snapshot denied as observedFinalStateOnly=true");
        assertTrue(!GoalEvidenceVerifier.verify("canale 0", tvCond, preHome, ch5Ok, nowMs, nowMs - 10L, badCh0).satisfied,
                "Invalid tune_channel 0 rejected");
        assertTrue(!GoalEvidenceVerifier.verify("canale 10000", tvCond, preHome, ch5Ok, nowMs, nowMs - 10L, badCh10000).satisfied,
                "Invalid select_channel 10000 rejected");

        // 3c. End-to-end AkaiAiController.createForTest verification (fast-path, autonomous & visual mode)
        boolean prevStrictLocal = AkaiAiController.isStrictLocalOnly();
        android.content.Context testCtx = new android.content.Context() {};
        AkaiMemoryEngine memEngine = AkaiMemoryEngine.getInstance(testCtx);
        memEngine.resetForTest();
        try {
            AkaiAiController.setDefaultPollIntervalMsForTest(0L);
            final List<ScreenPerceptionEngine.PerceptionSnapshot> nextPostSnaps = new ArrayList<>();
            final AtomicInteger postIndex = new AtomicInteger(0);
            final boolean[] captureAtCallTime = new boolean[] { true };
            final boolean[] actionDispatched = new boolean[] { false };
            final ScreenPerceptionEngine.PerceptionSnapshot[] fixedPre = new ScreenPerceptionEngine.PerceptionSnapshot[1];
            final ScreenPerceptionEngine.PerceptionSnapshot[] fixedPost = new ScreenPerceptionEngine.PerceptionSnapshot[1];
            final JSONArray[] cloudPlannedActions = new JSONArray[1];
            final String[] cloudPlannedCondition = new String[] { tvCond };

            AkaiAiController.PerceptionAndExecutionBridge mockBridge = new AkaiAiController.PerceptionAndExecutionBridge() {
                @Override
                public ScreenPerceptionEngine.PerceptionSnapshot capture(android.content.Context c) {
                    int idx = postIndex.getAndIncrement();
                    if (idx == 0 || !actionDispatched[0]) {
                        if (fixedPre[0] != null) {
                            return fixedPre[0];
                        }
                        return snapWithActivity("it.akai.customhome.v8", null, Collections.singletonList("Home"), System.currentTimeMillis());
                    }
                    if (fixedPost[0] != null && !captureAtCallTime[0]) {
                        return fixedPost[0];
                    }
                    if (!nextPostSnaps.isEmpty()) {
                        ScreenPerceptionEngine.PerceptionSnapshot tmpl = nextPostSnaps.get(0);
                        long postNow = System.currentTimeMillis();
                        long actTs = (tmpl.foregroundActivityTimestamp > 0L)
                                ? Math.max(tmpl.foregroundActivityTimestamp, postNow)
                                : 0L;
                        return snapFull(tmpl.foregroundPackage, tmpl.foregroundActivity, actTs, tmpl.visibleTexts, postNow);
                    }
                    return snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE, null, Collections.<String>emptyList(), System.currentTimeMillis());
                }

                @Override
                public TvController.CommandResult executeActions(JSONArray actions) {
                    actionDispatched[0] = true;
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
                    JSONArray acts = cloudPlannedActions[0];
                    if (acts == null) {
                        acts = new JSONArray();
                        try {
                            acts.put(new JSONObject().put("type", "command").put("action", "input_tv"));
                        } catch (Exception ignored) {}
                    }
                    return new AiResponse(
                            true,
                            "Passo al digitale terrestre...",
                            acts,
                            "autonomous_dtv_switch",
                            userGoal,
                            cloudPlannedCondition[0],
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

            // Edge-case #1 E2E: bare "Rai 1 HD" alone -> COMMAND_SENT / COMPLETED_UNVERIFIED / needs_visual_confirmation=true
            memEngine.resetForTest();
            postIndex.set(0);
            captureAtCallTime[0] = true;
            fixedPre[0] = null;
            fixedPost[0] = null;
            nextPostSnaps.clear();
            nextPostSnaps.add(snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE,
                    TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY, Collections.singletonList("Rai 1 HD"), System.currentTimeMillis()));
            JSONObject bareDtvE2E = ctrl.processQuery("digitale terrestre", false);
            assertEquals(false, bareDtvE2E.optBoolean("success", true), "E2E bare Rai 1 HD success=false");
            assertEquals(AkaiAiController.OUTCOME_COMMAND_SENT, bareDtvE2E.optString("execution_outcome"), "E2E bare Rai 1 HD COMMAND_SENT");
            assertEquals("COMPLETED_UNVERIFIED", bareDtvE2E.optString("status"), "E2E bare Rai 1 HD COMPLETED_UNVERIFIED");
            assertEquals(true, bareDtvE2E.optBoolean("needs_visual_confirmation"), "E2E bare Rai 1 HD visual confirmation");
            assertEquals(0, memEngine.getAllProcedures().length(), "E2E bare Rai 1 HD saves 0 procedures");

            // Edge-case #2a E2E: fresh captureTs (now) + stale intra-package InputsPanelActivity (now - 5000L)
            long t2a = System.currentTimeMillis();
            memEngine.resetForTest();
            postIndex.set(0);
            captureAtCallTime[0] = false;
            fixedPre[0] = snapFull("it.akai.customhome.v8", "it.akai.customhome.MainActivity", t2a - 6000L,
                    Collections.singletonList("Home"), t2a);
            fixedPost[0] = snapFull(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_INPUTS_ACTIVITY,
                    t2a - 5000L, Collections.<String>emptyList(), t2a + 50L);
            JSONObject staleActE2E = ctrl.processQuery("ingressi", false);
            assertEquals(false, staleActE2E.optBoolean("success", true), "E2E stale intra-pkg InputsPanel success=false");
            assertEquals(AkaiAiController.OUTCOME_COMMAND_SENT, staleActE2E.optString("execution_outcome"), "E2E stale intra-pkg COMMAND_SENT");
            assertEquals("COMPLETED_UNVERIFIED", staleActE2E.optString("status"), "E2E stale intra-pkg COMPLETED_UNVERIFIED");
            assertEquals(true, staleActE2E.optBoolean("observed_final_state_only"), "E2E stale intra-pkg observed_final_state_only=true");
            assertEquals(true, staleActE2E.optBoolean("needs_visual_confirmation"), "E2E stale intra-pkg needs_visual_confirmation=true");
            assertEquals(0, memEngine.getAllProcedures().length(), "E2E stale intra-pkg saves 0 procedures");

            // Edge-case #2b E2E: identical preSnap & postSnap DTV -> observed_final_state_only=true / COMPLETED_UNVERIFIED
            long t2b = System.currentTimeMillis();
            memEngine.resetForTest();
            postIndex.set(0);
            captureAtCallTime[0] = false;
            fixedPre[0] = snapFull(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                    t2b - 500L, Arrays.asList("Rai 1 HD", "DTV"), t2b);
            fixedPost[0] = snapFull(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                    t2b - 500L, Arrays.asList("Rai 1 HD", "DTV"), t2b + 50L);
            JSONObject unchangedE2E = ctrl.processQuery("digitale terrestre", false);
            assertEquals(false, unchangedE2E.optBoolean("success", true), "E2E identical pre/post DTV success=false");
            assertEquals(AkaiAiController.OUTCOME_COMMAND_SENT, unchangedE2E.optString("execution_outcome"), "E2E identical pre/post COMMAND_SENT");
            assertEquals("COMPLETED_UNVERIFIED", unchangedE2E.optString("status"), "E2E identical pre/post COMPLETED_UNVERIFIED");
            assertEquals(true, unchangedE2E.optBoolean("observed_final_state_only"), "E2E identical pre/post observed_final_state_only=true");
            assertEquals(true, unchangedE2E.optBoolean("needs_visual_confirmation"), "E2E identical pre/post needs_visual_confirmation=true");
            assertEquals(0, memEngine.getAllProcedures().length(), "E2E identical pre/post saves 0 procedures");

            // 3c-bis (1). Fast-path "canale 5" & "metti rai 1" E2E fail-closed & verified paths
            for (List<String> unverifiedChTexts : Arrays.asList(
                    Collections.<String>emptyList(),
                    Collections.singletonList("Canale 5"),
                    Arrays.asList("HDMI 1", "1080p"))) {
                memEngine.resetForTest();
                postIndex.set(0);
                actionDispatched[0] = false;
                captureAtCallTime[0] = true;
                fixedPre[0] = null;
                fixedPost[0] = null;
                nextPostSnaps.clear();
                nextPostSnaps.add(snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE,
                        TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY, unverifiedChTexts, System.currentTimeMillis()));
                JSONObject chUnv = ctrl.processQuery("canale 5", false);
                assertEquals(false, chUnv.optBoolean("success", true), "fast-path canale 5 unverified: " + unverifiedChTexts);
                assertEquals(false, chUnv.optBoolean("verified", true), "fast-path canale 5 verified=false: " + unverifiedChTexts);
                assertEquals(AkaiAiController.OUTCOME_COMMAND_SENT, chUnv.optString("execution_outcome"), "fast-path canale 5 COMMAND_SENT");
                assertEquals("COMPLETED_UNVERIFIED", chUnv.optString("status"), "fast-path canale 5 COMPLETED_UNVERIFIED");
                assertEquals(true, chUnv.optBoolean("needs_visual_confirmation"), "fast-path canale 5 needs_visual_confirmation=true");
                assertEquals(0, memEngine.getAllProcedures().length(), "fast-path canale 5 unverified saves 0 procedures");
            }

            long tStaleCh = System.currentTimeMillis();
            memEngine.resetForTest();
            postIndex.set(0);
            actionDispatched[0] = false;
            captureAtCallTime[0] = false;
            fixedPre[0] = snapFull("it.akai.customhome.v8", "it.akai.customhome.MainActivity", tStaleCh - 5000L,
                    Collections.singletonList("Home"), tStaleCh);
            fixedPost[0] = snapFull(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                    tStaleCh - 5000L, Arrays.asList("DTV", "CH 005", "Canale 5"), tStaleCh - 5000L);
            JSONObject staleChE2E = ctrl.processQuery("canale 5", false);
            assertEquals(false, staleChE2E.optBoolean("success", true), "fast-path canale 5 stale success=false");
            assertEquals(AkaiAiController.OUTCOME_COMMAND_SENT, staleChE2E.optString("execution_outcome"), "fast-path canale 5 stale COMMAND_SENT");
            assertEquals("COMPLETED_UNVERIFIED", staleChE2E.optString("status"), "fast-path canale 5 stale COMPLETED_UNVERIFIED");
            assertEquals(true, staleChE2E.optBoolean("needs_visual_confirmation"), "fast-path canale 5 stale visual confirmation");

            long tUnchCh = System.currentTimeMillis();
            memEngine.resetForTest();
            postIndex.set(0);
            actionDispatched[0] = false;
            captureAtCallTime[0] = false;
            fixedPre[0] = snapFull(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                    tUnchCh - 500L, Arrays.asList("DTV", "CH 005", "Canale 5"), tUnchCh);
            fixedPost[0] = snapFull(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                    tUnchCh - 500L, Arrays.asList("DTV", "CH 005", "Canale 5"), tUnchCh + 50L);
            JSONObject unchChE2E = ctrl.processQuery("canale 5", false);
            assertEquals(false, unchChE2E.optBoolean("success", true), "fast-path canale 5 unchanged success=false");
            assertEquals(AkaiAiController.OUTCOME_COMMAND_SENT, unchChE2E.optString("execution_outcome"), "fast-path canale 5 unchanged COMMAND_SENT");
            assertEquals("COMPLETED_UNVERIFIED", unchChE2E.optString("status"), "fast-path canale 5 unchanged COMPLETED_UNVERIFIED");
            assertEquals(true, unchChE2E.optBoolean("observed_final_state_only"), "fast-path canale 5 unchanged observed_final_state_only=true");
            assertEquals(true, unchChE2E.optBoolean("needs_visual_confirmation"), "fast-path canale 5 unchanged visual confirmation");

            for (String[] pair : Arrays.asList(
                    new String[] { "canale 5", "CH 005", "Canale 5" },
                    new String[] { "metti rai 1", "CH 001", "Rai 1" })) {
                memEngine.resetForTest();
                postIndex.set(0);
                actionDispatched[0] = false;
                captureAtCallTime[0] = true;
                fixedPre[0] = null;
                fixedPost[0] = null;
                nextPostSnaps.clear();
                nextPostSnaps.add(snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE,
                        TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY, Arrays.asList("DTV", pair[1], pair[2]), System.currentTimeMillis()));
                JSONObject chOkRes = ctrl.processQuery(pair[0], false);
                assertEquals(true, chOkRes.optBoolean("success"), "fast-path verified success=true for " + pair[0]);
                assertEquals(true, chOkRes.optBoolean("verified"), "fast-path verified=true for " + pair[0]);
                assertEquals(AkaiAiController.OUTCOME_STATE_VERIFIED, chOkRes.optString("execution_outcome"), "fast-path STATE_VERIFIED for " + pair[0]);
                assertEquals("SUCCESS_VERIFIED", chOkRes.optString("status"), "fast-path SUCCESS_VERIFIED for " + pair[0]);
            }

            // 3c-bis (2). Autonomous/cloud-planned tune_channel(105) & select_channel(105)
            AkaiAiController.setStrictLocalOnly(false);
            for (String actionType : Arrays.asList("tune_channel", "select_channel")) {
                cloudPlannedCondition[0] = tvCond;
                cloudPlannedActions[0] = new JSONArray().put(new JSONObject().put("type", actionType).put("number", 105));

                for (List<String> failTexts : Arrays.asList(
                        Collections.<String>emptyList(),
                        Arrays.asList("Rai 1 HD", "DTV"))) {
                    memEngine.resetForTest();
                    postIndex.set(0);
                    actionDispatched[0] = false;
                    captureAtCallTime[0] = true;
                    fixedPre[0] = null;
                    fixedPost[0] = null;
                    nextPostSnaps.clear();
                    nextPostSnaps.add(snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE,
                            TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY, failTexts, System.currentTimeMillis()));
                    JSONObject autoChFail = ctrl.processQuery("vai al centocinque", false);
                    assertEquals(false, autoChFail.optBoolean("success", true), actionType + " 105 unverified -> success=false");
                    assertEquals(false, autoChFail.optBoolean("verified", true), actionType + " 105 unverified -> verified=false");
                    assertEquals(false, autoChFail.optBoolean("learned_new_procedure", true), actionType + " 105 unverified -> learned=false");
                    assertEquals(AkaiAiController.OUTCOME_COMMAND_SENT, autoChFail.optString("execution_outcome"), actionType + " 105 COMMAND_SENT");
                    assertEquals("COMPLETED_UNVERIFIED", autoChFail.optString("status"), actionType + " 105 COMPLETED_UNVERIFIED");
                    assertEquals(true, autoChFail.optBoolean("needs_visual_confirmation"), actionType + " 105 visual confirmation");
                    assertEquals(0, memEngine.getAllProcedures().length(), actionType + " 105 unverified saves 0 procedures");
                }

                memEngine.resetForTest();
                postIndex.set(0);
                actionDispatched[0] = false;
                captureAtCallTime[0] = true;
                fixedPre[0] = null;
                fixedPost[0] = null;
                nextPostSnaps.clear();
                nextPostSnaps.add(snapWithActivity(TvInputIntentPolicy.TV_CENTER_PACKAGE,
                        TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY, Arrays.asList("DTV", "CH 105"), System.currentTimeMillis()));
                JSONObject autoChOk = ctrl.processQuery("vai al centocinque", false);
                assertEquals(true, autoChOk.optBoolean("success"), actionType + " 105 verified success=true");
                assertEquals(true, autoChOk.optBoolean("verified"), actionType + " 105 verified=true");
                assertEquals(true, autoChOk.optBoolean("learned_new_procedure"), actionType + " 105 learned=true");
                assertEquals(AkaiAiController.OUTCOME_STATE_VERIFIED, autoChOk.optString("execution_outcome"), actionType + " 105 STATE_VERIFIED");
                assertEquals("SUCCESS_VERIFIED", autoChOk.optString("status"), actionType + " 105 SUCCESS_VERIFIED");
                assertEquals(1, memEngine.getAllProcedures().length(), actionType + " 105 saves 1 SQLite procedure");
            }

            // 3c-bis (3). Visual mode (processVisualGoalLocked) fail-closed on stale & unchanged TV snapshots
            it.akai.customremote.ai.VisualObservationProvider.Session mockVisualSession =
                    new it.akai.customremote.ai.VisualObservationProvider.Session() {
                @Override
                public it.akai.customremote.ai.VisualObservationProvider.Result observe(
                        String provider, String pkg, String ui,
                        it.akai.customremote.ai.VisualObservationProvider.Cancellation cancel) {
                    return it.akai.customremote.ai.VisualObservationProvider.Result.observed(
                            provider, pkg, ui, "Schermata TV corrente", System.currentTimeMillis(), 10, 0.0);
                }
            };
            assertTrue(it.akai.customremote.ai.VisualObservationProvider.install(mockVisualSession),
                    "Install mock visual session for TV fail-closed regression");
            try {
                cloudPlannedCondition[0] = tvCond;
                for (JSONObject visualAct : Arrays.asList(
                        new JSONObject().put("type", "command").put("action", "input_tv"),
                        new JSONObject().put("type", "tune_channel").put("number", 5))) {
                    long tVisStale = System.currentTimeMillis();
                    memEngine.resetForTest();
                    postIndex.set(0);
                    actionDispatched[0] = false;
                    captureAtCallTime[0] = false;
                    cloudPlannedActions[0] = new JSONArray().put(visualAct);
                    fixedPre[0] = snapFull("it.akai.customhome.v8", "it.akai.customhome.MainActivity", tVisStale - 6000L,
                            Collections.singletonList("Home"), tVisStale);
                    fixedPost[0] = snapFull(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                            tVisStale - 5000L, Arrays.asList("DTV", "CH 005", "Canale 5"), tVisStale - 5000L);
                    JSONObject visStaleRes = ctrl.processQuery("metti tv visivo", false);
                    assertEquals(false, visStaleRes.optBoolean("verified", true), "visual stale verified=false for " + visualAct);
                    assertEquals(false, visStaleRes.optBoolean("learned_new_procedure", true), "visual stale learned=false");
                    assertEquals(AkaiAiController.OUTCOME_COMMAND_SENT, visStaleRes.optString("execution_outcome"), "visual stale COMMAND_SENT");
                    assertEquals("COMPLETED_UNVERIFIED", visStaleRes.optString("status"), "visual stale COMPLETED_UNVERIFIED");
                    assertEquals(true, visStaleRes.optBoolean("needs_visual_confirmation"), "visual stale needs_visual_confirmation=true");
                    assertEquals(0, memEngine.getAllProcedures().length(), "visual stale saves 0 procedures");
                }

                long tVisUnch = System.currentTimeMillis();
                memEngine.resetForTest();
                postIndex.set(0);
                actionDispatched[0] = false;
                captureAtCallTime[0] = false;
                cloudPlannedActions[0] = new JSONArray().put(new JSONObject().put("type", "tune_channel").put("number", 5));
                fixedPre[0] = snapFull(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                        tVisUnch - 500L, Arrays.asList("DTV", "CH 005", "Canale 5"), tVisUnch);
                fixedPost[0] = snapFull(TvInputIntentPolicy.TV_CENTER_PACKAGE, TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY,
                        tVisUnch - 500L, Arrays.asList("DTV", "CH 005", "Canale 5"), tVisUnch + 50L);
                JSONObject visUnchRes = ctrl.processQuery("metti canale cinque visivo", false);
                assertEquals(false, visUnchRes.optBoolean("verified", true), "visual unchanged verified=false");
                assertEquals(false, visUnchRes.optBoolean("learned_new_procedure", true), "visual unchanged learned=false");
                assertEquals(AkaiAiController.OUTCOME_COMMAND_SENT, visUnchRes.optString("execution_outcome"), "visual unchanged COMMAND_SENT");
                assertEquals("COMPLETED_UNVERIFIED", visUnchRes.optString("status"), "visual unchanged COMPLETED_UNVERIFIED");
                assertEquals(true, visUnchRes.optBoolean("needs_visual_confirmation"), "visual unchanged needs_visual_confirmation=true");
                assertEquals(true, visUnchRes.optBoolean("observed_final_state_only"), "visual unchanged observed_final_state_only=true");
                assertEquals(0, memEngine.getAllProcedures().length(), "visual unchanged saves 0 procedures");
            } finally {
                it.akai.customremote.ai.VisualObservationProvider.clear(mockVisualSession);
            }
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
