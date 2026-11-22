package it.akai.customremote.ai;

import it.akai.customremote.TvInputIntentPolicy;

import java.text.Normalizer;
import java.util.List;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * A2 deterministic final-goal evidence gate. The LLM may propose a
 * success_condition, but it cannot lower the observable evidence required
 * by a user's explicit request. This is deliberately small for Android 9.
 *
 * A true result here must ALSO pass the plan's success_condition.
 */
public final class GoalEvidenceVerifier {
    public static final long MAX_TV_INPUT_EVIDENCE_AGE_MS = 15000L;
    private static final long MAX_CLOCK_SKEW_MS = 5000L;
    private static final Pattern NUMERIC_CHANNEL_GOAL_PATTERN =
            Pattern.compile("(?:^| )canale ([0-9]{1,4})(?: |$)");

    private GoalEvidenceVerifier() {}

    private static final class TvInputTarget {
        final String kind; // "HDMI", "DTV_CHANNEL", "DTV", "INPUTS_PANEL"
        final int number;

        TvInputTarget(String kind, int number) {
            this.kind = kind;
            this.number = number;
        }
    }

    public static final class Verdict {
        public final boolean satisfied;
        public final String goalKind;
        public final String reason;
        public final boolean observedFinalStateOnly;

        Verdict(boolean satisfied, String goalKind, String reason) {
            this(satisfied, goalKind, reason, false);
        }

        Verdict(boolean satisfied, String goalKind, String reason, boolean observedFinalStateOnly) {
            this.satisfied = satisfied;
            this.goalKind = goalKind;
            this.reason = reason;
            this.observedFinalStateOnly = observedFinalStateOnly;
        }
    }

    private static String normalize(String raw) {
        String s = raw == null ? "" : raw.toLowerCase(Locale.ITALIAN).trim();
        s = Normalizer.normalize(s, Normalizer.Form.NFD).replaceAll("\\p{M}+", "");
        return s.replaceAll("[^a-z0-9]+", " ").replaceAll("\\s+", " ").trim();
    }

    private static boolean has(String text, String term) {
        return (" " + text + " ").contains(" " + term + " ");
    }

    /**
     * Whole-word/whole-phrase channel identity, not substring matching:
     * "Italia 20" must never certify "Italia 2"; likewise Rai 10 vs Rai 1.
     * Compact OEM labels such as "Italia2" and "Rai1" are also accepted,
     * but an ambiguous or missing label fails closed.
     */
    private static boolean hasVisibleChannelLabel(ScreenPerceptionEngine.PerceptionSnapshot snapshot,
            String spaced, String compact) {
        if (snapshot == null || snapshot.visibleTexts == null) return false;
        for (String raw : snapshot.visibleTexts) {
            String visible = normalize(raw);
            if (has(visible, spaced) || has(visible, compact)) return true;
        }
        return false;
    }

    private static boolean mentionsPlayback(String q) {
        if (has(q, "diretta") || has(q, "live") || has(q, "riproduci")
                || has(q, "guarda") || has(q, "guardare") || has(q, "fai partire")
                || has(q, "fammi vedere") || has(q, "avvia riproduzione")) {
            return true;
        }
        // Avoid confusing "metti il volume" / "avvia l'app" with playback.
        boolean mediaSubject = has(q, "video") || has(q, "film") || has(q, "episodio")
                || has(q, "puntata") || has(q, "italia 2") || has(q, "italia2")
                || has(q, "rai 1") || has(q, "rai1")
                || has(q, "canale") || has(q, "streaming");
        return mediaSubject && (has(q, "metti") || has(q, "avvia") || has(q, "vedere"));
    }

    private static Verdict denied(String kind, String reason) {
        return new Verdict(false, kind, reason, false);
    }

    private static Verdict deniedObservedOnly(String kind, String reason) {
        return new Verdict(false, kind, reason, true);
    }

    private static Verdict allowed(String kind, String reason) {
        return new Verdict(true, kind, reason, false);
    }

