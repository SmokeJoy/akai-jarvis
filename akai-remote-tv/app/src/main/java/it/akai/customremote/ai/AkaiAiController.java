package it.akai.customremote.ai;

import android.content.Context;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.Locale;

import it.akai.customremote.TvController;

/**
 * AkaiAiController: Orchestratore Cognitivo Autonomo su Smart TV AKAI (v2).
 * 
 * Implementa il ciclo closed-loop:
 * 1. Percezione -> 2. Memory Lookup -> 3. Fast-Path (0 Token)
 * 4. Autonomous Discovery & Planning (Cloud LLM o Local UI Graph Planner)
 * 5. Closed-loop Execution -> 6. Verifica Schermata -> 7. Salvataggio Memoria SQLite.
 */
public class AkaiAiController {
    private static final String TAG = "AKAI_AiController";
    private static AkaiAiController sInstance = null;

    // Profilo vincolante STRICT_LOCAL_ONLY (PR #1 Milestone M1):
    // Impedisce rigorosamente qualsiasi socket/chiamata verso provider cloud o TTS esterni
    private static volatile boolean sStrictLocalOnly = true;

    public static boolean isStrictLocalOnly() {
        return sStrictLocalOnly;
    }

    public static void setStrictLocalOnly(boolean strictLocalOnly) {
        sStrictLocalOnly = strictLocalOnly;
    }

    public static org.json.JSONArray getSupportedCatalog() {
        return LocalIntentParser.getSupportedCatalog();
    }

    private final Context context;
    private final TvController tvController;
    private final AkaiMemoryEngine memoryEngine;
    private final AiProviderAdapter aiAdapter;

    public static synchronized AkaiAiController getInstance(Context context, TvController tvController) {
        if (sInstance == null) {
            sInstance = new AkaiAiController(context.getApplicationContext(), tvController);
        }
        return sInstance;
    }

    private AkaiAiController(Context context, TvController tvController) {
        this.context = context;
        this.tvController = tvController;
        this.memoryEngine = AkaiMemoryEngine.getInstance(context);
        this.aiAdapter = new AiProviderAdapter(context);
    }

    public AkaiMemoryEngine getMemoryEngine() {
        return memoryEngine;
    }

    public AiProviderAdapter getAiAdapter() {
        return aiAdapter;
    }

    public JSONObject processQuery(String userQuery) {
        return processQuery(userQuery, true);
    }

