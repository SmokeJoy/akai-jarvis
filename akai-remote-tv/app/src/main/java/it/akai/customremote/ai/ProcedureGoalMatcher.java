package it.akai.customremote.ai;

import java.text.Normalizer;
import java.util.Locale;

/**
 * Bounded deterministic matching for VERIFIED SQLite procedures.
 *
 * No substring matches inside words ("tv" must not match "attiva"), and
 * generic commands ("apri", "metti") never recall an unrelated TV skill.
 * Compact compound keys such as "italia2" may match "Italia 2" as adjacent
 * complete tokens. There is no AI inference or cloud call here.
 */
public final class ProcedureGoalMatcher {
    private ProcedureGoalMatcher() {}

    public static String normalize(String raw) {
        if (raw == null) return "";
        String withoutAccents = Normalizer.normalize(raw, Normalizer.Form.NFD)
                .replaceAll("\\p{M}+", "");
        return withoutAccents.toLowerCase(Locale.ITALIAN)
                .replaceAll("[^a-z0-9]+", " ").trim().replaceAll("\\s+", " ");
    }

    private static boolean generic(String normalized) {
        return "apri".equals(normalized) || "metti".equals(normalized)
                || "avvia".equals(normalized) || "vai".equals(normalized)
                || "tv".equals(normalized) || "ok".equals(normalized);
    }

    private static boolean wholeWords(String phrase, String needle) {
        return !needle.isEmpty() && (" " + phrase + " ").contains(" " + needle + " ");
    }

    /**
     * Compatibility for stored "italia2" vs user "Italia 2", but ONLY when
     * the full candidate equals a contiguous window of up to 4 user tokens.
     * Never interpret "italia2" as "italia20" or "attiva" as "tv".
     */
    private static boolean compactTokenWindow(String haystack, String candidate) {
        String[] words = haystack.split(" ");
        String target = candidate.replace(" ", "");
        if (target.length() < 4 || words.length == 0) return false;
        for (int i = 0; i < words.length; i++) {
            StringBuilder joined = new StringBuilder();
            for (int j = i; j < words.length && j < i + 4; j++) {
                joined.append(words[j]);
                // One-token substring hits must be handled by the explicit
                // whole-word rule below, which avoids "YouTube" -> "YouTube Kids".
                if (j > i && joined.length() == target.length()
                        && target.equals(joined.toString())) return true;
                if (joined.length() >= target.length()) break;
            }
        }
        return false;
    }

    private static String target(String phrase) {
        String value = phrase.replaceFirst("^(apri|metti|avvia|vai) ", "");
        value = value.replaceFirst("^l app ", "");
        value = value.replaceFirst(" in diretta$", "");
        return value;
    }

    private static boolean sameTarget(String left, String right) {
        if (left.equals(right)) return true;
        // Channel names may be written with or without the digit separator.
        // Do not collapse arbitrary app names (e.g. YouTube Kids).
        return left.matches("[a-z]+ [0-9]+") && left.replace(" ", "").equals(right)
                || right.matches("[a-z]+ [0-9]+") && right.replace(" ", "").equals(left);
    }

    public static boolean matches(String userInput, String storedCandidate) {
        String user = normalize(userInput);
        String stored = normalize(storedCandidate);
        if (user.isEmpty() || stored.isEmpty() || generic(user) || generic(stored)) return false;
        // Never recall an executable skill for a question or negated request.
        // This guard deliberately rejects ambiguous language instead of guessing.
        if ((" " + user + " ").matches(".* (non|no|evita|senza|annulla|stop|ferma) .*")
                || user.matches("^(come|perche|quando|puoi|potresti|sai)(\\s+.*)?$")) return false;
        if (user.equals(stored)) return true;
        return sameTarget(target(user), target(stored));
    }
}
