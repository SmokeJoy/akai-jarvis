package it.akai.customremote.ai;

import java.text.Normalizer;
import java.util.LinkedHashSet;
import java.util.Locale;
import java.util.Set;

/**
 * A2 UI click gate: refuse blind, ambiguous or high-risk clicks proposed by
 * an untrusted LLM. Uses only the latest Accessibility snapshot. No network,
 * persistent state, screenshots, reflection or Android 11+ APIs.
 *
 * Accessible labels are observations, NOT commands. The caller must still
 * execute the click through the already authorized Accessibility service.
 */
public final class UiClickTargetGate {
    private UiClickTargetGate() {}

    public static final class Decision {
        public final boolean allowed;
        public final boolean exact;
        public final String reason;

        Decision(boolean allowed, boolean exact, String reason) {
            this.allowed = allowed;
            this.exact = exact;
            this.reason = reason;
        }
    }

    private static Decision allow(boolean exact) {
        return new Decision(true, exact, exact ? "exact_visible_label" : "unique_partial_label");
    }

    private static Decision deny(String reason) {
        return new Decision(false, false, reason);
    }

    private static String normalized(String value) {
        if (value == null) return "";
        String s = Normalizer.normalize(value.trim().toLowerCase(Locale.ITALIAN),
                Normalizer.Form.NFD).replaceAll("\\p{M}+", "");
        return s.replaceAll("[^a-z0-9]+", " ").replaceAll("\\s+", " ").trim();
    }

    private static boolean highRisk(String label) {
        String s = " " + normalized(label) + " ";
        String[] blocked = {
                " elimina ", " disinstalla ", " acquista ", " abbonati ",
                " paga ", " effettua pagamento ", " conferma acquisto ",
                " cancella dati ", " ripristino dati di fabbrica ",
                " factory reset ", " formatta ", " elimina account "
        };
        for (String p : blocked) if (s.contains(p)) return true;
        return false;
    }

    public static Decision check(ScreenPerceptionEngine.PerceptionSnapshot snapshot, String requestedText) {
        if (snapshot == null) return deny("screen_unavailable");
        if (snapshot.hasSensitiveFields) return deny("sensitive_screen");
        String query = normalized(requestedText);
        if (query.length() < 2 || query.length() > 120) return deny("invalid_target");
        if (highRisk(query)) return deny("requires_explicit_owner_confirmation");

        int exactClickableMatches = 0;
        Set<String> labels = new LinkedHashSet<>();
        if (snapshot.clickableElements != null) {
            for (ScreenPerceptionEngine.ClickableElement el : snapshot.clickableElements) {
                if (el == null || el.text == null) continue;
                String label = normalized(el.text);
                if (label.isEmpty()) continue;
                if (label.equals(query)) exactClickableMatches++;
                labels.add(label);
            }
        }
        if (exactClickableMatches > 1) return deny("ambiguous_exact_clickable_target");
        if (exactClickableMatches == 1) return allow(true);

        if (snapshot.visibleTexts != null) {
            for (String text : snapshot.visibleTexts) {
                String label = normalized(text);
                if (!label.isEmpty()) labels.add(label);
            }
        }
        // Exact text may live in a child of a clickable Leanback container.
        if (labels.contains(query)) return allow(true);

        // Containment is accepted only when precisely one visible label
        // could match. Otherwise the agent must re-observe or replan.
        if (query.length() < 3) return deny("partial_target_too_short");
        int partialMatches = 0;
        for (String label : labels) {
            if (label.contains(query)) {
                if (highRisk(label)) return deny("requires_explicit_owner_confirmation");
                if (++partialMatches > 1) return deny("ambiguous_partial_target");
            }
        }
        return partialMatches == 1 ? allow(false) : deny("target_not_visible");
    }
}