    public JSONObject processQuery(String userQuery, boolean speak) {
        long startTime = System.currentTimeMillis();
        JSONObject result = new JSONObject();

        if (userQuery == null || userQuery.trim().isEmpty()) {
            String emptyReply = "Nessuna richiesta ricevuta. Dì ad esempio: 'Metti Italia 2' o 'Imposta il volume a 20'.";
            return completeAndSpeak(result, "", emptyReply, "ERROR", null, 0, 0.0, speak, startTime);
        }

        String query = userQuery.trim();
        Log.i(TAG, "Processing request: \"" + query + "\" (speak=" + speak + ")");

        // ---------------------------------------------------------------------
        // PASSO 1: VERIFICA PROCEDURA IN MEMORIA SQLITE (O COMANDO HARDWARE)
        // ---------------------------------------------------------------------
        LocalIntentParser.ParsedIntent parsed = LocalIntentParser.parse(context, query);

        if (parsed.matched) {
            Log.i(TAG, "Fast-Path/SQLite match: " + parsed.intentKey + " (" + parsed.source + ")");

            // Verifica coerenza dello stato iniziale prima dell'esecuzione
            ScreenPerceptionEngine.PerceptionSnapshot preSnap = ScreenPerceptionEngine.capture();
            if (parsed.initialState != null && !parsed.initialState.isEmpty()) {
                try {
                    JSONObject initCond = new JSONObject(parsed.initialState);
                    String expectedPkg = initCond.optString("pkg", "");
                    boolean pkgMatches = expectedPkg.isEmpty() || expectedPkg.equals(preSnap.foregroundPackage);
                    if (!pkgMatches && ("it.akai.customhome".equals(expectedPkg) || "it.akai.customhome.v8".equals(expectedPkg)) &&
                            ("it.akai.customhome.v8".equals(preSnap.foregroundPackage) || "it.akai.customhome".equals(preSnap.foregroundPackage))) {
                        pkgMatches = true;
                    }
                    if (!pkgMatches) {
                        Log.w(TAG, "Stato iniziale non corrispondente: atteso " + expectedPkg + ", rilevato " + preSnap.foregroundPackage);
                        if ("it.akai.customhome".equals(expectedPkg) || "it.akai.customhome.v8".equals(expectedPkg)) {
                            Log.i(TAG, "Allineamento automatico: ritorno alla Home prima di eseguire la procedura memorizzata...");
                            tvController.executeCommand("home");
                            try { Thread.sleep(800); } catch (InterruptedException ignored) {}
                        }
                    }
                } catch (Exception ignored) {}
            }

            TvController.CommandResult cmdRes = tvController.executeActionSequence(parsed.actions);

            // Attesa di assestamento per il rendering della UI e buffer video
            try { Thread.sleep(1200); } catch (InterruptedException ignored) {}

            // Closed-loop verification con Context per AudioManager e Accessibility
            ScreenPerceptionEngine.PerceptionSnapshot snap = ScreenPerceptionEngine.capture(context);
            boolean hasCondition = parsed.successCondition != null && !parsed.successCondition.trim().isEmpty();
            boolean verified = hasCondition ? ScreenPerceptionEngine.evaluateSuccessCondition(snap, parsed.successCondition) : cmdRes.success;

            if (parsed.intentKey != null) {
                if (verified && cmdRes.success) {
                    memoryEngine.recordProcedureSuccess(parsed.intentKey);
                } else {
                    Log.w(TAG, "Verification failed for procedure: " + parsed.intentKey);
                    memoryEngine.recordProcedureFailure(parsed.intentKey);
                }
            }

            String status = (cmdRes.success && verified) ? "SUCCESS_VERIFIED" : (cmdRes.success ? "COMPLETED_UNVERIFIED" : "ERROR");
            String replyMsg;
            if (verified && cmdRes.success) {
                if ("italia2".equals(parsed.intentKey)) {
                    replyMsg = "Ho sintonizzato Italia 2 in diretta.";
                } else if ("rai1".equals(parsed.intentKey)) {
                    replyMsg = "Ho avviato Rai 1 in diretta.";
                } else if (parsed.responseMessage != null) {
                    replyMsg = parsed.responseMessage;
                } else {
                    replyMsg = "Comando completato con successo.";
                }
            } else if (hasCondition && !verified && cmdRes.success) {
                replyMsg = "Non sono riuscito a sintonizzare il canale o la schermata richiesta. Il player non è attivo.";
            } else {
                replyMsg = "Si è verificato un errore durante l'esecuzione del comando.";
            }

            try {
                result.put("success", cmdRes.success && verified);
                result.put("source", parsed.source); // "procedural_memory" o "local_fast_path"
                result.put("intent_key", parsed.intentKey);
                result.put("tokens", 0);
                result.put("cost_eur", 0.0);
                result.put("verified", verified);
                result.put("actions_count", parsed.actions != null ? parsed.actions.length() : 0);
            } catch (Exception ignored) {}

            return completeAndSpeak(result, query, replyMsg, status, parsed.intentKey, 0, 0.0, speak, startTime);
        }

        // ---------------------------------------------------------------------
        // PASSO 2: PROCEDURA NON NOTA -> APPRENDIMENTO ED ESPLORAZIONE AUTONOMA
        // ---------------------------------------------------------------------
        Log.i(TAG, "No procedure found in SQLite. Initiating autonomous discovery for: \"" + query + "\"");
        ScreenPerceptionEngine.PerceptionSnapshot initialSnap = ScreenPerceptionEngine.capture();

        // Livello 4: Protezione Privacy & Sicurezza
        if (initialSnap.hasSensitiveFields) {
            Log.w(TAG, "Screen contains sensitive/password fields. Aborting AI processing for security.");
            JSONObject secRes = new JSONObject();
            try {
                secRes.put("success", false);
                secRes.put("reply", "Operazione sospesa per sicurezza: rilevato campo sensibile o password sullo schermo.");
                secRes.put("source", "security_guard");
                secRes.put("tokens", 0);
                secRes.put("cost_usd", 0);
            } catch (JSONException ignored) {}
            return secRes;
        }

        String provider = aiAdapter.getActiveProvider();
        String apiKey = aiAdapter.getApiKey(provider);

        JSONArray candidateActions = null;
        String candidateKey = null;
        String candidateCondition = null;
        int promptTokens = 0, compTokens = 0, totalTokens = 0;
        double costEur = 0.0;
        String planReply = null;
        String planWarning = null;

        // Profilo vincolante STRICT_LOCAL_ONLY (PR #1 Milestone M1):
        // Se attivo (default), inibisci qualsiasi invocazione cloud/esterna e usa unicamente
        // il Local UI Graph Planner deterministico. Se non trova nodi, fail-closed immediato.
        if (sStrictLocalOnly) {
            long elapsed = System.currentTimeMillis() - startTime;
            DiscoveryPlan plan = planLocalDiscovery(query, initialSnap);
            if (plan != null) {
                candidateActions = plan.actions;
                candidateKey = generateIntentKey(query);
                candidateCondition = plan.successCondition;
                planReply = plan.reply;
            } else {
                try {
                    result.put("success", false);
                    result.put("status", "FAIL_CLOSED_UNSUPPORTED");
                    result.put("reply", "Comando non supportato in modalita locale esclusiva (PC spento). Comandi disponibili: volume, canali DTV, ingressi HDMI, navigazione Home/Indietro, avvio app.");
                    result.put("source", "strict_local_guard");
                    result.put("tokens", 0);
                    result.put("cost_eur", 0.0);
                    result.put("latency_ms", elapsed);
                    result.put("verified", false);
                    result.put("strict_local_only", true);
                } catch (Exception ignored) {}
                return completeAndSpeak(result, query, "Comando non supportato in modalita locale esclusiva.", "FAIL_CLOSED_UNSUPPORTED", null, 0, 0.0, speak, startTime);
            }
        } else if (!AiProviderAdapter.PROVIDER_LOCAL.equals(provider) && !apiKey.isEmpty()) {
            if (aiAdapter.isBudgetExceeded()) {
                long elapsed = System.currentTimeMillis() - startTime;
                try {
                    result.put("success", false);
                    result.put("status", "BUDGET_EXCEEDED");
                    result.put("reply", "Budget massimo iniziale di 5,00 € esaurito o residuo insufficiente. Richieste cloud bloccate preventivamente.");
                    result.put("source", "budget_guard");
                    result.put("tokens", 0);
                    result.put("cost_eur", 0.0);
                    result.put("latency_ms", elapsed);
                    result.put("verified", false);
                } catch (Exception ignored) {}
                return result;
            }

            JSONObject prefs = memoryEngine.getAllPreferences();
            JSONArray convHistory = memoryEngine.getRecentConversations(3);
            AiProviderAdapter.AiResponse planRes = aiAdapter.planActionSequence(query, initialSnap.toContextPrompt(), prefs, convHistory);

            if (planRes.success) {
                promptTokens = planRes.promptTokens;
                compTokens = planRes.completionTokens;
                totalTokens = planRes.totalTokens;
                costEur = planRes.costEur;
                planReply = planRes.reply;
                planWarning = planRes.warningMessage;

                // Caso A: Domanda puramente conversazionale (consiglio, dialogo) -> 0 azioni hardware richieste
                if (planRes.actions == null || planRes.actions.length() == 0) {
                    Log.i(TAG, "Conversational dialog response from AI provider: " + planReply);
                    memoryEngine.incrementStat("cloud_ai_calls", 1);
                    memoryEngine.incrementStat("prompt_tokens", promptTokens);
                    memoryEngine.incrementStat("completion_tokens", compTokens);

                    try {
                        result.put("success", true);
                        result.put("source", provider);
                        result.put("tokens", totalTokens);
                        result.put("cost_eur", costEur);
                        result.put("verified", false); // Dialogo informativo, non uno stato TV verificato
                        result.put("actions_count", 0);
                    } catch (Exception ignored) {}

                    return completeAndSpeak(result, query, planReply, "ANSWERED_DIALOG", "dialog", totalTokens, costEur, speak, startTime);
                }

                // Caso B: Richiesta operativa TV con sequenza azioni
                candidateActions = planRes.actions;
                candidateKey = planRes.intentKey;
                candidateCondition = planRes.successCondition;
            } else if (!planRes.success && planRes.error != null && planRes.error.contains("Budget")) {
                long elapsed = System.currentTimeMillis() - startTime;
                try {
                    result.put("success", false);
                    result.put("status", "BUDGET_EXCEEDED");
                    result.put("reply", planRes.error);
                    result.put("source", "budget_guard");
                    result.put("tokens", 0);
                    result.put("cost_eur", 0.0);
                    result.put("latency_ms", elapsed);
                    result.put("verified", false);
                } catch (Exception ignored) {}
                return result;
            }
        }

        // Fallback su Local UI Graph Planner se cloud non configurato o offline
        if (candidateActions == null) {
            DiscoveryPlan plan = planLocalDiscovery(query, initialSnap);
            if (plan != null) {
                candidateActions = plan.actions;
                candidateKey = generateIntentKey(query);
                candidateCondition = plan.successCondition;
                planReply = plan.reply;
            }
        }

        // Se nessun piano è stato generato:
        if (candidateActions == null || candidateActions.length() == 0) {
            long elapsed = System.currentTimeMillis() - startTime;
            try {
                result.put("success", false);
                result.put("status", "ERROR");
                result.put("reply", "Impossibile trovare un percorso per '" + query + "'. " +
                        "Assicurati che la schermata iniziale sia corretta o configura una chiave DeepSeek/Kimi per l'esplorazione autonoma.");
                result.put("source", "planner_failed");
                result.put("tokens", 0);
                result.put("latency_ms", elapsed);
                result.put("verified", false);
            } catch (Exception ignored) {}
            return result;
        }

        // ---------------------------------------------------------------------
        // PASSO 3: ESECUZIONE ED OSSERVAZIONE CLOSED-LOOP
        // ---------------------------------------------------------------------
        Log.i(TAG, "Executing planned actions (" + candidateActions.length() + " steps)...");
        TvController.CommandResult execRes = tvController.executeActionSequence(candidateActions);

        // Attesa stabilizzazione interfaccia
        try { Thread.sleep(1500); } catch (InterruptedException ignored) {}

        // Osservazione del risultato
        ScreenPerceptionEngine.PerceptionSnapshot postSnap = ScreenPerceptionEngine.capture(context);
        boolean verified = ScreenPerceptionEngine.evaluateSuccessCondition(postSnap, candidateCondition);

        Log.i(TAG, "Discovery verification: " + verified + " (postPkg=" + postSnap.foregroundPackage + ")");

        // ---------------------------------------------------------------------
        // PASSO 4: SALVATAGGIO NELLA MEMORIA PROCEDURALE SQLITE (SOLO SE VERIFICATO)
        // ---------------------------------------------------------------------
        boolean newlyLearned = false;
        if (verified && execRes.success) {
            if (candidateKey == null) candidateKey = generateIntentKey(query);
            String initialState = "{\"pkg\":\"" + initialSnap.foregroundPackage + "\"}";

            newlyLearned = memoryEngine.saveVerifiedProcedure(
                    candidateKey,
                    query.toLowerCase(Locale.ITALIAN),
                    query,
                    postSnap.foregroundPackage,
                    initialState,
                    candidateActions,
                    candidateCondition,
                    "1.0"
            );
            Log.i(TAG, "SUCCESS! New procedure learned and persisted to SQLite: " + candidateKey);
        }

        // Aggiornamento statistiche d'uso
        if (totalTokens > 0) {
            memoryEngine.incrementStat("cloud_ai_calls", 1);
            memoryEngine.incrementStat("prompt_tokens", promptTokens);
            memoryEngine.incrementStat("completion_tokens", compTokens);
        } else {
            memoryEngine.incrementStat("local_executions_zero_token", 1);
        }

        long elapsed = System.currentTimeMillis() - startTime;
        String status = (execRes.success && verified) ? "SUCCESS_VERIFIED" : (execRes.success ? "COMPLETED_UNVERIFIED" : "ERROR");
        String finalReply = planReply != null ? planReply : "Procedura completata.";
        if (!execRes.success) {
            finalReply = "Non sono riuscito a completare l'operazione: " + execRes.message;
        } else if (!verified && candidateCondition != null) {
            finalReply = "Azioni inviate, ma il risultato non è stato verificato con certezza sullo schermo.";
        }

        try {
            result.put("success", execRes.success && verified);
            result.put("source", totalTokens > 0 ? provider : "local_autonomous_planner");
            result.put("learned_new_procedure", newlyLearned);
            result.put("intent_key", candidateKey);
            result.put("actions_count", candidateActions.length());
            result.put("tokens", totalTokens);
            result.put("cost_eur", costEur);
            result.put("budget_spent_eur", aiAdapter.getTotalSpentEur());
            result.put("budget_remaining_eur", aiAdapter.getRemainingBudgetEur());
            if (planWarning != null) {
                result.put("budget_warning", planWarning);
            }
            result.put("verified", verified);
        } catch (Exception ignored) {}

        return completeAndSpeak(result, query, finalReply, status, candidateKey, totalTokens, costEur, speak, startTime);
    }