    private static boolean safeStrEq(String a, String b) {
        String sa = a != null ? a.trim() : "";
        String sb = b != null ? b.trim() : "";
        return sa.equals(sb);
    }

    private static boolean safeTextsEq(List<String> a, List<String> b) {
        int sizeA = a != null ? a.size() : 0;
        int sizeB = b != null ? b.size() : 0;
        if (sizeA != sizeB) {
            return false;
        }
        for (int i = 0; i < sizeA; i++) {
            if (!safeStrEq(a.get(i), b.get(i))) {
                return false;
            }
        }
        return true;
    }

    /**
     * Enforce the final request on top of the LLM-proposed condition.
     * A compound request cannot be considered complete merely because the
     * first application launched; that is only an intermediate state.
     */
    public static Verdict verify(String goal, String successCondition,
                                 ScreenPerceptionEngine.PerceptionSnapshot snapshot) {
        return verify(goal, successCondition, snapshot, System.currentTimeMillis(), 0L, null);
    }

    public static Verdict verify(String goal, String successCondition,
                                 ScreenPerceptionEngine.PerceptionSnapshot snapshot,
                                 long nowMs, long minTimestampMs) {
        return verify(goal, successCondition, snapshot, nowMs, minTimestampMs, null);
    }

    public static Verdict verify(String goal, String successCondition,
                                 ScreenPerceptionEngine.PerceptionSnapshot snapshot,
                                 long nowMs, long minTimestampMs,
                                 org.json.JSONArray executedActions) {
        Verdict observed = verify(goal, snapshot, nowMs, minTimestampMs, executedActions);
        if (!observed.satisfied) return observed;
        String q = normalize(goal);
        boolean compound = has(q, "poi") || (has(q, "e")
                && (has(q, "apri") || has(q, "avvia") || has(q, "vai su")));
        if (compound && successCondition != null) {
            try {
                org.json.JSONObject condition = new org.json.JSONObject(successCondition);
                String type = condition.optString("type", "");
                if ("pkg_is".equals(type) || "pkg_any_of".equals(type)
                        || "any_of_pkgs".equals(type)) {
                    return denied("multi_step", "L'apertura dell'app e' soltanto uno step intermedio del compito");
                }
                // A visible Search button does NOT prove that the requested
                // search ran or returned results.
                if (has(q, "cerca") && "contains_text".equals(type)) {
                    String value = normalize(condition.optString("value", ""));
                    if ("cerca".equals(value) || "search".equals(value)
                            || "cerca su youtube".equals(value)) {
                        return denied("search_results", "Il pulsante Cerca visibile non prova risultati della ricerca");
                    }
                }
                if (has(q, "cerca") && "any_of_texts".equals(type)) {
                    org.json.JSONArray values = condition.optJSONArray("values");
                    if (values != null && values.length() > 0) {
                        boolean onlySearchLabels = true;
                        for (int i = 0; i < values.length(); i++) {
                            String value = normalize(values.optString(i, ""));
                            if (!"cerca".equals(value) && !"search".equals(value)
                                    && !"cerca su youtube".equals(value)) {
                                onlySearchLabels = false;
                                break;
                            }
                        }
                        if (onlySearchLabels) {
                            return denied("search_results", "La schermata Ricerca non prova il contenuto cercato");
                        }
                    }
                }
            } catch (Exception e) {
                return denied("multi_step", "Condizione finale malformata");
            }
        }
        return observed;
    }

    public static Verdict verify(String goal, String successCondition,
                                 ScreenPerceptionEngine.PerceptionSnapshot preSnapshot,
                                 ScreenPerceptionEngine.PerceptionSnapshot postSnapshot,
                                 long nowMs, long minTimestampMs) {
        return verify(goal, successCondition, preSnapshot, postSnapshot, nowMs, minTimestampMs, null);
    }

