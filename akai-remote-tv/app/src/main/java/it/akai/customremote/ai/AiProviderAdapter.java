package it.akai.customremote.ai;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.Base64;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

/**
 * AiProviderAdapter: Client REST per DeepSeek e Moonshot Kimi (v3).
 * 
 * Include:
 * - Modelli ufficiali aggiornati: deepseek-flash (default), deepseek-v4-pro, kimi-k2.6.
 * - Two-Phase Budget Reservation: stima massima prudenziale, prenotazione atomica concorrente
 *   e rilascio/rendicontazione a costo 0 su errore/timeout.
 * - Limite massimo condiviso: 5,00 € con avvisi a 3,00 € e 4,00 €, blocco preventivo rigoroso.
 * - Zero disclosure credenziali e cifratura hardware Keystore TrustZone.
 */
public class AiProviderAdapter {
    private static final String TAG = "AKAI_AiAdapter";
    private static final String PREFS_NAME = "akai_ai_security_prefs";
    private static final String KEY_DEEPSEEK_KEY = "sec_enc_deepseek_key";
    private static final String KEY_KIMI_KEY = "sec_enc_kimi_key";
    private static final String KEY_PROVIDER = "active_provider";
    private static final String KEY_MODEL = "active_model";

    public static final String PROVIDER_LOCAL = "local";
    public static final String PROVIDER_DEEPSEEK = "deepseek";
    public static final String PROVIDER_KIMI = "kimi";

    public static final String ENDPOINT_DEEPSEEK = "https://api.deepseek.com/chat/completions";
    public static final String ENDPOINT_KIMI = "https://api.moonshot.cn/v1/chat/completions";

    // Modelli ufficiali supportati aggiornati
    public static final String MODEL_DEEPSEEK_FLASH = "deepseek-flash";
    public static final String MODEL_DEEPSEEK_V4_PRO = "deepseek-v4-pro";
    public static final String MODEL_DEEPSEEK_R1 = "deepseek-reasoner";
    public static final String MODEL_DEEPSEEK_LEGACY = "deepseek-chat";

    public static final String MODEL_KIMI_K2_6 = "kimi-k2.6";
    public static final String MODEL_KIMI_8K = "moonshot-v1-8k";
    public static final String MODEL_KIMI_32K = "moonshot-v1-32k";
    public static final String MODEL_KIMI_128K = "moonshot-v1-128k";

    // Regole di budget definitive per rete domestica
    public static final double TOTAL_BUDGET_EUR = 5.00;
    public static final double WARN_THRESHOLD_1_EUR = 3.00;
    public static final double WARN_THRESHOLD_2_EUR = 4.00;
    public static final double USD_TO_EUR = 0.92;
    private static final String KEY_TOTAL_SPENT_EUR = "budget_total_spent_eur";

    // Sincronizzazione atomica e tracciamento concorrente prenotazioni in-flight
    private static final Object BUDGET_LOCK = new Object();
    private static double sInFlightReservedEur = 0.0;

    public static class AiResponse {
        public final boolean success;
        public final String reply;
        public final JSONArray actions;
        public final String intentKey;
        public final String goalIntent;
        public final String successCondition;
        public final boolean learnProcedure;
        public final int promptTokens;
        public final int completionTokens;
        public final int totalTokens;
        public final double costEur;
        public final String warningMessage;
        public final String error;

        public AiResponse(boolean success, String reply, JSONArray actions, String intentKey,
                          String goalIntent, String successCondition, boolean learnProcedure,
                          int promptTokens, int completionTokens, int totalTokens, double costEur,
                          String warningMessage, String error) {
            this.success = success;
            this.reply = reply;
            this.actions = actions != null ? actions : new JSONArray();
            this.intentKey = intentKey;
            this.goalIntent = goalIntent;
            this.successCondition = successCondition;
            this.learnProcedure = learnProcedure;
            this.promptTokens = promptTokens;
            this.completionTokens = completionTokens;
            this.totalTokens = totalTokens;
            this.costEur = costEur;
            this.warningMessage = warningMessage;
            this.error = error;
        }

        public static AiResponse failure(String error) {
            return new AiResponse(false, null, null, null, null, null, false, 0, 0, 0, 0.0, null, error);
        }
    }

    private final Context context;
    private final SharedPreferences prefs;

