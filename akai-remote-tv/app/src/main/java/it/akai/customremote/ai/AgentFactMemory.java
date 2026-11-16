package it.akai.customremote.ai;

import org.json.JSONObject;
import java.security.MessageDigest;
import java.nio.charset.StandardCharsets;
import java.util.Iterator;
import java.util.Locale;

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
