package it.akai.customremote;

import java.nio.charset.StandardCharsets;
import java.text.Normalizer;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.regex.Pattern;

/**
 * Pure Java 8 Android TV Input Framework (TIF) intent and OEM anomaly policy.
 * Mirrors the real working launch mechanisms used by Home v8 without any legacy
 * MediaTek implicit broadcast workarounds (`com.mediatek.select.*` has zero
 * receivers on AKAI AKTV5037N Android 9).
 */
public final class TvInputIntentPolicy {
    public static final String TIF_PASSTHROUGH_PREFIX = "content://android.media.tv/passthrough/";
    public static final String TIF_CHANNEL_MIME_TYPE = "vnd.android.cursor.item/channel";

    public static final String TV_CENTER_PACKAGE = "com.mediatek.wwtv.tvcenter";
    public static final String TV_CENTER_MAIN_ACTIVITY = "com.mediatek.wwtv.tvcenter.nav.TurnkeyUiMainActivity";
    public static final String TV_CENTER_INPUTS_ACTIVITY = "com.mediatek.wwtv.tvcenter.nav.inputpanel.InputsPanelActivity";
    public static final String ACTION_VIEW_INPUTS = "com.android.tv.action.VIEW_INPUTS";

    // Matches android.media.tv.TvInputInfo constants so pure JDK 8 host tests require no Android stubs.
    public static final int TYPE_TUNER = 0;
    public static final int TYPE_HDMI = 1007;

    public static final String DEFAULT_DTV_INPUT_ID = "com.mediatek.tvinput/.tuner.TunerInputService/HW0";
    public static final String DEFAULT_HDMI1_INPUT_ID = "com.mediatek.tvinput/.hdmi.HDMIInputService/HW6";
    public static final String DEFAULT_HDMI2_INPUT_ID = "com.mediatek.tvinput/.hdmi.HDMIInputService/HW7";
    public static final String DEFAULT_HDMI3_INPUT_ID = "com.mediatek.tvinput/.hdmi.HDMIInputService/HW8";

    private static final Pattern DTV_CHANNEL_NUM_PATTERN =
            Pattern.compile("(?:^| )(?:dtv|dvbt|dvbt2) [0-9]{1,3}(?: |$)");

    private TvInputIntentPolicy() {}

    public static final class TifInputRecord {
        public final String inputId;
        public final int type;
        public final int hdmiPort;
        public final int state;
        public final boolean passthrough;

        public TifInputRecord(String inputId, int type, int hdmiPort, int state, boolean passthrough) {
            this.inputId = inputId;
            this.type = type;
            this.hdmiPort = hdmiPort;
            this.state = state;
            this.passthrough = passthrough;
        }
    }

    public static final class LaunchSpec {
        public final String kind;
        public final String intentAction;
        public final String category;
        public final String packageName;
        public final String componentClass;
        public final String dataUri;
        public final String inputId;

        public LaunchSpec(String kind, String intentAction, String category,
                          String packageName, String componentClass, String dataUri, String inputId) {
            this.kind = kind;
            this.intentAction = intentAction;
            this.category = category;
            this.packageName = packageName;
            this.componentClass = componentClass;
            this.dataUri = dataUri;
            this.inputId = inputId;
        }
    }

    private static boolean notBlank(String s) {
        return s != null && !s.trim().isEmpty();
    }

