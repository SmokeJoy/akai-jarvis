package it.akai.customremote.ai;

import android.content.Context;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * LocalIntentParser: Parser linguistico istantaneo per comandi hardware TV e consultazione
 * dinamica delle memorie procedurali in SQLite.
 * 
 * Separa rigorosamente i comandi hardware primitivi (volume, home, back, power, canali DTV)
 * dalle procedure complesse, che vengono SEMPRE ricercate nel database SQLite in modo dinamico.
 */
public class LocalIntentParser {
    private static final String TAG = "AKAI_LocalIntent";

    public static class ParsedIntent {
        public final boolean matched;
        public final String intentKey;
        public final String description;
        public final JSONArray actions;
        public final String responseMessage;
        public final String source;
        public final String successCondition;
        public final String initialState;

        public ParsedIntent(boolean matched, String intentKey, String description, JSONArray actions,
                            String responseMessage, String source, String successCondition, String initialState) {
            this.matched = matched;
            this.intentKey = intentKey;
            this.description = description;
            this.actions = actions;
            this.responseMessage = responseMessage;
            this.source = source;
            this.successCondition = successCondition;
            this.initialState = initialState;
        }

        public ParsedIntent(boolean matched, String intentKey, String description, JSONArray actions,
                            String responseMessage, String source, String successCondition) {
            this(matched, intentKey, description, actions, responseMessage, source, successCondition, null);
        }

        public static ParsedIntent notMatched() {
            return new ParsedIntent(false, null, null, null, null, null, null, null);
        }
    }