    public AiProviderAdapter(Context context) {
        this.context = context.getApplicationContext();
        this.prefs = this.context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
    }

    // -------------------------------------------------------------
    // GESTIONE CONFIGURAZIONI & SICUREZZA CHIAVI
    // -------------------------------------------------------------

    public String getActiveProvider() {
        return prefs.getString(KEY_PROVIDER, PROVIDER_DEEPSEEK);
    }

    public void setActiveProvider(String provider) {
        prefs.edit().putString(KEY_PROVIDER, provider).apply();
    }

    public String getActiveModel() {
        String prov = getActiveProvider();
        if (PROVIDER_KIMI.equals(prov)) {
            String m = prefs.getString(KEY_MODEL, MODEL_KIMI_K2_6);
            if (m.equals(MODEL_DEEPSEEK_LEGACY) || m.equals(MODEL_DEEPSEEK_FLASH) || m.equals(MODEL_DEEPSEEK_V4_PRO)) {
                return MODEL_KIMI_K2_6;
            }
            return m;
        }

        // DeepSeek
        String m = prefs.getString(KEY_MODEL, MODEL_DEEPSEEK_FLASH);
        if (MODEL_DEEPSEEK_LEGACY.equals(m)) {
            // Migrazione automatica da legacy deepseek-chat a deepseek-flash
            setActiveModel(MODEL_DEEPSEEK_FLASH);
            return MODEL_DEEPSEEK_FLASH;
        }
        return m;
    }

    public void setActiveModel(String model) {
        prefs.edit().putString(KEY_MODEL, model).apply();
    }

    public String getApiKey(String provider) {
        String enc = PROVIDER_KIMI.equals(provider) ? prefs.getString(KEY_KIMI_KEY, "") : prefs.getString(KEY_DEEPSEEK_KEY, "");
        if (enc == null || enc.isEmpty()) return "";
        return KeystoreSecurityHelper.decrypt(enc);
    }

    public void setApiKey(String provider, String rawKey) {
        if (rawKey == null || rawKey.trim().isEmpty()) {
            if (PROVIDER_KIMI.equals(provider)) prefs.edit().remove(KEY_KIMI_KEY).apply();
            else prefs.edit().remove(KEY_DEEPSEEK_KEY).apply();
            return;
        }

        String enc = KeystoreSecurityHelper.encrypt(rawKey.trim());
        if (PROVIDER_KIMI.equals(provider)) {
            prefs.edit().putString(KEY_KIMI_KEY, enc).apply();
        } else {
            prefs.edit().putString(KEY_DEEPSEEK_KEY, enc).apply();
        }
    }

    public String getMaskedApiKey(String provider) {
        String k = getApiKey(provider);
        if (k == null || k.isEmpty()) return "";
        if (k.length() <= 8) return "••••••••";
        return k.substring(0, 4) + "••••••••" + k.substring(k.length() - 4);
    }

    // -------------------------------------------------------------
    // CONTATORE E REGOLE DI BUDGET (5 € MASSIMI CONDIVISI - TWO-PHASE)
    // -------------------------------------------------------------

    public double getTotalSpentEur() {
        return (double) prefs.getFloat(KEY_TOTAL_SPENT_EUR, 0.0f);
    }

    public void addSpentEur(double amountEur) {
        synchronized (BUDGET_LOCK) {
            float current = prefs.getFloat(KEY_TOTAL_SPENT_EUR, 0.0f);
            float updated = current + (float) amountEur;
            prefs.edit().putFloat(KEY_TOTAL_SPENT_EUR, updated).apply();
            Log.i(TAG, "Aggiornato contatore spesa AI condiviso: " + String.format(java.util.Locale.US, "%.4f", updated) + " € / 5.00 €");
        }
    }

    public static double getInFlightReservedEur() {
        synchronized (BUDGET_LOCK) {
            return Math.round(sInFlightReservedEur * 10000.0) / 10000.0;
        }
    }

    public double getRemainingBudgetEur() {
        synchronized (BUDGET_LOCK) {
            double rem = TOTAL_BUDGET_EUR - (getTotalSpentEur() + sInFlightReservedEur);
            return Math.max(0.0, Math.round(rem * 10000.0) / 10000.0);
        }
    }