    public static Verdict verify(String goal, String successCondition,
                                 ScreenPerceptionEngine.PerceptionSnapshot preSnapshot,
                                 ScreenPerceptionEngine.PerceptionSnapshot postSnapshot,
                                 long nowMs, long minTimestampMs,
                                 org.json.JSONArray executedActions) {
        Verdict v = verify(goal, successCondition, postSnapshot, nowMs, minTimestampMs, executedActions);
        if (!v.satisfied || !"tv_input".equals(v.goalKind) || preSnapshot == null) {
            return v;
        }
        boolean pkgChanged = !safeStrEq(preSnapshot.foregroundPackage, postSnapshot.foregroundPackage);
        boolean actChanged = !safeStrEq(preSnapshot.foregroundActivity, postSnapshot.foregroundActivity);
        boolean freshActEvent = postSnapshot.foregroundActivityTimestamp > 0L
                && postSnapshot.foregroundActivityTimestamp > preSnapshot.foregroundActivityTimestamp
                && (minTimestampMs <= 0L || postSnapshot.foregroundActivityTimestamp >= minTimestampMs);
        boolean textsChanged = !safeTextsEq(preSnapshot.visibleTexts, postSnapshot.visibleTexts);
        if (!(pkgChanged || actChanged || freshActEvent || textsChanged)) {
            return deniedObservedOnly("tv_input",
                    "Stato finale TV gia' presente e invariato rispetto a prima del comando (nessuna transizione Activity/UI attribuibile al comando): conferma visiva richiesta");
        }
        return v;
    }

    private static Verdict checkTvInputFreshness(ScreenPerceptionEngine.PerceptionSnapshot snapshot,
                                                 long nowMs, long minTimestampMs) {
        if (snapshot.timestamp <= 0L) {
            return denied("tv_input", "Snapshot TV privo di timestamp valido: conferma visiva richiesta");
        }
        if (minTimestampMs > 0L && snapshot.timestamp < minTimestampMs) {
            return denied("tv_input", "Evidenza TV precedente al comando inviato (snapshot stantio): conferma visiva richiesta");
        }
        if ((nowMs - snapshot.timestamp) > MAX_TV_INPUT_EVIDENCE_AGE_MS
                || (snapshot.timestamp - nowMs) > MAX_CLOCK_SKEW_MS) {
            return denied("tv_input", "Evidenza OSD/Accessibilita' TV scaduta: conferma visiva richiesta al proprietario");
        }
        return null;
    }

    private static Verdict checkActivityEventFreshness(long activityTs, long nowMs, long minTimestampMs) {
        if (activityTs <= 0L) {
            return deniedObservedOnly("tv_input",
                    "Activity InputsPanelActivity osservata ma senza timestamp TYPE_WINDOW_STATE_CHANGED valido: transizione non attribuibile al comando");
        }
        if (minTimestampMs > 0L && activityTs < minTimestampMs) {
            return deniedObservedOnly("tv_input",
                    "Activity InputsPanelActivity registrata prima del comando (evento intra-package stantio): stato osservato non attribuibile al comando");
        }
        if ((nowMs - activityTs) > MAX_TV_INPUT_EVIDENCE_AGE_MS
                || (activityTs - nowMs) > MAX_CLOCK_SKEW_MS) {
            return deniedObservedOnly("tv_input",
                    "Evento InputsPanelActivity scaduto oltre la finestra di freschezza: conferma visiva richiesta");
        }
        return null;
    }

    private static String resolveExplicitNonTvAppPackage(String q) {
        if (has(q, "mediaset") || has(q, "infinity")) return "it.mediaset.infinitytv";
        if (has(q, "youtube")) return "com.google.android.youtube.tv";
        if (has(q, "raiplay")) return "it.rainet.androidtv";
        if (has(q, "impostazioni") || has(q, "settings")) return "com.android.tv.settings";
        return null;
    }

