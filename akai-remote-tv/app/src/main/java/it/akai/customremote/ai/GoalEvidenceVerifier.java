package it.akai.customremote.ai;

import it.akai.customremote.TvInputIntentPolicy;

import java.text.Normalizer;
import java.util.Locale;

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

    private GoalEvidenceVerifier() {}

    public static final class Verdict {
        public final boolean satisfied;
        public final String goalKind;
        public final String reason;

        Verdict(boolean satisfied, String goalKind, String reason) {
            this.satisfied = satisfied;
            this.goalKind = goalKind;
            this.reason = reason;
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
        return new Verdict(false, kind, reason);
    }

    private static Verdict allowed(String kind, String reason) {
        return new Verdict(true, kind, reason);
    }

    /**
     * Enforce the final request on top of the LLM-proposed condition.
     * A compound request cannot be considered complete merely because the
     * first application launched; that is only an intermediate state.
     */
    public static Verdict verify(String goal, String successCondition,
                                 ScreenPerceptionEngine.PerceptionSnapshot snapshot) {
        return verify(goal, successCondition, snapshot, System.currentTimeMillis(), 0L);
    }

    public static Verdict verify(String goal, String successCondition,
                                 ScreenPerceptionEngine.PerceptionSnapshot snapshot,
                                 long nowMs, long minTimestampMs) {
        Verdict observed = verify(goal, snapshot, nowMs, minTimestampMs);
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

    public static Verdict verify(String goal, ScreenPerceptionEngine.PerceptionSnapshot snapshot) {
        return verify(goal, snapshot, System.currentTimeMillis(), 0L);
    }

    public static Verdict verify(String goal, ScreenPerceptionEngine.PerceptionSnapshot snapshot,
                                 long nowMs, long minTimestampMs) {
        if (snapshot == null || snapshot.hasSensitiveFields) {
            return denied("unknown", "Schermata non osservabile o protetta");
        }
        String q = normalize(goal);
        String pkg = snapshot.foregroundPackage != null ? snapshot.foregroundPackage : "";

        String oemAnomaly = TvInputIntentPolicy.detectOemDialogAnomaly(pkg, snapshot.visibleTexts);
        if (oemAnomaly != null) {
            return denied("oem_dialog", "Dialogo errore/ANR OEM rilevato (" + oemAnomaly + "): stato non verificato");
        }

        if (mentionsPlayback(q)) {
            // Opening the app / seeing a SurfaceView is NEVER playback proof.
            // Require active media audio AND a player view in the foreground.
            if (pkg.isEmpty() || pkg.contains("customhome") || pkg.contains("launcher")) {
                return denied("playback", "Il player non e' in primo piano");
            }
            if (has(q, "mediaset") && !"it.mediaset.infinitytv".equals(pkg)) {
                return denied("playback", "Mediaset Infinity non e' in primo piano");
            }
            if (has(q, "youtube") && !"com.google.android.youtube.tv".equals(pkg)) {
                return denied("playback", "YouTube non e' in primo piano");
            }
            if (has(q, "raiplay") && !"it.rainet.androidtv".equals(pkg)) {
                return denied("playback", "RaiPlay non e' in primo piano");
            }
            if (!snapshot.isMusicActive || !snapshot.isPlayerActive) {
                return denied("playback", "La sola schermata dell'app non prova riproduzione audio/video");
            }
            // Channel-specific goals require visible identification as well.
            if ((has(q, "italia 2") || has(q, "italia2"))
                    && !hasVisibleChannelLabel(snapshot, "italia 2", "italia2")) {
                return denied("playback", "Il canale Italia 2 non e' identificabile");
            }
            if ((has(q, "rai 1") || has(q, "rai1"))
                    && !hasVisibleChannelLabel(snapshot, "rai 1", "rai1")) {
                return denied("playback", "Il canale Rai 1 non e' identificabile");
            }
            return allowed("playback", "Player, audio e identita' del contenuto richiesto osservati quando applicabile");
        }

        if (has(q, "impostazioni") && (has(q, "audio") || has(q, "suono"))) {
            if (!"com.android.tv.settings".equals(pkg)) {
                return denied("settings_section", "Impostazioni Android TV non in primo piano");
            }
            boolean audioSection = snapshot.containsText("Uscita digitale", false)
                    || snapshot.containsText("Bilanciamento", false)
                    || snapshot.containsText("Altoparlanti", false)
                    || snapshot.containsText("Equalizzatore", false)
                    || snapshot.containsText("Modalita audio", false);
            return audioSection
                    ? allowed("settings_section", "Dettaglio sezione Audio presente")
                    : denied("settings_section", "La sola voce Audio non dimostra che la sezione sia aperta");
        }

        // Physical TV inputs (DTV / HDMI 1-3 / Source Panel):
        // Android 9 public API 28 TvInputManager does NOT expose the currently active input/tuner of LiveTV.
        // Verification MUST fail closed whenever fresh independent UI/Activity proof is absent: never certify
        // generic tvcenter foreground alone, empty visibleTexts, or "Nessun segnale" / expired OSD banners.
        int requestedHdmiPort = -1;
        if (has(q, "hdmi 1") || has(q, "hdmi1")) requestedHdmiPort = 1;
        else if (has(q, "hdmi 2") || has(q, "hdmi2")) requestedHdmiPort = 2;
        else if (has(q, "hdmi 3") || has(q, "hdmi3")) requestedHdmiPort = 3;
        if (requestedHdmiPort > 0) {
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
        if (has(q, "digitale terrestre") || has(q, "dtv") || has(q, "antenna")
                || has(q, "canali tv") || "tv".equals(q)) {
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
        if (has(q, "ingressi") || has(q, "sorgenti") || has(q, "cambia ingresso")) {
            if (!TvInputIntentPolicy.isTvCenterPackage(pkg)) {
                return denied("tv_input", "Pannello ingressi LiveTV non e' in primo piano");
            }
            Verdict stale = checkTvInputFreshness(snapshot, nowMs, minTimestampMs);
            if (stale != null) return stale;
            if (TvInputIntentPolicy.isInputsPanelActivity(snapshot.foregroundActivity)) {
                return allowed("tv_input", "Activity InputsPanelActivity confermata in primo piano");
            }
            if (snapshot.foregroundActivity != null && !snapshot.foregroundActivity.trim().isEmpty()) {
                return denied("tv_input", "LiveTV in primo piano su activity diversa da InputsPanelActivity (" + snapshot.foregroundActivity + "): pannello ingressi non verificato");
            }
            if (TvInputIntentPolicy.hasInputsPanelUiCues(snapshot.visibleTexts)) {
                return allowed("tv_input", "Pannello selezione ingressi confermato da elenco sorgenti visibile");
            }
            return denied("tv_input", "LiveTV in primo piano senza conferma InputsPanelActivity o lista sorgenti: conferma visiva richiesta");
        }

        // For clear app-opening goals, a model-provided different pkg_is
        // cannot certify that the user-requested application was opened.
        if (has(q, "apri") || has(q, "avvia") || has(q, "vai su")) {
            String target = null;
            if (has(q, "mediaset") || has(q, "infinity")) target = "it.mediaset.infinitytv";
            else if (has(q, "youtube")) target = "com.google.android.youtube.tv";
            else if (has(q, "raiplay")) target = "it.rainet.androidtv";
            else if (has(q, "impostazioni") || has(q, "settings")) target = "com.android.tv.settings";
            if (target != null) {
                return target.equals(pkg)
                        ? allowed("open_app", "Pacchetto richiesto osservato in primo piano")
                        : denied("open_app", "L'app richiesta non e' in primo piano");
            }
        }

        // No reliable semantic classification: retain the planner's observable
        // condition (which is checked independently by the caller).
        return allowed("other", "Nessun requisito finale aggiuntivo identificato");
    }
}