    public int getWarningLevel() {
        double spent = getTotalSpentEur();
        if (spent >= TOTAL_BUDGET_EUR) return 3; // Blocco preventivo totale
        if (spent >= WARN_THRESHOLD_2_EUR) return 2; // Avviso 4 €
        if (spent >= WARN_THRESHOLD_1_EUR) return 1; // Avviso 3 €
        return 0; // Normale
    }

    public String getWarningMessage() {
        int lvl = getWarningLevel();
        double spent = Math.round(getTotalSpentEur() * 100.0) / 100.0;
        if (lvl == 3) {
            return "Budget massimo iniziale di 5,00 € esaurito (" + spent + " € spesi). Chiamate cloud bloccate preventivamente. L'assistente opera esclusivamente con procedure locali a 0 token.";
        } else if (lvl == 2) {
            return "Attenzione: Spesa AI condivisa a " + spent + " € su 5,00 € (soglia critica 4,00 € raggiunta).";
        } else if (lvl == 1) {
            return "Avviso budget: Spesa AI condivisa a " + spent + " € su 5,00 € (soglia 3,00 € raggiunta).";
        }
        return null;
    }

    public boolean isBudgetExceeded() {
        synchronized (BUDGET_LOCK) {
            return (getTotalSpentEur() + sInFlightReservedEur + 0.002) >= TOTAL_BUDGET_EUR;
        }
    }

    public JSONObject getBudgetSummary() {
        JSONObject b = new JSONObject();
        try {
            double spent = Math.round(getTotalSpentEur() * 10000.0) / 10000.0;
            double rem = getRemainingBudgetEur();
            b.put("total_limit_eur", TOTAL_BUDGET_EUR);
            b.put("total_spent_eur", spent);
            b.put("in_flight_reserved_eur", getInFlightReservedEur());
            b.put("remaining_eur", rem);
            b.put("warning_level", getWarningLevel());
            b.put("warning_message", getWarningMessage());
            b.put("no_auto_recharge", true);
            b.put("is_exceeded", isBudgetExceeded());
        } catch (Exception ignored) {}
        return b;
    }

    public void resetBudgetSpent() {
        synchronized (BUDGET_LOCK) {
            prefs.edit().putFloat(KEY_TOTAL_SPENT_EUR, 0.0f).apply();
            sInFlightReservedEur = 0.0;
            Log.i(TAG, "Contatore spesa AI condiviso azzerato dall'utente.");
        }
    }

    // -------------------------------------------------------------
    // TWO-PHASE BUDGET RESERVATION & COST ESTIMATION
    // -------------------------------------------------------------

    public static double estimateMaxCostEur(String provider, String model, int promptChars, int maxCompletionTokens) {
        int estPromptTokens = (promptChars / 3) + 120;
        int estCompTokens = maxCompletionTokens > 0 ? maxCompletionTokens : 800;

        double inPrice, outPrice;
        if (PROVIDER_KIMI.equals(provider)) {
            if (MODEL_KIMI_K2_6.equals(model)) {
                inPrice = 0.0000015;  // $1.50 per 1M tokens
                outPrice = 0.0000025; // $2.50 per 1M tokens
            } else if (MODEL_KIMI_32K.equals(model)) {
                inPrice = 0.0000024;
                outPrice = 0.0000024;
            } else {
                inPrice = 0.0000012;
                outPrice = 0.0000012;
            }
        } else {
            // DeepSeek
            if (MODEL_DEEPSEEK_V4_PRO.equals(model)) {
                inPrice = 0.00000027;  // $0.27 per 1M tokens
                outPrice = 0.00000110; // $1.10 per 1M tokens
            } else if (MODEL_DEEPSEEK_R1.equals(model)) {
                inPrice = 0.00000055;  // $0.55 per 1M tokens
                outPrice = 0.00000219; // $2.19 per 1M tokens
            } else {
                // deepseek-flash default
                inPrice = 0.00000014;  // $0.14 per 1M tokens
                outPrice = 0.00000028; // $0.28 per 1M tokens
            }
        }

        double costUsd = (estPromptTokens * inPrice) + (estCompTokens * outPrice);
        double costEur = costUsd * USD_TO_EUR * 1.20; // +20% margine di sicurezza
        return Math.max(0.0005, Math.round(costEur * 10000.0) / 10000.0);
    }