    private static int resolveNamedDtvChannelFromGoal(String q) {
        if (has(q, "rai 1") || has(q, "rai1") || has(q, "rai uno")) return 1;
        if (has(q, "rai 2") || has(q, "rai2") || has(q, "rai due")) return 2;
        if (has(q, "rai 3") || has(q, "rai3") || has(q, "rai tre")) return 3;
        if (has(q, "rete 4") || has(q, "rete4") || has(q, "rete quattro")) return 4;
        if (has(q, "canale 5") || has(q, "canale5") || has(q, "canale cinque")) return 5;
        if (has(q, "italia 1") || has(q, "italia1") || has(q, "italia uno")) return 6;
        if (has(q, "la 7") || has(q, "la7") || has(q, "la sette")) return 7;
        return -1;
    }

    private static boolean hasImplicitNamedBroadcastChannel(String q) {
        return resolveNamedDtvChannelFromGoal(q) > 0
                || has(q, "italia 2") || has(q, "italia2");
    }

    private static TvInputTarget resolveTvInputTargetFromActions(org.json.JSONArray executedActions) {
        if (executedActions == null) {
            return null;
        }
        TvInputTarget actionTarget = null;
        for (int i = 0; i < executedActions.length(); i++) {
            org.json.JSONObject step = executedActions.optJSONObject(i);
            if (step == null) continue;
            String type = step.optString("type", "").trim().toLowerCase(Locale.US);
            if ("tune_channel".equals(type) || "select_channel".equals(type)) {
                actionTarget = new TvInputTarget("DTV_CHANNEL", step.optInt("number", -1));
            } else if ("command".equals(type) || "press_key".equals(type)) {
                String act = step.optString("action", step.optString("key", "")).trim().toLowerCase(Locale.US);
                if ("input_hdmi1".equals(act)) actionTarget = new TvInputTarget("HDMI", 1);
                else if ("input_hdmi2".equals(act)) actionTarget = new TvInputTarget("HDMI", 2);
                else if ("input_hdmi3".equals(act)) actionTarget = new TvInputTarget("HDMI", 3);
                else if ("input_tv".equals(act)) actionTarget = new TvInputTarget("DTV", -1);
                else if ("input_source".equals(act)) actionTarget = new TvInputTarget("INPUTS_PANEL", -1);
            } else if ("launch_app".equals(type) || "open_app".equals(type)) {
                String targetPkg = step.optString("pkg", step.optString("package", "")).trim();
                if (TvInputIntentPolicy.isTvCenterPackage(targetPkg)) {
                    actionTarget = new TvInputTarget("DTV", -1);
                } else if (!targetPkg.isEmpty()) {
                    actionTarget = null;
                }
            }
        }
        return actionTarget;
    }

    private static boolean hasDtvChannelAction(org.json.JSONArray executedActions) {
        TvInputTarget t = resolveTvInputTargetFromActions(executedActions);
        return t != null && "DTV_CHANNEL".equals(t.kind);
    }

    private static boolean hasExplicitDtvTerm(String q) {
        return has(q, "digitale terrestre") || has(q, "dtv") || has(q, "antenna");
    }

    private static boolean hasStreamingContext(String q) {
        return has(q, "diretta") || has(q, "live") || has(q, "streaming")
                || has(q, "raiplay") || has(q, "mediaset") || has(q, "infinity") || has(q, "youtube");
    }

