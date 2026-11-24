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

        Log.d(TAG, "Parsing query (length=" + query.length() + ")");

        // A0: Personal memory is opt-in, local and bounded; never infer facts
        // from ordinary conversation. Handle it before any command matching.
        if (context != null) {
            String memoryPhrase = query.trim().replaceFirst("(?i)^jarvis[,\\s:.!]+", "").trim();
            String memoryCommand = memoryPhrase.toLowerCase(Locale.ITALIAN);
            if (memoryCommand.startsWith("ricorda che ")) {
                String fact = memoryPhrase.substring("ricorda che ".length()).trim();
                String reply = AgentFactMemory.remember(AkaiMemoryEngine.getInstance(context), fact);
                return new ParsedIntent(true, "agent_fact_remember", "Memoria personale esplicita",
                        new JSONArray(), reply, "local_memory", null);
            }
            if (memoryCommand.equals("cosa ricordi di me") || memoryCommand.equals("cosa ti ricordi di me")
                    || memoryCommand.equals("quali cose ricordi di me")) {
                String reply = AgentFactMemory.recall(AkaiMemoryEngine.getInstance(context));
                return new ParsedIntent(true, "agent_fact_recall", "Consultazione memoria personale",
                        new JSONArray(), reply, "local_memory", null);
            }
            if (memoryCommand.startsWith("dimentica che ")) {
                String fact = memoryPhrase.substring("dimentica che ".length()).trim();
                String reply = AgentFactMemory.forget(AkaiMemoryEngine.getInstance(context), fact);
                return new ParsedIntent(true, "agent_fact_forget", "Rimozione memoria personale",
                        new JSONArray(), reply, "local_memory", null);
            }
        }

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
            return new ParsedIntent(true, "home", "Schermata Home", acts, "Ritorno alla schermata Home...", "local_fast_path", "{\"type\":\"pkg_any_of\",\"values\":[\"it.akai.customhome.v8\",\"it.akai.customhome\"]}");
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

        // Ingressi fisici hardware (verifica indipendente pkg_is tvcenter + GoalEvidenceVerifier OSD/TIF)
        String tvCenterCond = "{\"type\":\"pkg_is\",\"value\":\"com.mediatek.wwtv.tvcenter\"}";
        if (clean.equals("digitale terrestre") || clean.equals("passa al digitale terrestre")
                || clean.equals("antenna") || clean.equals("tv")
                || clean.equals("dtv") || clean.equals("canali tv")) {
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "command").put("action", "input_tv")); } catch (Exception ignored) {}
            return new ParsedIntent(true, "input_tv", "Passa a Digitale Terrestre", acts, "Passaggio a TV Digitale Terrestre...", "local_fast_path", tvCenterCond);
        }

        if (clean.equals("hdmi 1") || clean.equals("hdmi1") || clean.equals("passa a hdmi 1") || clean.equals("metti hdmi 1")) {
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "command").put("action", "input_hdmi1")); } catch (Exception ignored) {}
            return new ParsedIntent(true, "input_hdmi1", "Passa a HDMI 1", acts, "Passaggio a sorgente HDMI 1...", "local_fast_path", tvCenterCond);
        }

        if (clean.equals("hdmi 2") || clean.equals("hdmi2") || clean.equals("passa a hdmi 2") || clean.equals("metti hdmi 2")) {
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "command").put("action", "input_hdmi2")); } catch (Exception ignored) {}
            return new ParsedIntent(true, "input_hdmi2", "Passa a HDMI 2", acts, "Passaggio a sorgente HDMI 2...", "local_fast_path", tvCenterCond);
        }

        if (clean.equals("hdmi 3") || clean.equals("hdmi3") || clean.equals("passa a hdmi 3") || clean.equals("metti hdmi 3")) {
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "command").put("action", "input_hdmi3")); } catch (Exception ignored) {}
            return new ParsedIntent(true, "input_hdmi3", "Passa a HDMI 3", acts, "Passaggio a sorgente HDMI 3...", "local_fast_path", tvCenterCond);
        }

        if (clean.equals("ingressi") || clean.equals("sorgenti") || clean.equals("selezione ingressi")
                || clean.equals("cambia ingresso") || clean.equals("apri ingressi")) {
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "command").put("action", "input_source")); } catch (Exception ignored) {}
            return new ParsedIntent(true, "input_source", "Apri selezione ingressi TV", acts, "Apertura pannello ingressi TV...", "local_fast_path", tvCenterCond);
        }

        // Cambio canale relativo (avanti / indietro)
        if (clean.equals("canale su") || clean.equals("canale successivo") || clean.equals("prossimo canale") || clean.equals("avanti canale") || clean.equals("canale piu")) {
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "command").put("action", "channel_up")); } catch (Exception ignored) {}
            return new ParsedIntent(true, "channel_up", "Canale successivo", acts, "Canale successivo...", "local_fast_path", null);
        }

        if (clean.equals("canale giu") || clean.equals("canale precedente") || clean.equals("canale prima") || clean.equals("canale meno")) {
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "command").put("action", "channel_down")); } catch (Exception ignored) {}
            return new ParsedIntent(true, "channel_down", "Canale precedente", acts, "Canale precedente...", "local_fast_path", null);
        }

        // Canali TV Italiani Nominali Diretti (DTV)
        int namedChannel = -1;
        String namedChannelTitle = null;
        if (clean.equals("rai 1") || clean.equals("rai1") || clean.equals("rai uno") || clean.equals("metti rai 1") || clean.equals("metti rai uno")) {
            namedChannel = 1; namedChannelTitle = "Rai 1";
        } else if (clean.equals("rai 2") || clean.equals("rai2") || clean.equals("rai due") || clean.equals("metti rai 2") || clean.equals("metti rai due")) {
            namedChannel = 2; namedChannelTitle = "Rai 2";
        } else if (clean.equals("rai 3") || clean.equals("rai3") || clean.equals("rai tre") || clean.equals("metti rai 3") || clean.equals("metti rai tre")) {
            namedChannel = 3; namedChannelTitle = "Rai 3";
        } else if (clean.equals("rete 4") || clean.equals("rete4") || clean.equals("rete quattro") || clean.equals("metti rete 4")) {
            namedChannel = 4; namedChannelTitle = "Rete 4";
        } else if (clean.equals("canale 5") || clean.equals("canale5") || clean.equals("canale cinque") || clean.equals("metti canale 5")) {
            namedChannel = 5; namedChannelTitle = "Canale 5";
        } else if (clean.equals("italia 1") || clean.equals("italia1") || clean.equals("italia uno") || clean.equals("metti italia 1")) {
            namedChannel = 6; namedChannelTitle = "Italia 1";
        } else if (clean.equals("la 7") || clean.equals("la7") || clean.equals("la sette") || clean.equals("metti la 7")) {
            namedChannel = 7; namedChannelTitle = "La 7";
        }

        if (namedChannel > 0) {
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "tune_channel").put("number", namedChannel)); } catch (Exception ignored) {}
            return new ParsedIntent(true, "channel_" + namedChannel, "Sintonizza " + namedChannelTitle, acts, "Sintonizzazione " + namedChannelTitle + " (Canale " + namedChannel + ")...", "local_fast_path", tvCenterCond);
        }

        // Sintonizzazione canale numerico diretto (es. "canale 5", "canale 20")
        Pattern chanPattern = Pattern.compile("^(?:metti\\s+)?(?:il\\s+)?canale\\s+(\\d{1,4})$");
        Matcher chanMatcher = chanPattern.matcher(clean);
        if (chanMatcher.find()) {
            int ch = Integer.parseInt(chanMatcher.group(1));
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "tune_channel").put("number", ch)); } catch (Exception ignored) {}
            return new ParsedIntent(true, "channel_" + ch, "Sintonizza Canale " + ch, acts, "Sintonizzazione Canale " + ch + "...", "local_fast_path", tvCenterCond);
        }

        // Navigazione D-Pad e Menu
        if (clean.equals("su") || clean.equals("in alto") || clean.equals("freccia su") || clean.equals("muovi su")) {
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "command").put("action", "dpad_up")); } catch (Exception ignored) {}
            return new ParsedIntent(true, "dpad_up", "Sposta cursore in alto", acts, "Cursore su", "local_fast_path", null);
        }
        if (clean.equals("giu") || clean.equals("in basso") || clean.equals("freccia giu") || clean.equals("muovi giu")) {
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "command").put("action", "dpad_down")); } catch (Exception ignored) {}
            return new ParsedIntent(true, "dpad_down", "Sposta cursore in basso", acts, "Cursore giu", "local_fast_path", null);
        }
        if (clean.equals("sinistra") || clean.equals("a sinistra") || clean.equals("freccia sinistra")) {
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "command").put("action", "dpad_left")); } catch (Exception ignored) {}
            return new ParsedIntent(true, "dpad_left", "Sposta cursore a sinistra", acts, "Cursore a sinistra", "local_fast_path", null);
        }
        if (clean.equals("destra") || clean.equals("a destra") || clean.equals("freccia destra")) {
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "command").put("action", "dpad_right")); } catch (Exception ignored) {}
            return new ParsedIntent(true, "dpad_right", "Sposta cursore a destra", acts, "Cursore a destra", "local_fast_path", null);
        }
        if (clean.equals("ok") || clean.equals("conferma") || clean.equals("seleziona") || clean.equals("invio") || clean.equals("premi ok")) {
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "command").put("action", "dpad_center")); } catch (Exception ignored) {}
            return new ParsedIntent(true, "dpad_center", "Conferma selezione (OK)", acts, "Tasto OK inviato", "local_fast_path", null);
        }
        if (clean.equals("menu") || clean.equals("apri menu") || clean.equals("tasto menu")) {
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "command").put("action", "menu")); } catch (Exception ignored) {}
            return new ParsedIntent(true, "menu", "Apri Menu TV", acts, "Tasto Menu inviato", "local_fast_path", null);
        }

        // Avvio Applicazioni Multimediali
        if (clean.equals("apri youtube") || clean.equals("avvia youtube") || clean.equals("youtube") || clean.equals("vai su youtube")) {
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "command").put("action", "launch_youtube")); } catch (Exception ignored) {}
            return new ParsedIntent(true, "launch_youtube", "Avvia YouTube TV", acts, "Avvio di YouTube TV in corso...", "local_fast_path", "{\"type\":\"pkg_is\",\"value\":\"com.google.android.youtube.tv\"}");
        }
        if (clean.equals("apri raiplay") || clean.equals("avvia raiplay") || clean.equals("raiplay") || clean.equals("vai su raiplay")) {
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "command").put("action", "launch_raiplay")); } catch (Exception ignored) {}
            return new ParsedIntent(true, "launch_raiplay", "Avvia RaiPlay", acts, "Avvio di RaiPlay in corso...", "local_fast_path", "{\"type\":\"pkg_is\",\"value\":\"it.rainet.androidtv\"}");
        }
        if (clean.equals("apri mediaset") || clean.equals("avvia mediaset") || clean.equals("mediaset") || clean.equals("infinity") || clean.equals("mediaset infinity")) {
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "command").put("action", "launch_mediaset")); } catch (Exception ignored) {}
            return new ParsedIntent(true, "launch_mediaset", "Avvia Mediaset Infinity", acts, "Avvio di Mediaset Infinity in corso...", "local_fast_path", "{\"type\":\"pkg_is\",\"value\":\"it.mediaset.infinitytv\"}");
        }
        if (clean.equals("apri browser") || clean.equals("avvia browser") || clean.equals("browser") || clean.equals("internet") || clean.equals("naviga")) {
            JSONArray acts = new JSONArray();
            try { acts.put(new JSONObject().put("type", "command").put("action", "launch_browser")); } catch (Exception ignored) {}
            return new ParsedIntent(true, "launch_browser", "Avvia TV Bro Browser", acts, "Avvio del browser in corso...", "local_fast_path", "{\"type\":\"pkg_is\",\"value\":\"com.phlox.tvwebbrowser\"}");
        }

        // -------------------------------------------------------------
        // 1.5 CONSULTAZIONE MEMORIA PREFERENZE E CRONOLOGIA (0 TOKEN)
        // -------------------------------------------------------------
        if (context != null) {
            if (clean.contains("canali preferiti") || clean.contains("canali che preferisco") || clean.contains("quali canali preferisco") || clean.equals("i miei canali")) {
                AkaiMemoryEngine mem = AkaiMemoryEngine.getInstance(context);
                if (mem.isGuestMode()) {
                    return new ParsedIntent(true, "pref_favorite_channels", "Consultazione canali preferiti", new JSONArray(),
                            "La modalità Ospite è attiva. I canali preferiti personali sono protetti e non accessibili.", "local_memory", null);
                }
                String favs = mem.getPreference("favorite_channels", "[]");
                String msg;
                try {
                    JSONArray arr = new JSONArray(favs);
                    StringBuilder sb = new StringBuilder("I tuoi canali preferiti memorizzati sono: ");
                    for (int i = 0; i < arr.length(); i++) {
                        if (i > 0 && i == arr.length() - 1) sb.append(" e ");
                        else if (i > 0) sb.append(", ");
                        sb.append(arr.optString(i));
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
                if (mem.isGuestMode()) {
                    return new ParsedIntent(true, "pref_favorite_genres", "Consultazione generi preferiti", new JSONArray(),
                            "La modalità Ospite è attiva. I generi e i gusti personali sono protetti e non accessibili.", "local_memory", null);
                }
                String favs = mem.getPreference("favorite_genres", "[]");
                String msg;
                try {
                    JSONArray arr = new JSONArray(favs);
                    StringBuilder sb = new StringBuilder("I generi che preferisci guardare sono: ");
                    for (int i = 0; i < arr.length(); i++) {
                        if (i > 0 && i == arr.length() - 1) sb.append(" e ");
                        else if (i > 0) sb.append(", ");
                        sb.append(arr.optString(i));
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
                if (mem.isGuestMode()) {
                    return new ParsedIntent(true, "last_action_recall", "Rievocazione ultima operazione", new JSONArray(),
                            "La modalità Ospite è attiva. La cronologia delle operazioni recenti è protetta.", "local_memory", null);
                }
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

                Log.i(TAG, "Procedural memory matched (key redacted; success_count=" + successes + ")");

                return new ParsedIntent(true, intentKey, desc, actions,
                        "Esecuzione procedura memorizzata: " + desc, "procedural_memory", succCond, initState);
            }
        }

        // A2: apri una qualunque app installata tramite il nome esatto mostrato
        // da Android, senza API e senza una whitelist scritta a mano. Le skill
        // SQLite restano prioritarie; richieste composte non sono intercettate.
        ParsedIntent installedApp = resolveInstalledAppLaunch(context, clean);
        if (installedApp.matched) return installedApp;

        // Nessun match primitivo né procedurale trovato -> Richiede esplorazione autonoma
        return ParsedIntent.notMatched();
    }

    /**
     * Fast local app opening by Android's own application label.
     * Exact name and unique match only; ambiguous or compound requests remain
     * for the existing AI planner. No network access, no persistent cache, and
     * no Android 11+ APIs are necessary on the Android 9 TV.
     */
    private static ParsedIntent resolveInstalledAppLaunch(Context context, String clean) {
        if (context == null || clean == null) return ParsedIntent.notMatched();
        Matcher m = Pattern.compile(
                "^(?:jarvis\\s+)?(?:apri|avvia|vai\\s+su)\\s+(?:l\\s+app\\s+|l\\s+applicazione\\s+|app\\s+|applicazione\\s+)?(.+)$"
        ).matcher(clean);
        if (!m.matches()) return ParsedIntent.notMatched();
        String target = m.group(1).trim();
        if (target.isEmpty() || target.length() > 75) return ParsedIntent.notMatched();

        try {
            android.content.pm.PackageManager pm = context.getPackageManager();
            if (pm == null) return ParsedIntent.notMatched();
            java.util.List<android.content.pm.ApplicationInfo> apps = pm.getInstalledApplications(0);
            if (apps == null) return ParsedIntent.notMatched();
            String selectedPkg = null;
            String selectedLabel = null;
            int scanned = 0;
            for (android.content.pm.ApplicationInfo app : apps) {
                if (++scanned > 300) break; // Bound work on low-RAM hardware.
                if (app == null || app.packageName == null) continue;
                String pkg = app.packageName;
                if (pkg.equals("it.akai.customhome") || pkg.equals("it.akai.customhome.v8")
                        || pkg.equals("it.akai.customremote")) continue;
                CharSequence labelCs;
                try {
                    labelCs = pm.getApplicationLabel(app);
                } catch (RuntimeException e) {
                    continue;
                }
                if (labelCs == null) continue;
                String label = labelCs.toString().trim();
                String normalizedLabel = java.text.Normalizer.normalize(
                        label.toLowerCase(Locale.ITALIAN), java.text.Normalizer.Form.NFD)
                        .replaceAll("\\p{InCombiningDiacriticalMarks}+", "")
                        .replaceAll("[^a-z0-9\\+\\s]", " ")
                        .replaceAll("\\s+", " ").trim();
                if (!target.equals(normalizedLabel)) continue;
                // Do not accept a package merely because it exists on disk:
                // the device must actually expose a launchable TV/phone entry.
                if (pm.getLeanbackLaunchIntentForPackage(pkg) == null
                        && pm.getLaunchIntentForPackage(pkg) == null) continue;
                if (selectedPkg != null) {
                    Log.w(TAG, "App launch label ambiguous; deferring to planner");
                    return ParsedIntent.notMatched();
                }
                selectedPkg = pkg;
                selectedLabel = label;
            }
            if (selectedPkg == null) return ParsedIntent.notMatched();
            JSONArray actions = new JSONArray();
            actions.put(new JSONObject().put("type", "launch_app").put("pkg", selectedPkg)
                    .put("name", selectedLabel));
            JSONObject cond = new JSONObject().put("type", "pkg_is").put("value", selectedPkg);
            return new ParsedIntent(true, "launch_installed_app_" + selectedPkg,
                    "Avvia " + selectedLabel, actions, "Apertura " + selectedLabel + " in corso...",
                    "local_installed_app", cond.toString());
        } catch (Exception e) {
            Log.w(TAG, "Cannot resolve installed app name");
            return ParsedIntent.notMatched();
        }
    }

    public static JSONArray getSupportedCatalog() {
        JSONArray arr = new JSONArray();
        arr.put("volume_up");
        arr.put("volume_down");
        arr.put("volume_set");
        arr.put("volume_mute");
        arr.put("channel_up");
        arr.put("channel_down");
        arr.put("tune_channel");
        arr.put("home");
        arr.put("back");
        arr.put("power");
        arr.put("input_tv");
        arr.put("input_hdmi1");
        arr.put("input_hdmi2");
        arr.put("input_hdmi3");
        arr.put("input_source");
        arr.put("dpad_up");
        arr.put("dpad_down");
        arr.put("dpad_left");
        arr.put("dpad_right");
        arr.put("dpad_center");
        arr.put("menu");
        arr.put("launch_youtube");
        arr.put("launch_raiplay");
        arr.put("launch_mediaset");
        arr.put("launch_browser");
        arr.put("launch_installed_app_by_label");
        return arr;
    }
}