    private JSONObject completeAndSpeak(JSONObject result, String query, String replyMsg, String status,
                                        String intentKey, int tokens, double costEur, boolean speakRequested, long startTime) {
        long elapsed = System.currentTimeMillis() - startTime;
        try {
            result.put("reply", replyMsg);
            result.put("status", status);
            result.put("latency_ms", elapsed);
        } catch (Exception ignored) {}

        // 1. Voce TV: Pronuncia attraverso altoparlanti se richiesto (inibito se STRICT_LOCAL_ONLY per evitare chiamate cloud esterne)
        if (speakRequested && replyMsg != null && !replyMsg.trim().isEmpty()) {
            if (!sStrictLocalOnly) {
                try {
                    AkaiSpeechEngine speech = AkaiSpeechEngine.getInstance(context);
                    speech.speak(replyMsg, true);
                } catch (Exception e) {
                    Log.w(TAG, "Speech engine playback notice: " + e.getMessage());
                }
            }
        }

        // 2. Persistenza memoria conversazionale SQLite (budget 15 MB)
        if (query != null && !query.isEmpty()) {
            try {
                memoryEngine.saveConversationExchange(query, replyMsg, status, intentKey, tokens, costEur);
            } catch (Exception e) {
                Log.w(TAG, "Conversation memory persistence notice: " + e.getMessage());
            }
        }

        return result;
    }

