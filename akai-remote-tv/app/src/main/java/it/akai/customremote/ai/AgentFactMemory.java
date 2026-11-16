package it.akai.customremote.ai;

import org.json.JSONObject;
import java.security.MessageDigest;
import java.nio.charset.StandardCharsets;
import java.util.Iterator;
import java.util.Locale;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.Set;
import java.util.List;
import java.util.Comparator;

/**
 * Explicit, bounded long-lived facts stored in the existing user_preferences
 * SQLite table (is_personal=1). No new service, background listener or schema
 * migration. Facts are saved ONLY upon a direct "ricorda che" command.
 */
public final class AgentFactMemory {
    public static final int MAX_FACTS = 24;
    public static final int MAX_FACT_CHARS = 220;
    private static final String KEY_PREFIX = "agent_fact_";

    private AgentFactMemory() {}

    private static String normalize(String fact) {
        return fact == null ? "" : fact.trim().replaceAll("\\s+", " ").toLowerCase(Locale.ITALIAN);
    }

    private static String factKey(String fact) {
        try {
            byte[] hash = MessageDigest.getInstance("SHA-256").digest(
                normalize(fact).getBytes(StandardCharsets.UTF_8));
            StringBuilder hex = new StringBuilder(KEY_PREFIX);
            for (int i = 0; i < 12; i++) hex.append(String.format(Locale.ROOT, "%02x", hash[i] & 0xff));
            return hex.toString();
        } catch (Exception e) {
            return null; // no unvalidated persistence fallback
        }
    }

    private static int countFacts(JSONObject preferences) {
        if (preferences == null) return 0;
        int count = 0;
        Iterator<String> keys = preferences.keys();
        while (keys.hasNext()) {
            if (keys.next().startsWith(KEY_PREFIX)) count++;
        }
        return count;
    }


    /**
     * Retrieve only query-relevant, explicitly remembered facts. This is a
     * bounded local shortlist, not semantic embeddings or an automatic cloud
     * upload. Caller must check cloud-consent before sending any result.
     */
    public static org.json.JSONArray relevantFacts(AkaiMemoryEngine memory, String query, int maxFacts) {
        org.json.JSONArray out = new org.json.JSONArray();
        if (memory == null || memory.isGuestMode() || query == null
                || query.trim().isEmpty() || maxFacts < 1) return out;
        final Set<String> queryWords = meaningfulWords(query);
        if (queryWords.isEmpty()) return out;
        JSONObject prefs = memory.getAllPreferences();
        if (prefs == null) return out;
        List<ScoredFact> matches = new ArrayList<>();
        Iterator<String> keys = prefs.keys();
        while (keys.hasNext()) {
            String key = keys.next();
            if (!key.startsWith(KEY_PREFIX)) continue;
            String fact = prefs.optString(key, "");
            if (fact.isEmpty() || fact.length() > MAX_FACT_CHARS) continue;
            Set<String> factWords = meaningfulWords(fact);
            int score = 0;
            for (String word : queryWords) if (factWords.contains(word)) score++;
            if (score > 0) matches.add(new ScoredFact(fact, score));
        }
        java.util.Collections.sort(matches, new Comparator<ScoredFact>() {
            @Override
            public int compare(ScoredFact first, ScoredFact second) {
                int byScore = Integer.compare(second.score, first.score);
                return byScore != 0 ? byScore : first.text.compareTo(second.text);
            }
        });
        int count = Math.min(3, Math.max(1, maxFacts));
        int budget = 550; // upper bound on private context sent to LLM
        for (ScoredFact match : matches) {
            if (out.length() >= count || match.text.length() > budget) break;
            out.put(match.text);
            budget -= match.text.length();
        }
        return out;
    }

    private static final class ScoredFact {
        final String text;
        final int score;
        ScoredFact(String text, int score) {
            this.text = text;
            this.score = score;
        }
    }

    private static Set<String> meaningfulWords(String text) {
        Set<String> result = new HashSet<>();
        String folded = java.text.Normalizer.normalize(
                text.toLowerCase(Locale.ITALIAN), java.text.Normalizer.Form.NFD)
                .replaceAll("\\p{InCombiningDiacriticalMarks}+", "");
        for (String word : folded.split("[^a-z0-9]+")) {
            if (word.length() >= 4 && !COMMON_WORDS.contains(word)) result.add(word);
        }
        return result;
    }

    private static final Set<String> COMMON_WORDS =
            new HashSet<>(java.util.Arrays.asList(
                "sono", "della", "delle", "degli", "nella", "nelle", "come",
                "quando", "quale", "quali", "questo", "questa", "anche", "perche",
                "ricorda", "ricordi", "jarvis", "vorrei", "potresti", "sempre",
                "dimentica", "favore", "puoi", "fatto", "avere", "essere"
            ));

    public static String remember(AkaiMemoryEngine memory, String rawFact) {
        if (memory == null) return "Memoria non disponibile.";
        if (memory.isGuestMode()) return "Modalita Ospite attiva: non salvo informazioni personali.";
        String fact = rawFact == null ? "" : rawFact.trim().replaceAll("\\s+", " ");
        if (fact.isEmpty() || fact.length() > MAX_FACT_CHARS || fact.matches("(?s).*\\p{Cntrl}.*")) {
            return "Informazione vuota, troppo lunga o non valida: non salvata.";
        }
        String key = factKey(fact);
        if (key == null) return "Impossibile verificare la chiave della memoria.";
        JSONObject prefs = memory.getAllPreferences();
        if (prefs != null && prefs.has(key)) return "Questa informazione e gia presente nella memoria.";
        if (countFacts(prefs) >= MAX_FACTS) {
            return "La memoria personale rapida e piena. Dimentica un'informazione prima di aggiungerne altre.";
        }
        return memory.setPreference(key, fact, "agent_fact", 1)
            ? "Ho memorizzato questa informazione per le prossime conversazioni."
            : "Non sono riuscito a salvare l'informazione.";
    }

    public static String recall(AkaiMemoryEngine memory) {
        if (memory == null) return "Memoria non disponibile.";
        if (memory.isGuestMode()) return "Modalita Ospite attiva: non mostro informazioni personali.";
        JSONObject prefs = memory.getAllPreferences();
        if (countFacts(prefs) == 0) return "Non ho ancora informazioni personali che mi hai chiesto di ricordare.";
        StringBuilder out = new StringBuilder("Ricordo: ");
        Iterator<String> keys = prefs.keys();
        int shown = 0;
        while (keys.hasNext() && shown < MAX_FACTS) {
            String key = keys.next();
            if (!key.startsWith(KEY_PREFIX)) continue;
            String value = prefs.optString(key, "").trim();
            if (value.isEmpty()) continue;
            if (shown > 0) out.append("; ");
            out.append(value);
            shown++;
        }
        return shown == 0 ? "Non ho ancora informazioni personali che mi hai chiesto di ricordare." : out.toString() + ".";
    }

    public static String forget(AkaiMemoryEngine memory, String rawFact) {
        if (memory == null) return "Memoria non disponibile.";
        if (memory.isGuestMode()) return "Modalita Ospite attiva: memoria personale non accessibile.";
        String key = factKey(rawFact);
        if (key == null || rawFact == null || rawFact.trim().isEmpty()) {
            return "Indica quale informazione devo dimenticare.";
        }
        return memory.deletePreference(key)
            ? "Ho eliminato questa informazione dalla memoria personale."
            : "Non ho trovato questa informazione esatta nella memoria personale.";
    }
}
