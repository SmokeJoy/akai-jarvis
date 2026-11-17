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

    public static boolean matches(String userInput, String storedCandidate) {
        String user = normalize(userInput);
        String stored = normalize(storedCandidate);
        if (user.isEmpty() || stored.isEmpty() || generic(user) || generic(stored)) return false;
        if (user.equals(stored)) return true;
        // Full candidate appears as whole words within the spoken command.
        if (stored.length() >= 4 && wholeWords(user, stored)) {
            // If a skill names a single app, do not allow it to be a prefix
            // of a different app, e.g. YouTube vs YouTube Kids.
            if (stored.contains(" ") || user.endsWith(" " + stored)
                    || user.endsWith(" " + stored + " in diretta")) return true;
        }
        // User may shorten a stored description: "YouTube" vs "apri YouTube".
        if (user.length() >= 5 && wholeWords(stored, user)) return true;
        // Avoid substring-based matches by comparing exact token windows.
        return compactTokenWindow(user, stored);
    }
}