    public static double calculateActualCostEur(String provider, String model, int pTokens, int cTokens) {
        double inPrice, outPrice;
        if (PROVIDER_KIMI.equals(provider)) {
            if (MODEL_KIMI_K2_6.equals(model)) {
                inPrice = 0.0000015;
                outPrice = 0.0000025;
            } else if (MODEL_KIMI_32K.equals(model)) {
                inPrice = 0.0000024;
                outPrice = 0.0000024;
            } else {
                inPrice = 0.0000012;
                outPrice = 0.0000012;
            }
        } else {
            if (MODEL_DEEPSEEK_V4_PRO.equals(model)) {
                inPrice = 0.00000027;
                outPrice = 0.00000110;
            } else if (MODEL_DEEPSEEK_R1.equals(model)) {
                inPrice = 0.00000055;
                outPrice = 0.00000219;
            } else {
                inPrice = 0.00000014;
                outPrice = 0.00000028;
            }
        }

        double costUsd = (pTokens * inPrice) + (cTokens * outPrice);
        return Math.round((costUsd * USD_TO_EUR) * 100000.0) / 100000.0;
    }

    public boolean reserveBudget(double estimateEur) {
        synchronized (BUDGET_LOCK) {
            double currentSpent = getTotalSpentEur();
            if (currentSpent + sInFlightReservedEur + estimateEur > TOTAL_BUDGET_EUR) {
                Log.w(TAG, "PREVENTIVE BLOCK: Richiesti " + estimateEur + " € ma margine residuo è solo " 
                        + (TOTAL_BUDGET_EUR - (currentSpent + sInFlightReservedEur)) + " €");
                return false;
            }
            sInFlightReservedEur += estimateEur;
            Log.i(TAG, "BUDGET RESERVED: " + estimateEur + " € (In-flight: " + sInFlightReservedEur + " €)");
            return true;
        }
    }

    public void commitAndReleaseReservation(double reservedEur, double actualCostEur, boolean wasBilled) {
        synchronized (BUDGET_LOCK) {
            sInFlightReservedEur = Math.max(0.0, sInFlightReservedEur - reservedEur);
            if (wasBilled && actualCostEur > 0) {
                addSpentEur(actualCostEur);
            }
            Log.i(TAG, "BUDGET COMMITTED: reserved=" + reservedEur + " €, billed=" + actualCostEur 
                    + " € (Remaining in-flight: " + sInFlightReservedEur + " €)");
        }
    }

    public void releaseReservation(double reservedEur) {
        synchronized (BUDGET_LOCK) {
            sInFlightReservedEur = Math.max(0.0, sInFlightReservedEur - reservedEur);
            Log.i(TAG, "BUDGET RESERVATION RELEASED (0 cost): " + reservedEur + " €");
        }
    }

    public static JSONObject simulateBudgetCheck(double simulatedRemaining, double simulatedEstimate) {
        JSONObject sim = new JSONObject();
        try {
            boolean wouldPass = (simulatedRemaining >= simulatedEstimate);
            sim.put("simulated_remaining_eur", simulatedRemaining);
            sim.put("simulated_estimate_eur", simulatedEstimate);
            sim.put("approved", wouldPass);
            sim.put("reason", wouldPass 
                    ? "Prenotazione autorizzata (margine sufficiente: " + simulatedRemaining + " € >= " + simulatedEstimate + " €)"
                    : "BLOCCO PREVENTIVO ATTIVATO: Margine residuo (" + simulatedRemaining + " €) insufficiente per la stima massima (" + simulatedEstimate + " €)");
            sim.put("real_tokens_billed", 0);
            sim.put("real_cost_billed_eur", 0.0);
        } catch (Exception ignored) {}
        return sim;
    }

    // -------------------------------------------------------------
    // TEST DI CONNETTIVITÀ API
    // -------------------------------------------------------------