    private static TvInputTarget resolveTvInputTargetFromGoal(String q, org.json.JSONArray executedActions) {
        if (resolveExplicitNonTvAppPackage(q) != null) {
            return null;
        }
        if (has(q, "hdmi 1") || has(q, "hdmi1")) return new TvInputTarget("HDMI", 1);
        if (has(q, "hdmi 2") || has(q, "hdmi2")) return new TvInputTarget("HDMI", 2);
        if (has(q, "hdmi 3") || has(q, "hdmi3")) return new TvInputTarget("HDMI", 3);
        Matcher cm = NUMERIC_CHANNEL_GOAL_PATTERN.matcher(q);
        if (cm.find() && (!hasStreamingContext(q) || hasExplicitDtvTerm(q))) {
            int ch = -1;
            try {
                ch = Integer.parseInt(cm.group(1));
            } catch (NumberFormatException ignored) {}
            return new TvInputTarget("DTV_CHANNEL", ch);
        }
        int namedCh = resolveNamedDtvChannelFromGoal(q);
        if (!hasStreamingContext(q)) {
            if (namedCh > 0 && (hasExplicitDtvTerm(q) || hasDtvChannelAction(executedActions))) {
                return new TvInputTarget("DTV_CHANNEL", namedCh);
            }
            if ((has(q, "italia 2") || has(q, "italia2"))
                    && (hasExplicitDtvTerm(q) || hasDtvChannelAction(executedActions))) {
                if (hasDtvChannelAction(executedActions)) {
                    TvInputTarget actTarget = resolveTvInputTargetFromActions(executedActions);
                    return new TvInputTarget("DTV_CHANNEL", actTarget != null ? actTarget.number : -1);
                }
                return new TvInputTarget("DTV_NAMED_ITALIA2", -1);
            }
            if (hasImplicitNamedBroadcastChannel(q)) {
                return new TvInputTarget("AMBIGUOUS_NAMED_CHANNEL", namedCh);
            }
        }
        if (hasExplicitDtvTerm(q)
                || has(q, "canali tv") || has(q, "canale tv") || has(q, "elenco canali") || "tv".equals(q)) {
            return new TvInputTarget("DTV", -1);
        }
        if (has(q, "ingressi") || has(q, "sorgenti") || has(q, "cambia ingresso")) {
            return new TvInputTarget("INPUTS_PANEL", -1);
        }
        return null;
    }