    public static String encodePassthroughInputId(String inputId) {
        if (!notBlank(inputId)) return "";
        byte[] bytes = inputId.trim().getBytes(StandardCharsets.UTF_8);
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            int c = b & 0xFF;
            boolean unreserved = (c >= 'a' && c <= 'z')
                    || (c >= 'A' && c <= 'Z')
                    || (c >= '0' && c <= '9')
                    || c == '-' || c == '.' || c == '_' || c == '~';
            if (unreserved) {
                sb.append((char) c);
            } else {
                sb.append('%');
                char hi = Character.toUpperCase(Character.forDigit((c >> 4) & 0xF, 16));
                char lo = Character.toUpperCase(Character.forDigit(c & 0xF, 16));
                sb.append(hi).append(lo);
            }
        }
        return sb.toString();
    }

    public static String buildPassthroughUri(String inputId) {
        if (!notBlank(inputId)) return null;
        return TIF_PASSTHROUGH_PREFIX + encodePassthroughInputId(inputId);
    }

    public static int parseHdmiPortFromLabel(String label) {
        String t = normalizeText(label);
        if (t.isEmpty()) return -1;
        String padded = " " + t + " ";
        if (padded.contains(" hdmi 1 ") || padded.contains(" hdmi1 ")) return 1;
        if (padded.contains(" hdmi 2 ") || padded.contains(" hdmi2 ")) return 2;
        if (padded.contains(" hdmi 3 ") || padded.contains(" hdmi3 ")) return 3;
        return -1;
    }

    public static String resolveHdmiInputId(int portNumber, List<TifInputRecord> discoveredInputs) {
        if (portNumber < 1 || portNumber > 3) {
            return null;
        }
        if (discoveredInputs != null) {
            for (TifInputRecord rec : discoveredInputs) {
                if (rec != null && rec.type == TYPE_HDMI && rec.passthrough
                        && rec.hdmiPort == portNumber && notBlank(rec.inputId)) {
                    return rec.inputId.trim();
                }
            }
            String expectedSuffix = "/HW" + (5 + portNumber);
            for (TifInputRecord rec : discoveredInputs) {
                if (rec != null && rec.type == TYPE_HDMI && notBlank(rec.inputId)
                        && rec.inputId.trim().endsWith(expectedSuffix)) {
                    return rec.inputId.trim();
                }
            }
        }
        switch (portNumber) {
            case 1:
                return DEFAULT_HDMI1_INPUT_ID;
            case 2:
                return DEFAULT_HDMI2_INPUT_ID;
            case 3:
                return DEFAULT_HDMI3_INPUT_ID;
            default:
                return null;
        }
    }

    public static String resolveDtvInputId(List<TifInputRecord> discoveredInputs) {
        if (discoveredInputs != null) {
            for (TifInputRecord rec : discoveredInputs) {
                if (rec != null && rec.type == TYPE_TUNER && DEFAULT_DTV_INPUT_ID.equals(rec.inputId)) {
                    return rec.inputId;
                }
            }
            for (TifInputRecord rec : discoveredInputs) {
                if (rec != null && rec.type == TYPE_TUNER && notBlank(rec.inputId)) {
                    return rec.inputId.trim();
                }
            }
        }
        return DEFAULT_DTV_INPUT_ID;
    }

    public static List<LaunchSpec> planCandidatesForAction(String action, List<TifInputRecord> discoveredInputs) {
        if (!notBlank(action)) {
            return Collections.emptyList();
        }
        String cleanAction = action.trim();
        List<LaunchSpec> specs = new ArrayList<>();
        if ("input_tv".equals(cleanAction)) {
            String dtvId = resolveDtvInputId(discoveredInputs);
            String dtvUri = buildPassthroughUri(dtvId);
            specs.add(new LaunchSpec(
                    "MAIN_COMPONENT",
                    "android.intent.action.MAIN",
                    "android.intent.category.DEFAULT",
                    TV_CENTER_PACKAGE,
                    TV_CENTER_MAIN_ACTIVITY,
                    null,
                    dtvId));
            specs.add(new LaunchSpec(
                    "VIEW_TIF_URI_PACKAGED",
                    "android.intent.action.VIEW",
                    null,
                    TV_CENTER_PACKAGE,
                    null,
                    dtvUri,
                    dtvId));
            specs.add(new LaunchSpec(
                    "VIEW_TIF_URI_SYSTEM",
                    "android.intent.action.VIEW",
                    null,
                    null,
                    null,
                    dtvUri,
                    dtvId));
            return Collections.unmodifiableList(specs);
        }

        int hdmiPort = -1;
        if ("input_hdmi1".equals(cleanAction)) hdmiPort = 1;
        else if ("input_hdmi2".equals(cleanAction)) hdmiPort = 2;
        else if ("input_hdmi3".equals(cleanAction)) hdmiPort = 3;

        if (hdmiPort > 0) {
            String hdmiId = resolveHdmiInputId(hdmiPort, discoveredInputs);
            String hdmiUri = buildPassthroughUri(hdmiId);
            if (!notBlank(hdmiUri)) {
                return Collections.emptyList();
            }
            specs.add(new LaunchSpec(
                    "VIEW_TIF_URI_PACKAGED",
                    "android.intent.action.VIEW",
                    null,
                    TV_CENTER_PACKAGE,
                    null,
                    hdmiUri,
                    hdmiId));
            specs.add(new LaunchSpec(
                    "VIEW_TIF_URI_SYSTEM",
                    "android.intent.action.VIEW",
                    null,
                    null,
                    null,
                    hdmiUri,
                    hdmiId));
            return Collections.unmodifiableList(specs);
        }

        if ("input_source".equals(cleanAction)) {
            specs.add(new LaunchSpec(
                    "ACTION_VIEW_INPUTS",
                    ACTION_VIEW_INPUTS,
                    null,
                    null,
                    null,
                    null,
                    null));
            specs.add(new LaunchSpec(
                    "COMPONENT_ONLY",
                    null,
                    null,
                    TV_CENTER_PACKAGE,
                    TV_CENTER_INPUTS_ACTIVITY,
                    null,
                    null));
            return Collections.unmodifiableList(specs);
        }

        return Collections.emptyList();
    }

    public static boolean isTvCenterPackage(String pkg) {
        return TV_CENTER_PACKAGE.equals(pkg);
    }

    private static String normalizeText(String raw) {
        if (raw == null) return "";
        String lower = raw.toLowerCase(Locale.ITALIAN).trim();
        String norm = Normalizer.normalize(lower, Normalizer.Form.NFD).replaceAll("\\p{M}+", "");
        return norm.replaceAll("[^a-z0-9]+", " ").replaceAll("\\s+", " ").trim();
    }

    private static boolean hasWholePhrase(String normalizedText, String phrase) {
        if (normalizedText == null || normalizedText.isEmpty() || phrase == null || phrase.isEmpty()) {
            return false;
        }
        return (" " + normalizedText + " ").contains(" " + phrase + " ");
    }

    private static boolean hasAnyWholePhrase(String normalizedText, String... phrases) {
        for (String p : phrases) {
            if (hasWholePhrase(normalizedText, p)) {
                return true;
            }
        }
        return false;
    }

    public static boolean isInputsPanelActivity(String activityClass) {
        if (!notBlank(activityClass)) {
            return false;
        }
        String trimmed = activityClass.trim();
        return TV_CENTER_INPUTS_ACTIVITY.equals(trimmed)
                || "InputsPanelActivity".equals(trimmed)
                || trimmed.endsWith(".InputsPanelActivity");
    }

    public static boolean hasExternalSourceLabel(List<String> visibleTexts) {
        if (visibleTexts == null || visibleTexts.isEmpty()) {
            return false;
        }
        for (String raw : visibleTexts) {
            String norm = normalizeText(raw);
            if (hasAnyWholePhrase(norm,
                    "hdmi", "hdmi 1", "hdmi1", "hdmi 2", "hdmi2", "hdmi 3", "hdmi3",
                    "av", "av 1", "av1", "composito", "composite", "component", "scart", "vga")) {
                return true;
            }
        }
        return false;
    }

    public static boolean hasInputsPanelUiCues(List<String> visibleTexts) {
        if (visibleTexts == null || visibleTexts.isEmpty()) {
            return false;
        }
        boolean hasHeader = false;
        boolean sawDtv = false;
        boolean sawHdmi1 = false;
        boolean sawHdmi2 = false;
        boolean sawHdmi3 = false;
        boolean sawAvOther = false;
        for (String raw : visibleTexts) {
            String norm = normalizeText(raw);
            if (norm.isEmpty()) continue;
            if (hasAnyWholePhrase(norm,
                    "ingressi", "sorgenti", "inputs", "input source", "input list",
                    "seleziona ingresso", "selezione ingressi", "lista ingressi",
                    "sorgente ingresso", "elenco ingressi", "source list")) {
                hasHeader = true;
            }
            if (hasAnyWholePhrase(norm, "dtv", "digitale terrestre", "tv", "antenna", "canali tv")) {
                sawDtv = true;
            }
            if (hasAnyWholePhrase(norm, "hdmi 1", "hdmi1")) {
                sawHdmi1 = true;
            }
            if (hasAnyWholePhrase(norm, "hdmi 2", "hdmi2")) {
                sawHdmi2 = true;
            }
            if (hasAnyWholePhrase(norm, "hdmi 3", "hdmi3")) {
                sawHdmi3 = true;
            }
            if (hasAnyWholePhrase(norm, "av", "av 1", "av1", "composito", "composite", "component", "scart", "vga")) {
                sawAvOther = true;
            }
        }
        int distinctSources = (sawDtv ? 1 : 0) + (sawHdmi1 ? 1 : 0) + (sawHdmi2 ? 1 : 0)
                + (sawHdmi3 ? 1 : 0) + (sawAvOther ? 1 : 0);
        return hasHeader && distinctSources >= 2;
    }

    /**
     * Requires explicit DTV/tuner/EPG origin evidence (never bare channel names such as "Rai 1 HD"
     * or "Canale 5" alone). On Android 9 public API 28, TvInputManager cannot read LiveTV's active
     * input, so a bare channel label without DTV/tuner/EPG corroboration must fail closed and fall
     * back to COMMAND_SENT + owner visual confirmation.
     */
    public static boolean hasPositiveDtvEvidence(List<String> visibleTexts) {
        if (visibleTexts == null || visibleTexts.isEmpty()) {
            return false;
        }
        if (hasExternalSourceLabel(visibleTexts) || hasInputsPanelUiCues(visibleTexts)) {
            return false;
        }
        for (String raw : visibleTexts) {
            String norm = normalizeText(raw);
            if (norm.isEmpty()) continue;
            if (hasAnyWholePhrase(norm,
                    "dtv", "dvb", "dvb t", "dvbt", "dvb t2", "dvbt2",
                    "digitale terrestre", "tuner", "tv digitale", "antenna tv",
                    "lcn", "guida tv", "epg", "televideo")) {
                return true;
            }
            if (DTV_CHANNEL_NUM_PATTERN.matcher(norm).find()) {
                return true;
            }
        }
        return false;
    }

    public static boolean hasPositiveHdmiPortEvidence(int portNumber, List<String> visibleTexts) {
        if (portNumber < 1 || portNumber > 3 || visibleTexts == null || visibleTexts.isEmpty()) {
            return false;
        }
        if (hasInputsPanelUiCues(visibleTexts)) {
            return false;
        }
        boolean matchedTarget = false;
        for (String raw : visibleTexts) {
            String norm = normalizeText(raw);
            if (norm.isEmpty()) continue;
            if (hasAnyWholePhrase(norm, "dtv", "dvb t", "dvbt", "dvb t2", "dvbt2", "digitale terrestre")) {
                return false;
            }
            for (int other = 1; other <= 3; other++) {
                if (other != portNumber && hasAnyWholePhrase(norm, "hdmi " + other, "hdmi" + other)) {
                    return false;
                }
            }
            if (hasAnyWholePhrase(norm, "hdmi " + portNumber, "hdmi" + portNumber)) {
                matchedTarget = true;
            }
        }
        return matchedTarget;
    }

    public static String detectOemDialogAnomaly(String foregroundPackage, List<String> visibleTexts) {
        if (visibleTexts == null || visibleTexts.isEmpty()) {
            return null;
        }
        boolean isSystemUiDialog = "android".equals(foregroundPackage) || "com.android.systemui".equals(foregroundPackage);
        for (String raw : visibleTexts) {
            String t = normalizeText(raw);
            if (t.isEmpty()) continue;
            if (t.contains("non risponde")
                    || t.contains("isn t responding")
                    || t.contains("isnt responding")) {
                return "ANR dialogo sistema (" + raw.trim() + ")";
            }
            if (t.contains("continua a interrompersi")
                    || t.contains("keeps stopping")
                    || t.contains("si e interrotta")
                    || t.contains("si e interrotto")
                    || t.contains("has stopped")) {
                return "Crash dialogo sistema (" + raw.trim() + ")";
            }
            if (isSystemUiDialog && (t.contains("chiudi app") || t.contains("close app"))) {
                return "Dialogo errore sistema (" + raw.trim() + ")";
            }
        }
        return null;
    }
}