    public JSONObject testConnection(String provider, String apiKey, String model) {
        JSONObject res = new JSONObject();
        if (PROVIDER_LOCAL.equals(provider)) {
            try {
                res.put("success", true);
                res.put("message", "Modalità Solo Locale attiva (0 Token, nessuna chiamata cloud necessaria)");
            } catch (Exception ignored) {}
            return res;
        }

        if (apiKey == null || apiKey.trim().isEmpty()) {
            apiKey = getApiKey(provider);
        }

        if (apiKey == null || apiKey.trim().isEmpty()) {
            try {
                res.put("success", false);
                res.put("message", "Nessuna API Key configurata per " + provider);
            } catch (Exception ignored) {}
            return res;
        }

        String endpoint = PROVIDER_KIMI.equals(provider) ? ENDPOINT_KIMI : ENDPOINT_DEEPSEEK;
        String mod = (model != null && !model.isEmpty()) ? model : (PROVIDER_KIMI.equals(provider) ? MODEL_KIMI_K2_6 : MODEL_DEEPSEEK_FLASH);

        try {
            JSONArray messages = new JSONArray();
            messages.put(new JSONObject().put("role", "system").put("content", "Sei un tester. Rispondi solo 'PONG'."));
            messages.put(new JSONObject().put("role", "user").put("content", "PING"));

            JSONObject body = new JSONObject();
            body.put("model", mod);
            body.put("messages", messages);
            body.put("max_tokens", 8);
            body.put("temperature", 0.0);

            long start = System.currentTimeMillis();
            JSONObject apiRes = executeHttpRequest(endpoint, apiKey, body);
            long elapsed = System.currentTimeMillis() - start;

            if (apiRes.has("error")) {
                res.put("success", false);
                res.put("message", apiRes.getString("error"));
            } else {
                res.put("success", true);
                res.put("message", "Connessione riuscita con " + provider + " (" + mod + ") in " + elapsed + " ms!");
                res.put("latency_ms", elapsed);
            }
        } catch (Exception e) {
            try {
                res.put("success", false);
                res.put("message", "Errore HTTP: " + e.getMessage());
            } catch (Exception ignored) {}
        }
        return res;
    }

    // -------------------------------------------------------------
    // CHAT & PLANNING COMPLETION
    // -------------------------------------------------------------

    public AiResponse planActionSequence(String userGoal, String screenContext, JSONObject preferences) {
        return planActionSequence(userGoal, screenContext, preferences, null);
    }

    public AiResponse planActionSequence(String userGoal, String screenContext, JSONObject preferences, JSONArray conversationHistory) {
        String provider = getActiveProvider();
        if (PROVIDER_LOCAL.equals(provider)) {
            return AiResponse.failure("Modalità Solo Locale attiva.");
        }

        String model = getActiveModel();
        double maxEstCostEur = estimateMaxCostEur(provider, model, userGoal.length() + (screenContext != null ? screenContext.length() : 0), 800);

        if (!reserveBudget(maxEstCostEur)) {
            return AiResponse.failure("Budget massimo condiviso di 5,00 € esaurito o residuo insufficiente (Stima richiesta: " 
                + String.format(java.util.Locale.US, "%.4f", maxEstCostEur) + " €, Disponibile: " 
                + String.format(java.util.Locale.US, "%.4f", getRemainingBudgetEur()) + " €).");
        }

        String apiKey = getApiKey(provider);
        if (apiKey == null || apiKey.isEmpty()) {
            releaseReservation(maxEstCostEur);
            return AiResponse.failure("API Key mancante per " + provider + ". Inseriscila nelle impostazioni AI.");
        }

        String endpoint = PROVIDER_KIMI.equals(provider) ? ENDPOINT_KIMI : ENDPOINT_DEEPSEEK;
        boolean billed = false;

        try {
            String systemPrompt = buildPlanningPrompt(screenContext, preferences, conversationHistory);

            JSONArray messages = new JSONArray();
            messages.put(new JSONObject().put("role", "system").put("content", systemPrompt));
            messages.put(new JSONObject().put("role", "user").put("content", userGoal));

            JSONObject body = new JSONObject();
            body.put("model", model);
            body.put("messages", messages);
            body.put("temperature", 0.2);
            body.put("max_tokens", 800);

            JSONObject apiRes = executeHttpRequest(endpoint, apiKey, body);
            if (apiRes.has("error")) {
                releaseReservation(maxEstCostEur);
                return AiResponse.failure(apiRes.getString("error"));
            }

            int pTokens = 0, cTokens = 0, tTokens = 0;
            if (apiRes.has("usage")) {
                JSONObject usage = apiRes.getJSONObject("usage");
                pTokens = usage.optInt("prompt_tokens", 0);
                cTokens = usage.optInt("completion_tokens", 0);
                tTokens = usage.optInt("total_tokens", 0);
            }

            double actualCostEur = calculateActualCostEur(provider, model, pTokens, cTokens);
            billed = true;
            commitAndReleaseReservation(maxEstCostEur, actualCostEur, true);

            JSONArray choices = apiRes.optJSONArray("choices");
            if (choices == null || choices.length() == 0) {
                return AiResponse.failure("Risposta vuota dal provider AI");
            }

            String content = choices.getJSONObject(0).getJSONObject("message").getString("content");
            Log.d(TAG, "Raw LLM Response: " + content);

            return parseLlmOutput(content, userGoal, pTokens, cTokens, tTokens, actualCostEur);

        } catch (Exception e) {
            Log.e(TAG, "Error in planActionSequence: " + e.getMessage(), e);
            if (!billed) {
                releaseReservation(maxEstCostEur);
            }
            return AiResponse.failure("Eccezione durante chiamata AI: " + e.getMessage());
        }
    }