    /**
     * Physical TV inputs (DTV / DTV channel / HDMI 1-3 / Source Panel):
     * Android 9 public API 28 TvInputManager does NOT expose the currently active input/tuner of LiveTV.
     * Verification MUST fail closed whenever fresh independent UI/Activity proof is absent: never certify
     * generic tvcenter foreground alone, empty visibleTexts, or "Nessun segnale" / expired OSD banners.
     */
    private static Verdict verifyTvInputTarget(TvInputTarget target,
                                               ScreenPerceptionEngine.PerceptionSnapshot snapshot,
                                               String pkg, long nowMs, long minTimestampMs) {
        if ("AMBIGUOUS_NAMED_CHANNEL".equals(target.kind)) {
            return denied("tv_input",
                    "Richiesta canale TV ambigua senza app streaming esplicita ne' azione/conferma DTV: chiarire sorgente (antenna/app) o confermare visivamente");
        }
        if ("DTV_NAMED_ITALIA2".equals(target.kind)) {
            if (!TvInputIntentPolicy.isTvCenterPackage(pkg)) {
                return denied("tv_input", "LiveTV (tvcenter) non e' in primo piano per canale Italia 2");
            }
            Verdict stale = checkTvInputFreshness(snapshot, nowMs, minTimestampMs);
            if (stale != null) return stale;
            if (TvInputIntentPolicy.isInputsPanelActivity(snapshot.foregroundActivity)) {
                return denied("tv_input", "Pannello ingressi ancora aperto: sintonizzazione Italia 2 non confermata");
            }
            if (TvInputIntentPolicy.hasExternalSourceLabel(snapshot.visibleTexts)) {
                return denied("tv_input", "LiveTV mostra una sorgente esterna (HDMI/AV) anziche' canale Italia 2");
            }
            if (!TvInputIntentPolicy.hasPositiveDtvEvidence(snapshot.visibleTexts)) {
                return denied("tv_input", "LiveTV in primo piano ma senza conferma DTV/tuner/EPG fresca per Italia 2: conferma visiva richiesta");
            }
            if (hasVisibleChannelLabel(snapshot, "italia 2", "italia2")) {
                return allowed("tv_input", "LiveTV in primo piano con conferma DTV fresca per canale Italia 2");
            }
            return denied("tv_input", "LiveTV in primo piano ma canale Italia 2 non confermato nei nodi UI freschi: conferma visiva richiesta");
        }
        if ("DTV_CHANNEL".equals(target.kind)) {
            int ch = target.number;
            if (ch < 1 || ch > 9999) {
                return denied("tv_input", "Numero canale DTV non valido (" + ch + "): deve essere tra 1 e 9999");
            }
            if (!TvInputIntentPolicy.isTvCenterPackage(pkg)) {
                return denied("tv_input", "LiveTV (tvcenter) non e' in primo piano per canale DTV " + ch);
            }
            Verdict stale = checkTvInputFreshness(snapshot, nowMs, minTimestampMs);
            if (stale != null) return stale;
            if (TvInputIntentPolicy.isInputsPanelActivity(snapshot.foregroundActivity)) {
                return denied("tv_input", "Pannello ingressi ancora aperto: sintonizzazione canale DTV " + ch + " non confermata");
            }
            if (TvInputIntentPolicy.hasExternalSourceLabel(snapshot.visibleTexts)) {
                return denied("tv_input", "LiveTV mostra una sorgente esterna (HDMI/AV) anziche' canale DTV " + ch);
            }
            if (!TvInputIntentPolicy.hasPositiveDtvEvidence(snapshot.visibleTexts)) {
                return denied("tv_input", "LiveTV in primo piano ma senza conferma DTV/tuner/EPG fresca per canale " + ch + ": conferma visiva richiesta");
            }
            if (TvInputIntentPolicy.hasPositiveDtvChannelNumberEvidence(ch, snapshot.visibleTexts)) {
                return allowed("tv_input", "LiveTV in primo piano con conferma DTV fresca per canale " + ch);
            }
            return denied("tv_input", "LiveTV in primo piano ma numero canale DTV " + ch + " non confermato nei nodi UI freschi: conferma visiva richiesta");
        }
        if ("HDMI".equals(target.kind)) {
            int requestedHdmiPort = target.number;
            if (!TvInputIntentPolicy.isTvCenterPackage(pkg)) {
                return denied("tv_input", "LiveTV (tvcenter) non e' in primo piano per HDMI " + requestedHdmiPort);
            }
            Verdict stale = checkTvInputFreshness(snapshot, nowMs, minTimestampMs);
            if (stale != null) return stale;
            if (TvInputIntentPolicy.isInputsPanelActivity(snapshot.foregroundActivity)) {
                return denied("tv_input", "Pannello ingressi ancora aperto: selezione HDMI " + requestedHdmiPort + " non ancora confermata");
            }
            if (TvInputIntentPolicy.hasPositiveHdmiPortEvidence(requestedHdmiPort, snapshot.visibleTexts)) {
                return allowed("tv_input", "LiveTV in primo piano con conferma OSD fresca HDMI " + requestedHdmiPort);
            }
            return denied("tv_input", "LiveTV in primo piano ma nessuna prova OSD fresca e univoca per HDMI " + requestedHdmiPort + ": conferma visiva richiesta");
        }
        if ("DTV".equals(target.kind)) {
            if (!TvInputIntentPolicy.isTvCenterPackage(pkg)) {
                return denied("tv_input", "LiveTV (tvcenter) non e' in primo piano per Digitale Terrestre");
            }
            Verdict stale = checkTvInputFreshness(snapshot, nowMs, minTimestampMs);
            if (stale != null) return stale;
            if (TvInputIntentPolicy.isInputsPanelActivity(snapshot.foregroundActivity)) {
                return denied("tv_input", "Pannello ingressi ancora aperto: passaggio a Digitale Terrestre non confermato");
            }
            if (TvInputIntentPolicy.hasExternalSourceLabel(snapshot.visibleTexts)) {
                return denied("tv_input", "LiveTV mostra una sorgente esterna (HDMI/AV) anziche' Digitale Terrestre");
            }
            if (TvInputIntentPolicy.hasPositiveDtvEvidence(snapshot.visibleTexts)) {
                return allowed("tv_input", "LiveTV in primo piano con conferma OSD fresca del tuner Digitale Terrestre");
            }
            return denied("tv_input", "LiveTV in primo piano ma Android 9 non espone prova DTV/tuner fresca nei nodi UI: stato non verificato, conferma visiva richiesta");
        }
        if (!TvInputIntentPolicy.isTvCenterPackage(pkg)) {
            return denied("tv_input", "Pannello ingressi LiveTV non e' in primo piano");
        }
        Verdict stale = checkTvInputFreshness(snapshot, nowMs, minTimestampMs);
        if (stale != null) return stale;
        if (TvInputIntentPolicy.isInputsPanelActivity(snapshot.foregroundActivity)) {
            Verdict staleAct = checkActivityEventFreshness(snapshot.foregroundActivityTimestamp, nowMs, minTimestampMs);
            if (staleAct != null) return staleAct;
            return allowed("tv_input", "Activity InputsPanelActivity fresca confermata dopo il comando");
        }
        if (snapshot.foregroundActivity != null && !snapshot.foregroundActivity.trim().isEmpty()) {
            return denied("tv_input", "LiveTV in primo piano su activity diversa da InputsPanelActivity (" + snapshot.foregroundActivity + "): pannello ingressi non verificato");
        }
        if (TvInputIntentPolicy.hasInputsPanelUiCues(snapshot.visibleTexts)) {
            return allowed("tv_input", "Pannello selezione ingressi confermato da elenco sorgenti visibile");
        }
        return denied("tv_input", "LiveTV in primo piano senza conferma InputsPanelActivity o lista sorgenti: conferma visiva richiesta");
    }