    public static ParsedIntent parse(Context context, String query) {
        if (query == null || query.trim().isEmpty()) {
            return ParsedIntent.notMatched();
        }

        String raw = query.trim().toLowerCase(Locale.ITALIAN);
        String normalized = java.text.Normalizer.normalize(raw, java.text.Normalizer.Form.NFD);
        String clean = normalized.replaceAll("\\p{InCombiningDiacriticalMarks}+", "")
                .replaceAll("[^a-z0-9\\+\\s]", " ")
                .replaceAll("\\s+", " ")
                .trim();

        Log.d(TAG, "Parsing query: \"" + clean + "\"");

        // -------------------------------------------------------------
        // 1. PRIMITIVE HARDWARE & SISTEMA (SOLO COMANDI FONDAMENTALI)
        // -------------------------------------------------------------

        // Volume assoluto: "volume a 20", "metti il volume a 25", "volume 15"
        Pattern volPattern = Pattern.compile("(?:imposta\\s+)?(?:il\\s+)?volume\\s+(?:a\\s+)?(\\d{1,3})");
        Matcher volMatcher = volPattern.matcher(clean);
        if (volMatcher.find()) {
            int level = Integer.parseInt(volMatcher.group(1));
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "volume_set").put("level", level)); } catch (Exception ignored) {}
            return new ParsedIntent(true, "volume_set", "Imposta volume a " + level, acts, "Volume impostato a " + level, "local_fast_path", null);
        }

        if (clean.equals("alza il volume") || clean.equals("alza") || clean.equals("volume su") || clean.equals("volume piu") || clean.equals("piu forte")) {
            JSONArray acts = new JSONArray();
            try {
                acts.put(new JSONObject().put("type", "command").put("action", "volume_up"));
                acts.put(new JSONObject().put("type", "command").put("action", "volume_up"));
            } catch (Exception ignored) {}
            return new ParsedIntent(true, "volume_up", "Alza volume", acts, "Volume aumentato", "local_fast_path", null);
        }

        if (clean.equals("abbassa il volume") || clean.equals("abbassa") || clean.equals("volume giu") || clean.equals("volume meno") || clean.equals("piu piano")) {
            JSONArray acts = new JSONArray();
            try {
                acts.put(new JSONObject().put("type", "command").put("action", "volume_down"));
                acts.put(new JSONObject().put("type", "command").put("action", "volume_down"));
            } catch (Exception ignored) {}
            return new ParsedIntent(true, "volume_down", "Abbassa volume", acts, "Volume abbassato", "local_fast_path", null);
        }

        if (clean.equals("muto") || clean.equals("silenzioso") || clean.equals("togli audio") || clean.equals("silenzio")) {
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "command").put("action", "volume_mute")); } catch (Exception ignored) {}
            return new ParsedIntent(true, "volume_mute", "Attiva/disattiva Muto", acts, "Stato mute alternato", "local_fast_path", null);
        }

        // Navigazione base Home / Back / Power
        if (clean.equals("home") || clean.equals("vai alla home") || clean.equals("torna alla home") || clean.equals("schermata principale") || clean.equals("esci")) {
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "command").put("action", "home")); } catch (Exception ignored) {}
            return new ParsedIntent(true, "home", "Schermata Home", acts, "Ritorno alla schermata Home...", "local_fast_path", "{\"type\":\"pkg_is\",\"value\":\"it.akai.customhome\"}");
        }

        if (clean.equals("indietro") || clean.equals("torna indietro") || clean.equals("back")) {
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "command").put("action", "back")); } catch (Exception ignored) {}
            return new ParsedIntent(true, "back", "Indietro", acts, "Azione indietro eseguita", "local_fast_path", null);
        }

        if (clean.equals("spegni") || clean.equals("spegni la tv") || clean.equals("spegniti") || clean.equals("standby")) {
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "command").put("action", "power")); } catch (Exception ignored) {}
            return new ParsedIntent(true, "power", "Spegnimento / Standby", acts, "Invio segnale Standby...", "local_fast_path", null);
        }

        // Ingressi fisici hardware
        if (clean.equals("digitale terrestre") || clean.equals("antenna") || clean.equals("tv") || clean.equals("dtv") || clean.equals("canali tv")) {
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "command").put("action", "input_tv")); } catch (Exception ignored) {}
            return new ParsedIntent(true, "input_tv", "Passa a Digitale Terrestre", acts, "Passaggio a TV Digitale Terrestre...", "local_fast_path", null);
        }

        if (clean.equals("hdmi 1") || clean.equals("hdmi1") || clean.equals("passa a hdmi 1")) {
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "command").put("action", "input_hdmi1")); } catch (Exception ignored) {}
            return new ParsedIntent(true, "input_hdmi1", "Passa a HDMI 1", acts, "Passaggio a sorgente HDMI 1...", "local_fast_path", null);
        }

        if (clean.equals("hdmi 2") || clean.equals("hdmi2") || clean.equals("passa a hdmi 2")) {
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "command").put("action", "input_hdmi2")); } catch (Exception ignored) {}
            return new ParsedIntent(true, "input_hdmi2", "Passa a HDMI 2", acts, "Passaggio a sorgente HDMI 2...", "local_fast_path", null);
        }

        // Sintonizzazione canale numerico diretto (es. "canale 5", "canale 20")
        Pattern chanPattern = Pattern.compile("^(?:metti\\s+)?(?:il\\s+)?canale\\s+(\\d{1,4})$");
        Matcher chanMatcher = chanPattern.matcher(clean);
        if (chanMatcher.find()) {
            int ch = Integer.parseInt(chanMatcher.group(1));
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "tune_channel").put("number", ch)); } catch (Exception ignored) {}
            return new ParsedIntent(true, "channel_" + ch, "Sintonizza Canale " + ch, acts, "Sintonizzazione Canale " + ch + "...", "local_fast_path", null);
        }

        // -------------------------------------------------------------
        // 1.5 CONSULTAZIONE MEMORIA PREFERENZE E CRONOLOGIA (0 TOKEN)
        // -------------------------------------------------------------
        if (clean.contains("canali preferiti") || clean.contains("canali che preferisco") || clean.contains("quali canali preferisco") || clean.equals("i miei canali")) {
            AkaiMemoryEngine mem = AkaiMemoryEngine.getInstance(context);
            String favs = mem.getPreference("favorite_channels", "[]");
            String msg;
            try {
                JSONArray arr = new JSONArray(favs);
                StringBuilder sb = new StringBuilder("I tuoi canali preferiti memorizzati sono: ");
                for (int i = 0; i < arr.length(); i++) {
                    if (i > 0 && i == arr.length() - 1) sb.append(" e ");
                    else if (i > 0) sb.append(", ");
                    sb.append(arr.getString(i));
                }
                sb.append(".");
                msg = sb.toString();
            } catch (Exception e) {
                msg = "Non ho ancora canali preferiti registrati nella tua memoria personale.";
            }
            return new ParsedIntent(true, "pref_favorite_channels", "Consultazione canali preferiti", new JSONArray(), msg, "local_memory", null);
        }

        if (clean.contains("generi preferiti") || clean.contains("cosa mi piace guardare") || clean.contains("miei gusti")) {
            AkaiMemoryEngine mem = AkaiMemoryEngine.getInstance(context);
            String favs = mem.getPreference("favorite_genres", "[]");
            String msg;
            try {
                JSONArray arr = new JSONArray(favs);
                StringBuilder sb = new StringBuilder("I generi che preferisci guardare sono: ");
                for (int i = 0; i < arr.length(); i++) {
                    if (i > 0 && i == arr.length() - 1) sb.append(" e ");
                    else if (i > 0) sb.append(", ");
                    sb.append(arr.getString(i));
                }
                sb.append(".");
                msg = sb.toString();
            } catch (Exception e) {
                msg = "Nessun genere preferito memorizzato.";
            }
            return new ParsedIntent(true, "pref_favorite_genres", "Consultazione generi preferiti", new JSONArray(), msg, "local_memory", null);
        }

        if (clean.contains("cosa hai fatto") || clean.contains("cosa hai appena fatto") || clean.contains("ultimo comando") || clean.contains("ultima operazione")) {
            AkaiMemoryEngine mem = AkaiMemoryEngine.getInstance(context);
            JSONArray convs = mem.getRecentConversations(2);
            String msg;
            if (convs != null && convs.length() > 0) {
                JSONObject last = convs.optJSONObject(convs.length() - 1);
                if (last != null) {
                    String lastQ = last.optString("user_query", "");
                    String lastA = last.optString("assistant_reply", "");
                    msg = "L'ultima richiesta completata è stata: " + lastQ + ", con esito: " + lastA;
                } else {
                    msg = "Nessuna operazione precedente registrata nella cronologia recente.";
                }
            } else {
                msg = "Nessuna operazione precedente registrata nella cronologia recente.";
            }
            return new ParsedIntent(true, "last_action_recall", "Rievocazione ultima operazione", new JSONArray(), msg, "local_memory", null);
        }

        // -------------------------------------------------------------
        // 2. CONSULTAZIONE DINAMICA DELLA MEMORIA PROCEDURALE (SQLITE)
        // -------------------------------------------------------------
        AkaiMemoryEngine mem = AkaiMemoryEngine.getInstance(context);
        JSONObject proc = mem.findProcedureByGoal(clean);
        if (proc != null) {
            String intentKey = proc.optString("intent_key");
            String desc = proc.optString("description", clean);
            JSONArray actions = proc.optJSONArray("action_sequence");
            String succCond = proc.optString("success_condition", null);
            String initState = proc.optString("initial_state", null);
            int successes = proc.optInt("success_count", 1);

            Log.i(TAG, "Procedural memory matched dynamically from SQLite: " + intentKey + " (" + successes + " previous successes)");

            return new ParsedIntent(true, intentKey, desc, actions,
                    "Esecuzione procedura memorizzata: " + desc, "procedural_memory", succCond, initState);
        }

        // Nessun match primitivo né procedurale trovato -> Richiede esplorazione autonoma
        return ParsedIntent.notMatched();
    }
}