    private String buildPlanningPrompt(String screenContext, JSONObject preferences, JSONArray conversationHistory) {
        StringBuilder sb = new StringBuilder();
        sb.append("Sei AKAI JARVIS, l'assistente vocale intelligente integrato nella Smart TV AKAI AKTV5037N (Android 9 Pie, 4K).\n");
        sb.append("Comportati come un assistente vocale da salotto (simile ad Alexa su Fire TV): rispondi in modo naturale, conciso e calmo in italiano.\n");
        sb.append("La tua risposta nel campo 'reply' verrà letta ad alta voce dagli altoparlanti della televisione: non includere JSON, codice, numeri di token o tecnicismi interni nel testo di risposta.\n");
        sb.append("Se la richiesta dell'utente richiede un'azione sulla TV (aprire app, alzare volume, navigare), fornisci la sequenza di azioni.\n");
        sb.append("Se la richiesta è una domanda conversazionale, una battuta o un consiglio (es. 'cosa mi consigli di guardare stasera?'), genera actions vuoto [] e una risposta parlata piacevole e pertinente.\n\n");

        if (conversationHistory != null && conversationHistory.length() > 0) {
            sb.append("--- CRONOLOGIA CONVERSAZIONE RECENTE (CONTESTO MULTI-TURN) ---\n");
            for (int i = 0; i < conversationHistory.length(); i++) {
                try {
                    JSONObject turn = conversationHistory.getJSONObject(i);
                    String uq = turn.optString("user_query", "");
                    String ar = turn.optString("assistant_reply", "");
                    if (!uq.isEmpty()) {
                        sb.append("Utente: ").append(uq).append("\n");
                        sb.append("JARVIS: ").append(ar).append("\n");
                    }
                } catch (Exception ignored) {}
            }
            sb.append("\n");
        }

        sb.append("--- STATO ATTUALE DELLO SCHERMO ---\n");
        sb.append(screenContext != null ? screenContext : "Schermata non accessibile").append("\n\n");

        if (preferences != null && preferences.length() > 0) {
            sb.append("--- PREFERENZE PERSONALI UTENTE ---\n");
            sb.append(preferences.toString()).append("\n\n");
        }

        sb.append("--- WHITELIST AZIONI SUPPORTATE ---\n");
        sb.append("open_app: {\"type\":\"open_app\", \"pkg\":\"nome_package\", \"name\":\"Nome App\"}\n");
        sb.append("press_key: {\"type\":\"press_key\", \"action\":\"dpad_up|dpad_down|dpad_left|dpad_right|dpad_center|back|home\"}\n");
        sb.append("click_accessibility_node: {\"type\":\"click_accessibility_node\", \"text\":\"Testo del nodo\"}\n");
        sb.append("set_volume: {\"type\":\"set_volume\", \"level\": 15}\n");
        sb.append("select_channel: {\"type\":\"select_channel\", \"number\": 5}\n");
        sb.append("wait: {\"type\":\"wait\", \"ms\": 1500}\n\n");

        sb.append("--- SCHEMA JSON OBBLIGATORIO ---\n");
        sb.append("{\n");
        sb.append("  \"reply\": \"Messaggio sintetico per l'utente in italiano\",\n");
        sb.append("  \"intent_key\": \"chiave_univoca_procedura (es. impostazioni_audio, meteo)\",\n");
        sb.append("  \"learn_procedure\": true,\n");
        sb.append("  \"success_condition\": {\"type\":\"player_active|contains_text|pkg_is\", \"pkg\":\"...\", \"value\":\"...\"},\n");
        sb.append("  \"actions\": [ ... ]\n");
        sb.append("}\n");

        return sb.toString();
    }

