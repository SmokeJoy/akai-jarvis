package it.akai.customremote;

import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/**
 * Pure JDK 8 host unit tests for TvInputIntentPolicy (TIF alignment with Home v8 + OEM anomaly checks).
 */
public class TvInputIntentPolicyTest {
    private static void assertTrue(boolean cond, String msg) {
        if (!cond) {
            throw new AssertionError("TvInputIntentPolicyTest failed: " + msg);
        }
    }

    private static void assertEquals(Object expected, Object actual, String msg) {
        if (expected == null ? actual != null : !expected.equals(actual)) {
            throw new AssertionError("TvInputIntentPolicyTest failed [" + msg + "]: expected=" + expected + " actual=" + actual);
        }
    }

    public static void main(String[] args) {
        // 1. Passthrough URI encoding parity with Home v8 / Android Uri.encode
        assertEquals(
                "content://android.media.tv/passthrough/com.mediatek.tvinput%2F.hdmi.HDMIInputService%2FHW6",
                TvInputIntentPolicy.buildPassthroughUri(TvInputIntentPolicy.DEFAULT_HDMI1_INPUT_ID),
                "HDMI 1 passthrough URI");
        assertEquals(
                "content://android.media.tv/passthrough/com.mediatek.tvinput%2F.hdmi.HDMIInputService%2FHW7",
                TvInputIntentPolicy.buildPassthroughUri(TvInputIntentPolicy.DEFAULT_HDMI2_INPUT_ID),
                "HDMI 2 passthrough URI");
        assertEquals(
                "content://android.media.tv/passthrough/com.mediatek.tvinput%2F.hdmi.HDMIInputService%2FHW8",
                TvInputIntentPolicy.buildPassthroughUri(TvInputIntentPolicy.DEFAULT_HDMI3_INPUT_ID),
                "HDMI 3 passthrough URI");
        assertEquals(
                "content://android.media.tv/passthrough/com.mediatek.tvinput%2F.tuner.TunerInputService%2FHW0",
                TvInputIntentPolicy.buildPassthroughUri(TvInputIntentPolicy.DEFAULT_DTV_INPUT_ID),
                "DTV passthrough URI");
        assertEquals(null, TvInputIntentPolicy.buildPassthroughUri("  "), "blank inputId");

        // 2. HDMI port label parsing (word-boundary safe)
        assertEquals(1, TvInputIntentPolicy.parseHdmiPortFromLabel("HDMI 1"), "label HDMI 1");
        assertEquals(2, TvInputIntentPolicy.parseHdmiPortFromLabel("HDMI2"), "label HDMI2");
        assertEquals(3, TvInputIntentPolicy.parseHdmiPortFromLabel("Console (HDMI 3)"), "label Fire/Console HDMI 3");
        assertEquals(-1, TvInputIntentPolicy.parseHdmiPortFromLabel("HDMI 10"), "reject HDMI 10");
        assertEquals(-1, TvInputIntentPolicy.parseHdmiPortFromLabel("HDMI 12"), "reject HDMI 12");
        assertEquals(-1, TvInputIntentPolicy.parseHdmiPortFromLabel("Composite"), "unrelated label");
        assertEquals(-1, TvInputIntentPolicy.parseHdmiPortFromLabel(null), "null label");

        // 3. TIF discovery + physical passthrough preference over CEC child nodes
        List<TvInputIntentPolicy.TifInputRecord> discoveredWithCec = Arrays.asList(
                new TvInputIntentPolicy.TifInputRecord(
                        "com.mediatek.tvinput/.hdmi.HDMIInputService/HDMI100004",
                        TvInputIntentPolicy.TYPE_HDMI, 1, 0, false),
                new TvInputIntentPolicy.TifInputRecord(
                        TvInputIntentPolicy.DEFAULT_HDMI1_INPUT_ID,
                        TvInputIntentPolicy.TYPE_HDMI, -1, 0, true),
                new TvInputIntentPolicy.TifInputRecord(
                        "com.mediatek.tvinput/.hdmi.HDMIInputService/HW7",
                        TvInputIntentPolicy.TYPE_HDMI, 2, 1, true),
                new TvInputIntentPolicy.TifInputRecord(
                        "com.mediatek.tvinput/.tuner.TunerInputService/HW10",
                        TvInputIntentPolicy.TYPE_TUNER, -1, 0, true),
                new TvInputIntentPolicy.TifInputRecord(
                        TvInputIntentPolicy.DEFAULT_DTV_INPUT_ID,
                        TvInputIntentPolicy.TYPE_TUNER, -1, 0, true)
        );
        assertEquals(TvInputIntentPolicy.DEFAULT_HDMI1_INPUT_ID,
                TvInputIntentPolicy.resolveHdmiInputId(1, discoveredWithCec),
                "prefer physical /HW6 over non-passthrough CEC node");
        assertEquals(TvInputIntentPolicy.DEFAULT_HDMI2_INPUT_ID,
                TvInputIntentPolicy.resolveHdmiInputId(2, discoveredWithCec),
                "direct hdmiPort=2 match");
        assertEquals(TvInputIntentPolicy.DEFAULT_HDMI3_INPUT_ID,
                TvInputIntentPolicy.resolveHdmiInputId(3, discoveredWithCec),
                "fallback to HW8 when port 3 not in list");
        assertEquals(null, TvInputIntentPolicy.resolveHdmiInputId(0, discoveredWithCec), "invalid port 0");
        assertEquals(null, TvInputIntentPolicy.resolveHdmiInputId(4, discoveredWithCec), "invalid port 4");

        // 4. DTV input resolution
        assertEquals(TvInputIntentPolicy.DEFAULT_DTV_INPUT_ID,
                TvInputIntentPolicy.resolveDtvInputId(discoveredWithCec),
                "prefer HW0 when present");
        assertEquals("com.mediatek.tvinput/.tuner.TunerInputService/HW10",
                TvInputIntentPolicy.resolveDtvInputId(Collections.singletonList(
                        new TvInputIntentPolicy.TifInputRecord(
                                "com.mediatek.tvinput/.tuner.TunerInputService/HW10",
                                TvInputIntentPolicy.TYPE_TUNER, -1, 0, true))),
                "use single discovered tuner");
        assertEquals(TvInputIntentPolicy.DEFAULT_DTV_INPUT_ID,
                TvInputIntentPolicy.resolveDtvInputId(Collections.<TvInputIntentPolicy.TifInputRecord>emptyList()),
                "fallback HW0 on empty discovery");

        // 5. Planned intent chains align with Home v8 and never use com.mediatek.select.*
        List<TvInputIntentPolicy.LaunchSpec> dtvPlan = TvInputIntentPolicy.planCandidatesForAction("input_tv", discoveredWithCec);
        assertEquals(3, dtvPlan.size(), "DTV plan length");
        assertEquals("MAIN_COMPONENT", dtvPlan.get(0).kind, "DTV primary matches Home v8 TurnkeyUiMainActivity");
        assertEquals("android.intent.action.MAIN", dtvPlan.get(0).intentAction, "DTV MAIN action");
        assertEquals("android.intent.category.DEFAULT", dtvPlan.get(0).category, "DTV DEFAULT category");
        assertEquals(TvInputIntentPolicy.TV_CENTER_MAIN_ACTIVITY, dtvPlan.get(0).componentClass, "DTV activity");
        assertEquals("VIEW_TIF_URI_PACKAGED", dtvPlan.get(1).kind, "DTV TIF fallback 1");
        assertEquals("VIEW_TIF_URI_SYSTEM", dtvPlan.get(2).kind, "DTV TIF fallback 2");

        for (String hdmiAct : Arrays.asList("input_hdmi1", "input_hdmi2", "input_hdmi3")) {
            List<TvInputIntentPolicy.LaunchSpec> hPlan = TvInputIntentPolicy.planCandidatesForAction(hdmiAct, discoveredWithCec);
            assertEquals(2, hPlan.size(), hdmiAct + " plan length");
            assertEquals("VIEW_TIF_URI_PACKAGED", hPlan.get(0).kind, hdmiAct + " packaged TIF");
            assertEquals(TvInputIntentPolicy.TV_CENTER_PACKAGE, hPlan.get(0).packageName, hdmiAct + " package");
            assertEquals("VIEW_TIF_URI_SYSTEM", hPlan.get(1).kind, hdmiAct + " system TIF");
            assertEquals(null, hPlan.get(1).packageName, hdmiAct + " system null package");
        }

        List<TvInputIntentPolicy.LaunchSpec> srcPlan = TvInputIntentPolicy.planCandidatesForAction("input_source", discoveredWithCec);
        assertEquals(2, srcPlan.size(), "input_source plan length");
        assertEquals(TvInputIntentPolicy.ACTION_VIEW_INPUTS, srcPlan.get(0).intentAction, "VIEW_INPUTS primary");
        assertEquals(TvInputIntentPolicy.TV_CENTER_INPUTS_ACTIVITY, srcPlan.get(1).componentClass, "InputsPanel fallback");

        for (String act : Arrays.asList("input_tv", "input_hdmi1", "input_hdmi2", "input_hdmi3", "input_source")) {
            for (TvInputIntentPolicy.LaunchSpec s : TvInputIntentPolicy.planCandidatesForAction(act, discoveredWithCec)) {
                String blob = String.valueOf(s.kind) + "|" + s.intentAction + "|" + s.dataUri + "|" + s.componentClass;
                assertTrue(!blob.contains("com.mediatek.select"), "Legacy implicit broadcast forbidden: " + blob);
            }
        }

        // 6. OEM ANR / crash dialog detection (with zero false positives on normal UI)
        assertTrue(TvInputIntentPolicy.detectOemDialogAnomaly("android",
                Arrays.asList("tvcenter non risponde", "Chiudi app", "Attendi")) != null, "Italian ANR");
        assertTrue(TvInputIntentPolicy.detectOemDialogAnomaly("android",
                Arrays.asList("LiveTV isn't responding", "Close app")) != null, "English ANR");
        assertTrue(TvInputIntentPolicy.detectOemDialogAnomaly("android",
                Arrays.asList("com.mediatek.wwtv.tvcenter continua a interrompersi")) != null, "Italian crash dialog");
        assertTrue(TvInputIntentPolicy.detectOemDialogAnomaly("android",
                Arrays.asList("LiveTV has stopped")) != null, "English crash dialog");
        assertEquals(null, TvInputIntentPolicy.detectOemDialogAnomaly(
                TvInputIntentPolicy.TV_CENTER_PACKAGE,
                Arrays.asList("HDMI 1", "1080p", "Rai 1 HD")), "Normal LiveTV OSD");
        assertEquals(null, TvInputIntentPolicy.detectOemDialogAnomaly(
                "it.akai.customhome.v8",
                Arrays.asList("Chiudi app", "YouTube")), "Non-system launcher text should not falsely match");

        System.out.println("TvInputIntentPolicyTest PASS: 16 TIF URI, discovery, candidate order and OEM ANR/crash assertions OK.");
    }
}