    public static Verdict verify(String goal, ScreenPerceptionEngine.PerceptionSnapshot snapshot) {
        return verify(goal, snapshot, System.currentTimeMillis(), 0L, null);
    }

    public static Verdict verify(String goal, ScreenPerceptionEngine.PerceptionSnapshot snapshot,
                                 long nowMs, long minTimestampMs) {
        return verify(goal, snapshot, nowMs, minTimestampMs, null);
    }

    public static Verdict verify(String goal, ScreenPerceptionEngine.PerceptionSnapshot snapshot,
                                 long nowMs, long minTimestampMs,
                                 org.json.JSONArray executedActions) {
        if (snapshot == null || snapshot.hasSensitiveFields) {
            return denied("unknown", "Schermata non osservabile o protetta");
        }
        String q = normalize(goal);
        String pkg = snapshot.foregroundPackage != null ? snapshot.foregroundPackage : "";

        String oemAnomaly = TvInputIntentPolicy.detectOemDialogAnomaly(pkg, snapshot.visibleTexts);
        if (oemAnomaly != null) {
            return denied("oem_dialog", "Dialogo errore/ANR OEM rilevato (" + oemAnomaly + "): stato non verificato");
        }

        // 1. Evaluate user's semantic goal FIRST: executed actions can add constraints
        //    but MUST NEVER redefine or bypass an explicit non-TV app/playback/settings goal.
        final Verdict goalVerdict;
        String explicitApp = resolveExplicitNonTvAppPackage(q);
        TvInputTarget goalTvTarget = explicitApp == null ? resolveTvInputTargetFromGoal(q, executedActions) : null;

        if (has(q, "impostazioni") && (has(q, "audio") || has(q, "suono"))) {
            if (!"com.android.tv.settings".equals(pkg)) {
                goalVerdict = denied("settings_section", "Impostazioni Android TV non in primo piano");
            } else {
                boolean audioSection = snapshot.containsText("Uscita digitale", false)
                        || snapshot.containsText("Bilanciamento", false)
                        || snapshot.containsText("Altoparlanti", false)
                        || snapshot.containsText("Equalizzatore", false)
                        || snapshot.containsText("Modalita audio", false);
                goalVerdict = audioSection
                        ? allowed("settings_section", "Dettaglio sezione Audio presente")
                        : denied("settings_section", "La sola voce Audio non dimostra che la sezione sia aperta");
            }
        } else if (explicitApp != null) {
            if (mentionsPlayback(q)) {
                if ("it.mediaset.infinitytv".equals(explicitApp) && !explicitApp.equals(pkg)) {
                    goalVerdict = denied("playback", "Mediaset Infinity non e' in primo piano");
                } else if ("com.google.android.youtube.tv".equals(explicitApp) && !explicitApp.equals(pkg)) {
                    goalVerdict = denied("playback", "YouTube non e' in primo piano");
                } else if ("it.rainet.androidtv".equals(explicitApp) && !explicitApp.equals(pkg)) {
                    goalVerdict = denied("playback", "RaiPlay non e' in primo piano");
                } else if (!explicitApp.equals(pkg)) {
                    goalVerdict = denied("playback", "L'app richiesta non e' in primo piano");
                } else if (!snapshot.isMusicActive || !snapshot.isPlayerActive) {
                    goalVerdict = denied("playback", "La sola schermata dell'app non prova riproduzione audio/video");
                } else if ((has(q, "italia 2") || has(q, "italia2"))
                        && !hasVisibleChannelLabel(snapshot, "italia 2", "italia2")) {
                    goalVerdict = denied("playback", "Il canale Italia 2 non e' identificabile");
                } else if ((has(q, "rai 1") || has(q, "rai1"))
                        && !hasVisibleChannelLabel(snapshot, "rai 1", "rai1")) {
                    goalVerdict = denied("playback", "Il canale Rai 1 non e' identificabile");
                } else {
                    goalVerdict = allowed("playback", "Player, audio e identita' del contenuto richiesto osservati quando applicabile");
                }
            } else {
                goalVerdict = explicitApp.equals(pkg)
                        ? allowed("open_app", "Pacchetto richiesto osservato in primo piano")
                        : denied("open_app", "L'app richiesta non e' in primo piano");
            }
        } else if (goalTvTarget != null) {
            goalVerdict = verifyTvInputTarget(goalTvTarget, snapshot, pkg, nowMs, minTimestampMs);
        } else if (mentionsPlayback(q)) {
            if (pkg.isEmpty() || pkg.contains("customhome") || pkg.contains("launcher")) {
                goalVerdict = denied("playback", "Il player non e' in primo piano");
            } else if (TvInputIntentPolicy.isTvCenterPackage(pkg)) {
                goalVerdict = denied("tv_input",
                        "LiveTV (tvcenter) non puo' certificare riproduzione o canale antenna tramite solo isPlayerActive: conferma DTV/visiva richiesta");
            } else if (!snapshot.isMusicActive || !snapshot.isPlayerActive) {
                goalVerdict = denied("playback", "La sola schermata dell'app non prova riproduzione audio/video");
            } else if ((has(q, "italia 2") || has(q, "italia2"))
                    && !hasVisibleChannelLabel(snapshot, "italia 2", "italia2")) {
                goalVerdict = denied("playback", "Il canale Italia 2 non e' identificabile");
            } else if ((has(q, "rai 1") || has(q, "rai1"))
                    && !hasVisibleChannelLabel(snapshot, "rai 1", "rai1")) {
                goalVerdict = denied("playback", "Il canale Rai 1 non e' identificabile");
            } else {
                goalVerdict = allowed("playback", "Player, audio e identita' del contenuto richiesto osservati quando applicabile");
            }
        } else {
            goalVerdict = allowed("other", "Nessun requisito finale aggiuntivo identificato");
        }

        if (!goalVerdict.satisfied) {
            return goalVerdict;
        }

        // 2. Executed actions are a strictly conjunctive constraint: they may require
        //    fresh TIF/DTV evidence for an open-ended goal, never override a failed goal.
        TvInputTarget actionTvTarget = resolveTvInputTargetFromActions(executedActions);
        if (actionTvTarget != null) {
            Verdict actionVerdict = verifyTvInputTarget(actionTvTarget, snapshot, pkg, nowMs, minTimestampMs);
            if (!actionVerdict.satisfied) {
                return actionVerdict;
            }
            if ("other".equals(goalVerdict.goalKind)) {
                return actionVerdict;
            }
        }
        return goalVerdict;
    }
}