    private AiResponse parseLlmOutput(String raw, String userGoal, int pTokens, int cTokens, int tTokens, double costEur) {
        try {
            String jsonStr = raw.trim();
            if (jsonStr.startsWith("```json")) jsonStr = jsonStr.substring(7);
            else if (jsonStr.startsWith("```")) jsonStr = jsonStr.substring(3);
            if (jsonStr.endsWith("```")) jsonStr = jsonStr.substring(0, jsonStr.length() - 3);
            jsonStr = jsonStr.trim();

            int firstBrace = jsonStr.indexOf("{");
            int lastBrace = jsonStr.lastIndexOf("}");
            if (firstBrace >= 0 && lastBrace > firstBrace) {
                jsonStr = jsonStr.substring(firstBrace, lastBrace + 1);
                JSONObject obj = new JSONObject(jsonStr);
                String reply = obj.optString("reply", "Comando recepito.");
                JSONArray actions = obj.optJSONArray("actions");
                String intentKey = obj.optString("intent_key", null);
                boolean learn = obj.optBoolean("learn_procedure", false);
                JSONObject condObj = obj.optJSONObject("success_condition");
                String conditionStr = condObj != null ? condObj.toString() : null;

                return new AiResponse(true, reply, actions, intentKey, userGoal, conditionStr, learn, pTokens, cTokens, tTokens, costEur, getWarningMessage(), null);
            }
        } catch (Exception e) {
            Log.w(TAG, "Failed parsing JSON, fallback to plain reply: " + e.getMessage());
        }

        return new AiResponse(true, raw, new JSONArray(), null, userGoal, null, false, pTokens, cTokens, tTokens, costEur, getWarningMessage(), null);
    }

    private JSONObject executeHttpRequest(String endpointUrl, String apiKey, JSONObject bodyJson) throws Exception {
        URL url = new URL(endpointUrl);
        HttpURLConnection conn = (HttpURLConnection) url.openConnection();
        conn.setRequestMethod("POST");
        conn.setRequestProperty("Content-Type", "application/json; charset=utf-8");
        conn.setRequestProperty("Authorization", "Bearer " + apiKey);
        conn.setRequestProperty("Accept", "application/json");
        conn.setConnectTimeout(15000);
        conn.setReadTimeout(30000);
        conn.setDoOutput(true);

        byte[] outputBytes = bodyJson.toString().getBytes(StandardCharsets.UTF_8);
        try (OutputStream os = conn.getOutputStream()) {
            os.write(outputBytes);
            os.flush();
        }

        int statusCode = conn.getResponseCode();
        InputStream is = (statusCode >= 200 && statusCode < 300) ? conn.getInputStream() : conn.getErrorStream();

        BufferedReader reader = new BufferedReader(new InputStreamReader(is, StandardCharsets.UTF_8));
        StringBuilder sb = new StringBuilder();
        String line;
        while ((line = reader.readLine()) != null) sb.append(line);
        reader.close();

        String resStr = sb.toString();
        if (statusCode == 401) {
            JSONObject err = new JSONObject();
            err.put("error", "Autenticazione fallita (HTTP 401): API Key non valida o revocata.");
            return err;
        } else if (statusCode == 429) {
            JSONObject err = new JSONObject();
            err.put("error", "Rate limit superato (HTTP 429): troppe richieste al provider. Riprova tra poco.");
            return err;
        } else if (statusCode == 402) {
            JSONObject err = new JSONObject();
            err.put("error", "Credito insufficiente (HTTP 402): saldo account esaurito sul provider.");
            return err;
        } else if (statusCode < 200 || statusCode >= 300) {
            JSONObject err = new JSONObject();
            err.put("error", "Errore HTTP " + statusCode + ": " + resStr);
            return err;
        }

        return new JSONObject(resStr);
    }
}