    public static class DiscoveryPlan {
        public final JSONArray actions;
        public final String successCondition;
        public final String reply;

        public DiscoveryPlan(JSONArray actions, String successCondition, String reply) {
            this.actions = actions;
            this.successCondition = successCondition;
            this.reply = reply;
        }
    }

    /**
     * Local UI Graph Planner: ricerca autonoma di nodi a schermo per obiettivi TV frequenti.
     */
    private DiscoveryPlan planLocalDiscovery(String query, ScreenPerceptionEngine.PerceptionSnapshot snapshot) {
        String clean = query.toLowerCase(Locale.ITALIAN);
        JSONArray actions = new JSONArray();

        try {
            // Caso A: Impostazioni Audio (Android TV 9: Impostazioni -> Preferenze del dispositivo -> Audio)
            if (clean.contains("audio") || clean.contains("suono")) {
                actions.put(new JSONObject().put("type", "launch_app").put("pkg", "com.android.tv.settings").put("name", "Impostazioni TV"));
                actions.put(new JSONObject().put("type", "wait").put("ms", 2000));
                actions.put(new JSONObject().put("type", "click_text").put("text", "Preferenze del dispositivo"));
                actions.put(new JSONObject().put("type", "wait").put("ms", 1500));
                actions.put(new JSONObject().put("type", "click_text").put("text", "Audio"));
                String cond = "{\"type\":\"any_of_texts\",\"values\":[\"Audio\",\"Uscita digitale\",\"Altoparlanti\",\"Modalità audio\",\"Bilanciamento\",\"Equalizzatore\"]}";
                return new DiscoveryPlan(actions, cond, "Nuovo percorso scoperto: Navigazione a Impostazioni Audio TV.");
            }

            // Caso B: Impostazioni Rete / Wi-Fi (Android TV 9: Impostazioni -> Rete e Internet)
            if (clean.contains("rete") || clean.contains("wifi") || clean.contains("wi fi") || clean.contains("internet")) {
                actions.put(new JSONObject().put("type", "launch_app").put("pkg", "com.android.tv.settings").put("name", "Impostazioni TV"));
                actions.put(new JSONObject().put("type", "wait").put("ms", 2000));
                actions.put(new JSONObject().put("type", "click_text").put("text", "Rete e Internet"));
                String cond = "{\"type\":\"any_of_texts\",\"values\":[\"Rete e Internet\",\"Wi-Fi\",\"Vodafone-home\",\"Ethernet\",\"Connesso\"]}";
                return new DiscoveryPlan(actions, cond, "Nuovo percorso scoperto: Impostazioni Rete e Internet TV.");
            }

            // Caso C: Informazioni sul Dispositivo / Sistema TV
            if (clean.contains("informazioni") || clean.contains("dispositivo") || clean.contains("info tv")) {
                actions.put(new JSONObject().put("type", "launch_app").put("pkg", "com.android.tv.settings").put("name", "Impostazioni TV"));
                actions.put(new JSONObject().put("type", "wait").put("ms", 2000));
                actions.put(new JSONObject().put("type", "click_text").put("text", "Preferenze del dispositivo"));
                actions.put(new JSONObject().put("type", "wait").put("ms", 1500));
                actions.put(new JSONObject().put("type", "click_text").put("text", "Informazioni"));
                String cond = "{\"type\":\"any_of_texts\",\"values\":[\"Informazioni\",\"Modello\",\"Stato\",\"Versione\",\"Numero build\"]}";
                return new DiscoveryPlan(actions, cond, "Nuovo percorso scoperto: Informazioni di sistema TV.");
            }

            // Caso D: Canali TV Digitale Terrestre (DTV Center MediaTek)
            if (clean.contains("canali") || clean.contains("canale tv") || clean.contains("elenco canali")) {
                actions.put(new JSONObject().put("type", "launch_app").put("pkg", "com.mediatek.wwtv.tvcenter").put("name", "TV Digitale Terrestre"));
                String cond = "{\"type\":\"pkg_is\",\"value\":\"com.mediatek.wwtv.tvcenter\"}";
                return new DiscoveryPlan(actions, cond, "Nuovo percorso scoperto: Apertura Canali TV Digitale Terrestre.");
            }

            // Caso E: Ricerca su YouTube
            if (clean.contains("cerca su youtube") || clean.contains("cerca youtube")) {
                actions.put(new JSONObject().put("type", "launch_app").put("pkg", "com.google.android.youtube.tv").put("name", "YouTube"));
                actions.put(new JSONObject().put("type", "wait").put("ms", 2500));
                actions.put(new JSONObject().put("type", "click_text").put("text", "Cerca"));
                String cond = "{\"type\":\"any_of_texts\",\"values\":[\"Cerca\",\"Search\",\"Cerca su YouTube\"]}";
                return new DiscoveryPlan(actions, cond, "Nuovo percorso scoperto: Schermata Ricerca YouTube.");
            }

            // Caso F: Impostazioni Generali TV
            if (clean.contains("impostazioni") || clean.contains("settings")) {
                actions.put(new JSONObject().put("type", "launch_app").put("pkg", "com.android.tv.settings").put("name", "Impostazioni TV"));
                String cond = "{\"type\":\"pkg_is\",\"value\":\"com.android.tv.settings\"}";
                return new DiscoveryPlan(actions, cond, "Apertura Impostazioni TV.");
            }

            // Caso D: Navigazione a elemento testuale presente attualmente a schermo
            for (String t : snapshot.visibleTexts) {
                if (t.length() >= 3 && clean.contains(t.toLowerCase())) {
                    actions.put(new JSONObject().put("type", "click_text").put("text", t));
                    String cond = "{\"type\":\"contains_text\",\"value\":\"" + t + "\"}";
                    return new DiscoveryPlan(actions, cond, "Selezione elemento a schermo: \"" + t + "\"");
                }
            }
        } catch (Exception e) {
            Log.e(TAG, "Error in local discovery planning: " + e.getMessage());
        }

        return null;
    }

    private String generateIntentKey(String query) {
        String k = query.trim().toLowerCase(Locale.ITALIAN).replaceAll("[^a-z0-9]", "_").replaceAll("_+", "_");
        if (k.startsWith("_")) k = k.substring(1);
        if (k.endsWith("_")) k = k.substring(0, k.length() - 1);
        return k.length() > 30 ? k.substring(0, 30) : k;
    }
}
