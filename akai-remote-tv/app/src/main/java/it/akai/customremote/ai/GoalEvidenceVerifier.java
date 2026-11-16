package it.akai.customremote.ai;

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

    private static boolean mentionsPlayback(String q) {
        if (has(q, "diretta") || has(q, "live") || has(q, "riproduci")
                || has(q, "guarda") || has(q, "guardare") || has(q, "fai partire")
                || has(q, "fammi vedere") || has(q, "avvia riproduzione")) {
            return true;
        }
        // Avoid confusing "metti il volume" / "avvia l'app" with playback.
        boolean mediaSubject = has(q, "video") || has(q, "film") || has(q, "episodio")
                || has(q, "puntata") || has(q, "italia 2") || has(q, "rai 1")
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
        Verdict observed = verify(goal, snapshot);
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
            } catch (Exception e) {
                return denied("multi_step", "Condizione finale malformata");
            }
        }
        return observed;
    }

    public static Verdict verify(String goal, ScreenPerceptionEngine.PerceptionSnapshot snapshot) {
        if (snapshot == null || snapshot.hasSensitiveFields) {
            return denied("unknown", "Schermata non osservabile o protetta");
        }
        String q = normalize(goal);
        String pkg = snapshot.foregroundPackage != null ? snapshot.foregroundPackage : "";

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
            if (has(q, "italia 2") && !snapshot.containsText("Italia 2", false)) {
                return denied("playback", "Il canale Italia 2 non e' identificabile");
            }
            if (has(q, "rai 1") && !snapshot.containsText("Rai 1", false)) {
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
