package it.akai.customremote.ai;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.Locale;
import java.util.concurrent.atomic.AtomicBoolean;

import it.akai.customremote.TvController;

/**
 * AkaiAiController: Orchestratore Cognitivo Autonomo su Smart TV AKAI (v2).
 *
 * Implementa il ciclo closed-loop:
 * 1. Percezione -> 2. Memory Lookup -> 3. Fast-Path (0 Token)
 * 4. Autonomous Discovery & Planning (CLOUD_OPTIONAL DeepSeek/Kimi o Local UI Graph Planner / LOCAL_ONLY)
 * 5. Stepwise Execution + Bounded UI Wait -> 6. State Reflector & 1 Replanning -> 7. Persistenza SQLite SOLO se STATE_VERIFIED.
 */
public class AkaiAiController {
    private static final String TAG = "AKAI_AiController";
    private static AkaiAiController sInstance = null;

    public static final String MODE_CLOUD_OPTIONAL = "CLOUD_OPTIONAL";
    public static final String MODE_LOCAL_ONLY = "LOCAL_ONLY";
    public static final String OUTCOME_STATE_VERIFIED = "STATE_VERIFIED";
    public static final String OUTCOME_COMMAND_SENT = "COMMAND_SENT";
    public static final String OUTCOME_FAILED = "FAILED";
    public static final String OUTCOME_NOT_TESTED = "NOT_TESTED";

    private static final String PREFS_NAME = "akai_ai_secure_prefs";
    private static final String PREF_EXECUTION_MODE = "execution_mode";

    // Modalita configurabile: CLOUD_OPTIONAL (default, false) vs LOCAL_ONLY (true)
    private static volatile boolean sStrictLocalOnly = false;
    private static volatile long sDefaultPollIntervalMs = 150L;

    public static boolean isStrictLocalOnly() {
        return sStrictLocalOnly;
    }

    public static void setStrictLocalOnly(boolean strictLocalOnly) {
        sStrictLocalOnly = strictLocalOnly;
    }

    public static String getExecutionMode() {
        return sStrictLocalOnly ? MODE_LOCAL_ONLY : MODE_CLOUD_OPTIONAL;
    }

    public static void setExecutionMode(String mode) {
        String clean = mode != null ? mode.trim().toUpperCase(Locale.US) : "";
        if (MODE_LOCAL_ONLY.equals(clean)) {
            sStrictLocalOnly = true;
        } else if (MODE_CLOUD_OPTIONAL.equals(clean)) {
            sStrictLocalOnly = false;
        } else {
            throw new IllegalArgumentException("Modalita esecuzione non valida: " + mode);
        }
    }

    public static void persistExecutionMode(Context context, String mode) {
        setExecutionMode(mode);
        if (context != null) {
            try {
                SharedPreferences sp = context.getApplicationContext().getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
                sp.edit().putString(PREF_EXECUTION_MODE, getExecutionMode()).apply();
            } catch (Exception ignored) {}
        }
    }

    public static void setDefaultPollIntervalMsForTest(long pollMs) {
        sDefaultPollIntervalMs = Math.max(0L, pollMs);
    }

    public static org.json.JSONArray getSupportedCatalog() {
        return LocalIntentParser.getSupportedCatalog();
    }

    /**
     * Bridge iniettabile per percezione schermo, esecuzione comandi e attese limitate (produzione TV o test JVM).
     */
    public interface PerceptionAndExecutionBridge {
        ScreenPerceptionEngine.PerceptionSnapshot capture(Context ctx);
        TvController.CommandResult executeActions(JSONArray actions);
        void sleepMs(long ms);
    }

    private final Context context;
    private final TvController tvController;
    private final AkaiMemoryEngine memoryEngine;
    private final AiProviderAdapter aiAdapter;
    private final PerceptionAndExecutionBridge bridge;
    private final AtomicBoolean cancelRequested = new AtomicBoolean(false);

    public static synchronized AkaiAiController getInstance(Context context, TvController tvController) {
        if (sInstance == null) {
            sInstance = new AkaiAiController(context.getApplicationContext(), tvController);
        }
        return sInstance;
    }

    public static AkaiAiController createForTest(Context context,
                                                 TvController tvController,
                                                 AkaiMemoryEngine memoryEngine,
                                                 AiProviderAdapter aiAdapter,
                                                 PerceptionAndExecutionBridge bridge) {
        return new AkaiAiController(context, tvController, memoryEngine, aiAdapter, bridge);
    }

    private AkaiAiController(Context context, TvController tvController) {
        this(context, tvController, AkaiMemoryEngine.getInstance(context), new AiProviderAdapter(context), null);
    }

    private AkaiAiController(Context context,
                             TvController tvController,
                             AkaiMemoryEngine memoryEngine,
                             AiProviderAdapter aiAdapter,
                             PerceptionAndExecutionBridge customBridge) {
        this.context = context != null ? context.getApplicationContext() : null;
        this.tvController = tvController;
        this.memoryEngine = memoryEngine;
        this.aiAdapter = aiAdapter;
        this.bridge = customBridge != null ? customBridge : new PerceptionAndExecutionBridge() {
            @Override
            public ScreenPerceptionEngine.PerceptionSnapshot capture(Context ctx) {
                return ScreenPerceptionEngine.capture(ctx);
            }

            @Override
            public TvController.CommandResult executeActions(JSONArray actions) {
                return tvController != null
                        ? tvController.executeActionSequence(actions)
                        : new TvController.CommandResult(false, "TvController non inizializzato");
            }

            @Override
            public void sleepMs(long ms) {
                if (ms > 0) {
                    try { Thread.sleep(ms); } catch (InterruptedException ignored) {}
                }
            }
        };

        if (this.context != null && customBridge == null) {
            try {
                SharedPreferences sp = this.context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
                String savedMode = sp.getString(PREF_EXECUTION_MODE, null);
                if (MODE_LOCAL_ONLY.equalsIgnoreCase(savedMode)) {
                    sStrictLocalOnly = true;
                } else if (MODE_CLOUD_OPTIONAL.equalsIgnoreCase(savedMode)) {
                    sStrictLocalOnly = false;
                }
            } catch (Exception ignored) {}
        }
    }

    public void cancelCurrentTask() {
        cancelRequested.set(true);
    }

    public boolean isCancelRequested() {
        return cancelRequested.get();
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

    private static class WaitObservation {
        final ScreenPerceptionEngine.PerceptionSnapshot snapshot;
        final boolean verified;
        final long elapsedMs;
        final int snapshotCount;

        WaitObservation(ScreenPerceptionEngine.PerceptionSnapshot snapshot, boolean verified, long elapsedMs, int snapshotCount) {
            this.snapshot = snapshot;
            this.verified = verified;
            this.elapsedMs = elapsedMs;
            this.snapshotCount = snapshotCount;
        }
    }

    private WaitObservation waitForConditionOrUiChange(String successCondition, long maxWaitMs, long pollIntervalMs) {
        long waited = 0L;
        int snaps = 0;
        boolean hasCondition = successCondition != null && !successCondition.trim().isEmpty();

        ScreenPerceptionEngine.PerceptionSnapshot snap = bridge.capture(context);
        snaps++;
        boolean verified = hasCondition && ScreenPerceptionEngine.evaluateSuccessCondition(snap, successCondition);

        while (hasCondition && !verified && waited < maxWaitMs && !cancelRequested.get()) {
            long step = pollIntervalMs > 0 ? Math.min(pollIntervalMs, maxWaitMs - waited) : Math.min(50L, maxWaitMs - waited);
            if (step <= 0L) break;
            if (pollIntervalMs > 0) {
                bridge.sleepMs(step);
            }
            waited += step;
            snap = bridge.capture(context);
            snaps++;
            verified = ScreenPerceptionEngine.evaluateSuccessCondition(snap, successCondition);
        }
        return new WaitObservation(snap, verified, waited, snaps);
    }

    private long waitForHomePackage(long maxWaitMs, long pollIntervalMs) {
        long waited = 0L;
        while (waited < maxWaitMs && !cancelRequested.get()) {
            ScreenPerceptionEngine.PerceptionSnapshot snap = bridge.capture(context);
            if (snap != null && ("it.akai.customhome.v8".equals(snap.foregroundPackage) || "it.akai.customhome".equals(snap.foregroundPackage))) {
                return waited;
            }
            long step = pollIntervalMs > 0 ? Math.min(pollIntervalMs, maxWaitMs - waited) : maxWaitMs - waited;
            if (step <= 0L) break;
            if (pollIntervalMs > 0) {
                bridge.sleepMs(step);
            }
            waited += step;
        }
        return waited;
    }

    private TvController.CommandResult executeActionsStepwise(JSONArray actions) {
        if (actions == null || actions.length() == 0) {
            return new TvController.CommandResult(false, "Nessuna azione da eseguire");
        }
        if (actions.length() == 1) {
            if (cancelRequested.get()) {
                return new TvController.CommandResult(false, "Operazione annullata dall'utente");
            }
            return bridge.executeActions(actions);
        }
        int executed = 0;
        for (int i = 0; i < actions.length(); i++) {
            if (cancelRequested.get()) {
                return new TvController.CommandResult(false, "Operazione annullata dall'utente allo step " + (i + 1));
            }
            JSONObject step = actions.optJSONObject(i);
            if (step == null) {
                return new TvController.CommandResult(false, "Step non valido all'indice " + i);
            }
            JSONArray single = new JSONArray();
            single.put(step);
            TvController.CommandResult stepRes = bridge.executeActions(single);
            executed++;
            if (stepRes == null || !stepRes.success) {
                String msg = stepRes != null ? stepRes.message : "Errore esecuzione step " + (i + 1);
                return new TvController.CommandResult(false, msg);
            }
        }
        return new TvController.CommandResult(true, "Sequenza stepwise eseguita con successo (" + executed + " passi)");
    }

    private String buildReflectorContext(ScreenPerceptionEngine.PerceptionSnapshot postSnap,
                                        JSONArray previousActions,
                                        TvController.CommandResult previousExec) {
        try {
            JSONObject wrapper = new JSONObject();
            wrapper.put("replan_attempt", 1);
            wrapper.put("previous_execution_success", previousExec != null && previousExec.success);
            wrapper.put("previous_error", previousExec != null && previousExec.message != null ? previousExec.message : "");
            wrapper.put("failed_actions", previousActions != null ? previousActions : new JSONArray());
            if (postSnap != null) {
                wrapper.put("post_screen", new JSONObject(postSnap.toRedactedMinimalContextPrompt()));
            }
            return wrapper.toString();
        } catch (Exception e) {
            return postSnap != null ? postSnap.toRedactedMinimalContextPrompt() : "{\"replan_attempt\":1}";
        }
    }

    public JSONObject processQuery(String userQuery, boolean speak) {
        long startTime = System.currentTimeMillis();
        cancelRequested.set(false);
        JSONObject result = new JSONObject();

        if (userQuery == null || userQuery.trim().isEmpty()) {
            String emptyReply = "Nessuna richiesta ricevuta. Dì ad esempio: 'Metti Italia 2' o 'Imposta il volume a 20'.";
            return completeAndSpeak(result, "", emptyReply, "ERROR", null, 0, 0.0, speak, startTime);
        }

        String query = userQuery.trim();
        Log.i(TAG, "Processing request: \"" + query + "\" (speak=" + speak + ", mode=" + getExecutionMode() + ")");

        // ---------------------------------------------------------------------
        // PASSO 1: VERIFICA PROCEDURA IN MEMORIA SQLITE (O COMANDO HARDWARE)
        // ---------------------------------------------------------------------
        LocalIntentParser.ParsedIntent parsed = LocalIntentParser.parse(context, query);

        if (parsed.matched) {
            Log.i(TAG, "Fast-Path/SQLite match: " + parsed.intentKey + " (" + parsed.source + ")");
            int snapshotCount = 0;
            long waitElapsedMs = 0L;

            // Verifica coerenza dello stato iniziale prima dell'esecuzione
            ScreenPerceptionEngine.PerceptionSnapshot preSnap = bridge.capture(context);
            snapshotCount++;
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
                            JSONArray homeSeq = new JSONArray();
                            homeSeq.put(new JSONObject().put("type", "press_key").put("key", "home"));
                            bridge.executeActions(homeSeq);
                            waitElapsedMs += waitForHomePackage(800L, sDefaultPollIntervalMs);
                        }
                    }
                } catch (Exception ignored) {}
            }

            TvController.CommandResult cmdRes = executeActionsStepwise(parsed.actions);
            boolean hasCondition = parsed.successCondition != null && !parsed.successCondition.trim().isEmpty();

            WaitObservation obs = waitForConditionOrUiChange(hasCondition ? parsed.successCondition : null, 1200L, sDefaultPollIntervalMs);
            snapshotCount += obs.snapshotCount;
            waitElapsedMs += obs.elapsedMs;
            boolean verified = hasCondition ? obs.verified : cmdRes.success;

            if (parsed.intentKey != null) {
                if (verified && cmdRes.success) {
                    memoryEngine.recordProcedureSuccess(parsed.intentKey);
                } else {
                    Log.w(TAG, "Verification failed for procedure: " + parsed.intentKey);
                    memoryEngine.recordProcedureFailure(parsed.intentKey);
                }
            }

            String executionOutcome = !cmdRes.success ? OUTCOME_FAILED : (verified ? OUTCOME_STATE_VERIFIED : OUTCOME_COMMAND_SENT);
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
                result.put("execution_outcome", executionOutcome);
                result.put("replan_count", 0);
                result.put("cloud_calls", 0);
                result.put("snapshot_count", snapshotCount);
                result.put("wait_elapsed_ms", waitElapsedMs);
                result.put("execution_mode", getExecutionMode());
                result.put("strict_local_only", isStrictLocalOnly());
                result.put("budget_is_client_estimate", true);
                result.put("actions_count", parsed.actions != null ? parsed.actions.length() : 0);
            } catch (Exception ignored) {}

            return completeAndSpeak(result, query, replyMsg, status, parsed.intentKey, 0, 0.0, speak, startTime);
        }

        // ---------------------------------------------------------------------
        // PASSO 2: PROCEDURA NON NOTA -> APPRENDIMENTO ED ESPLORAZIONE AUTONOMA
        // ---------------------------------------------------------------------
        Log.i(TAG, "No procedure found in SQLite. Initiating autonomous discovery for: \"" + query + "\"");
        int snapshotCount = 0;
        long totalWaitElapsedMs = 0L;
        int cloudCalls = 0;
        int replanCount = 0;
        boolean replanRejectedDuplicate = false;

        ScreenPerceptionEngine.PerceptionSnapshot initialSnap = bridge.capture(context);
        snapshotCount++;

        // Livello 4: Protezione Privacy & Sicurezza (zero chiamate HTTP se campi sensibili)
        if (initialSnap.hasSensitiveFields) {
            Log.w(TAG, "Screen contains sensitive/password fields. Aborting AI processing for security.");
            JSONObject secRes = new JSONObject();
            try {
                secRes.put("success", false);
                secRes.put("status", "PRIVACY_BLOCKED");
                secRes.put("execution_outcome", OUTCOME_NOT_TESTED);
                secRes.put("privacy_blocked", true);
                secRes.put("verified", false);
                secRes.put("cloud_calls", 0);
                secRes.put("snapshot_count", snapshotCount);
                secRes.put("reply", "Operazione sospesa per sicurezza: rilevato campo sensibile o password sullo schermo.");
                secRes.put("source", "security_guard");
                secRes.put("tokens", 0);
                secRes.put("cost_usd", 0);
                secRes.put("cost_eur", 0.0);
                secRes.put("execution_mode", getExecutionMode());
                secRes.put("strict_local_only", isStrictLocalOnly());
            } catch (JSONException ignored) {}
            return secRes;
        }

        String provider = aiAdapter.getActiveProvider();
        String apiKey = AiProviderAdapter.PROVIDER_LOCAL.equals(provider) ? "" : aiAdapter.getApiKey(provider);
        boolean hasConsent = aiAdapter.hasCloudContextConsent();

        JSONArray candidateActions = null;
        String candidateKey = null;
        String candidateCondition = null;
        int promptTokens = 0, compTokens = 0, totalTokens = 0;
        double costEur = 0.0;
        String planReply = null;
        String planWarning = null;
        boolean usedCloudPlanner = false;

        if (isStrictLocalOnly()) {
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
                    result.put("execution_outcome", OUTCOME_FAILED);
                    result.put("reply", "Comando non supportato in modalita locale esclusiva (PC spento). Comandi disponibili: volume, canali DTV, ingressi HDMI, navigazione Home/Indietro, avvio app.");
                    result.put("source", "strict_local_guard");
                    result.put("tokens", 0);
                    result.put("cost_eur", 0.0);
                    result.put("latency_ms", elapsed);
                    result.put("verified", false);
                    result.put("cloud_calls", 0);
                    result.put("snapshot_count", snapshotCount);
                    result.put("execution_mode", MODE_LOCAL_ONLY);
                    result.put("strict_local_only", true);
                } catch (Exception ignored) {}
                return completeAndSpeak(result, query, "Comando non supportato in modalita locale esclusiva.", "FAIL_CLOSED_UNSUPPORTED", null, 0, 0.0, speak, startTime);
            }
        } else if (!AiProviderAdapter.PROVIDER_LOCAL.equals(provider) && !apiKey.isEmpty() && hasConsent) {
            if (aiAdapter.isBudgetExceeded()) {
                long elapsed = System.currentTimeMillis() - startTime;
                try {
                    result.put("success", false);
                    result.put("status", "BUDGET_EXCEEDED");
                    result.put("execution_outcome", OUTCOME_FAILED);
                    result.put("reply", "Budget massimo iniziale di 5,00 € esaurito o residuo insufficiente. Richieste cloud bloccate preventivamente.");
                    result.put("source", "budget_guard");
                    result.put("tokens", 0);
                    result.put("cost_eur", 0.0);
                    result.put("latency_ms", elapsed);
                    result.put("verified", false);
                    result.put("cloud_calls", 0);
                    result.put("snapshot_count", snapshotCount);
                    result.put("execution_mode", getExecutionMode());
                    result.put("strict_local_only", false);
                    result.put("budget_is_client_estimate", true);
                } catch (Exception ignored) {}
                return result;
            }

            JSONObject prefs = memoryEngine.getAllPreferences();
            JSONArray convHistory = memoryEngine.getRecentConversations(3);
            String redactedContextPrompt = initialSnap.toRedactedMinimalContextPrompt();
            AiProviderAdapter.AiResponse planRes = aiAdapter.planActionSequence(query, redactedContextPrompt, prefs, convHistory);
            cloudCalls++;

            if (planRes.success) {
                usedCloudPlanner = true;
                promptTokens = planRes.promptTokens;
                compTokens = planRes.completionTokens;
                totalTokens = planRes.totalTokens;
                costEur = planRes.costEur;
                planReply = planRes.reply;
                planWarning = planRes.warningMessage;

                // Caso A: Domanda puramente conversazionale -> 0 azioni hardware richieste
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
                        result.put("verified", false);
                        result.put("execution_outcome", OUTCOME_NOT_TESTED);
                        result.put("cloud_calls", cloudCalls);
                        result.put("snapshot_count", snapshotCount);
                        result.put("execution_mode", getExecutionMode());
                        result.put("strict_local_only", false);
                        result.put("budget_is_client_estimate", true);
                        result.put("actions_count", 0);
                    } catch (Exception ignored) {}

                    return completeAndSpeak(result, query, planReply, "ANSWERED_DIALOG", "dialog", totalTokens, costEur, speak, startTime);
                }

                // Caso B: Richiesta operativa TV con sequenza azioni validata
                candidateActions = planRes.actions;
                candidateKey = planRes.intentKey;
                candidateCondition = planRes.successCondition;
            } else {
                long elapsed = System.currentTimeMillis() - startTime;
                boolean budgetErr = planRes.error != null && planRes.error.contains("Budget");
                boolean validationErr = planRes.error != null && (planRes.error.contains("SCHEMA") || planRes.error.contains("POLICY"));
                try {
                    result.put("success", false);
                    result.put("status", budgetErr ? "BUDGET_EXCEEDED" : (validationErr ? "VALIDATION_BLOCKED" : "CLOUD_ERROR"));
                    result.put("execution_outcome", OUTCOME_FAILED);
                    result.put("validation_blocked", validationErr);
                    result.put("error", planRes.error);
                    result.put("reply", planRes.error != null ? planRes.error : "Risposta AI non valida o errore di rete.");
                    result.put("source", budgetErr ? "budget_guard" : provider);
                    result.put("tokens", planRes.totalTokens);
                    result.put("cost_eur", planRes.costEur);
                    result.put("latency_ms", elapsed);
                    result.put("verified", false);
                    result.put("learned_new_procedure", false);
                    result.put("cloud_calls", cloudCalls);
                    result.put("snapshot_count", snapshotCount);
                    result.put("execution_mode", getExecutionMode());
                    result.put("strict_local_only", false);
                    result.put("budget_is_client_estimate", true);
                } catch (Exception ignored) {}
                return result;
            }
        }

        // Fallback su Local UI Graph Planner se cloud non configurato o consenso assente
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
                result.put("execution_outcome", OUTCOME_FAILED);
                result.put("reply", "Impossibile trovare un percorso per '" + query + "'. " +
                        "Assicurati che la schermata iniziale sia corretta o configura una chiave DeepSeek/Kimi per l'esplorazione autonoma.");
                result.put("source", "planner_failed");
                result.put("tokens", 0);
                result.put("latency_ms", elapsed);
                result.put("verified", false);
                result.put("cloud_calls", cloudCalls);
                result.put("snapshot_count", snapshotCount);
                result.put("execution_mode", getExecutionMode());
                result.put("strict_local_only", isStrictLocalOnly());
            } catch (Exception ignored) {}
            return result;
        }

        // ---------------------------------------------------------------------
        // PASSO 3: ESECUZIONE STEPWISE, BOUNDED WAIT, REFLECTOR & MAX 1 REPLAN
        // ---------------------------------------------------------------------
        Log.i(TAG, "Executing planned actions (" + candidateActions.length() + " steps)...");
        TvController.CommandResult execRes = executeActionsStepwise(candidateActions);

        WaitObservation firstObs = waitForConditionOrUiChange(candidateCondition, 1500L, sDefaultPollIntervalMs);
        ScreenPerceptionEngine.PerceptionSnapshot postSnap = firstObs.snapshot;
        boolean verified = firstObs.verified;
        snapshotCount += firstObs.snapshotCount;
        totalWaitElapsedMs += firstObs.elapsedMs;

        Log.i(TAG, "Discovery verification attempt 1: " + verified + " (execSuccess=" + execRes.success + ", postPkg=" + (postSnap != null ? postSnap.foregroundPackage : "") + ")");

        // Reflector & singolo replanning non ripetitivo se fallito o non verificato
        if (usedCloudPlanner && !cancelRequested.get() && (!execRes.success || !verified) && !aiAdapter.isBudgetExceeded()) {
            String reflectorContext = buildReflectorContext(postSnap, candidateActions, execRes);
            JSONObject prefs = memoryEngine.getAllPreferences();
            JSONArray convHistory = memoryEngine.getRecentConversations(3);
            AiProviderAdapter.AiResponse retryRes = aiAdapter.planActionSequence(
                    query + " [RETRY_DIFFERENT_PLAN]", reflectorContext, prefs, convHistory);
            cloudCalls++;
            promptTokens += retryRes.promptTokens;
            compTokens += retryRes.completionTokens;
            totalTokens += retryRes.totalTokens;
            costEur += retryRes.costEur;
            if (retryRes.warningMessage != null) planWarning = retryRes.warningMessage;

            if (retryRes.success && retryRes.actions != null && retryRes.actions.length() > 0) {
                String firstSerialized = candidateActions.toString();
                String retrySerialized = retryRes.actions.toString();
                if (firstSerialized.equals(retrySerialized)) {
                    Log.w(TAG, "Replan rejected: identical action sequence returned by LLM.");
                    replanRejectedDuplicate = true;
                } else {
                    replanCount = 1;
                    candidateActions = retryRes.actions;
                    candidateCondition = retryRes.successCondition;
                    if (retryRes.intentKey != null && !retryRes.intentKey.isEmpty()) {
                        candidateKey = retryRes.intentKey;
                    }
                    if (retryRes.reply != null && !retryRes.reply.isEmpty()) {
                        planReply = retryRes.reply;
                    }
                    execRes = executeActionsStepwise(candidateActions);
                    WaitObservation retryObs = waitForConditionOrUiChange(candidateCondition, 1500L, sDefaultPollIntervalMs);
                    postSnap = retryObs.snapshot;
                    verified = retryObs.verified;
                    snapshotCount += retryObs.snapshotCount;
                    totalWaitElapsedMs += retryObs.elapsedMs;
                    Log.i(TAG, "Discovery verification attempt 2 (replan): " + verified + " (execSuccess=" + execRes.success + ")");
                }
            }
        }

        if (cancelRequested.get()) {
            try {
                result.put("success", false);
                result.put("source", usedCloudPlanner ? provider : "local_autonomous_planner");
                result.put("execution_outcome", OUTCOME_FAILED);
                result.put("verified", false);
                result.put("learned_new_procedure", false);
                result.put("replan_count", replanCount);
                result.put("cloud_calls", cloudCalls);
                result.put("snapshot_count", snapshotCount);
                result.put("wait_elapsed_ms", totalWaitElapsedMs);
                result.put("tokens", totalTokens);
                result.put("cost_eur", costEur);
                result.put("execution_mode", getExecutionMode());
                result.put("strict_local_only", isStrictLocalOnly());
            } catch (Exception ignored) {}
            return completeAndSpeak(result, query, "Operazione annullata su richiesta.", "CANCELLED", candidateKey, totalTokens, costEur, speak, startTime);
        }

        // Distinzione categorica tra COMMAND_SENT e STATE_VERIFIED
        String executionOutcome = !execRes.success ? OUTCOME_FAILED : (verified ? OUTCOME_STATE_VERIFIED : OUTCOME_COMMAND_SENT);

        // ---------------------------------------------------------------------
        // PASSO 4: SALVATAGGIO IN MEMORIA PROCEDURALE SQLITE (SOLO STATE_VERIFIED)
        // ---------------------------------------------------------------------
        boolean newlyLearned = false;
        if (OUTCOME_STATE_VERIFIED.equals(executionOutcome)) {
            if (candidateKey == null || candidateKey.trim().isEmpty()) candidateKey = generateIntentKey(query);
            String initialState = "{\"pkg\":\"" + (initialSnap != null ? initialSnap.foregroundPackage : "") + "\"}";

            newlyLearned = memoryEngine.saveVerifiedProcedure(
                    candidateKey,
                    query.toLowerCase(Locale.ITALIAN),
                    query,
                    postSnap != null ? postSnap.foregroundPackage : "",
                    initialState,
                    candidateActions,
                    candidateCondition,
                    "1.0"
            );
            Log.i(TAG, "SUCCESS! New verified procedure saved to SQLite: " + candidateKey);
        }

        // Aggiornamento statistiche d'uso
        if (cloudCalls > 0) {
            memoryEngine.incrementStat("cloud_ai_calls", cloudCalls);
            memoryEngine.incrementStat("prompt_tokens", promptTokens);
            memoryEngine.incrementStat("completion_tokens", compTokens);
        } else {
            memoryEngine.incrementStat("local_executions_zero_token", 1);
        }

        String status = OUTCOME_STATE_VERIFIED.equals(executionOutcome)
                ? "SUCCESS_VERIFIED"
                : (OUTCOME_COMMAND_SENT.equals(executionOutcome) ? "COMPLETED_UNVERIFIED" : "ERROR");
        String finalReply = planReply != null ? planReply : "Procedura completata.";
        if (!execRes.success) {
            finalReply = "Non sono riuscito a completare l'operazione: " + execRes.message;
        } else if (!verified && candidateCondition != null) {
            finalReply = "Azioni inviate, ma il risultato non è stato verificato con certezza sullo schermo.";
        }

        try {
            result.put("success", OUTCOME_STATE_VERIFIED.equals(executionOutcome));
            result.put("source", cloudCalls > 0 ? provider : "local_autonomous_planner");
            result.put("learned_new_procedure", newlyLearned);
            result.put("intent_key", candidateKey);
            result.put("actions_count", candidateActions.length());
            result.put("tokens", totalTokens);
            result.put("cost_eur", costEur);
            result.put("budget_spent_eur", aiAdapter.getTotalSpentEur());
            result.put("budget_remaining_eur", aiAdapter.getRemainingBudgetEur());
            result.put("budget_is_client_estimate", true);
            if (planWarning != null) {
                result.put("budget_warning", planWarning);
            }
            result.put("verified", verified);
            result.put("execution_outcome", executionOutcome);
            result.put("replan_count", replanCount);
            result.put("replan_rejected_duplicate", replanRejectedDuplicate);
            result.put("cloud_calls", cloudCalls);
            result.put("snapshot_count", snapshotCount);
            result.put("wait_elapsed_ms", totalWaitElapsedMs);
            result.put("execution_mode", getExecutionMode());
            result.put("strict_local_only", isStrictLocalOnly());
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

        // 1. Voce TV: Pronuncia attraverso altoparlanti se richiesto
        if (speakRequested && context != null && replyMsg != null && !replyMsg.trim().isEmpty()) {
            try {
                AkaiSpeechEngine speech = AkaiSpeechEngine.getInstance(context);
                speech.speak(replyMsg, true);
            } catch (Throwable e) {
                Log.w(TAG, "Speech engine playback notice: " + e.getMessage());
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

            // Caso G: Navigazione a elemento testuale presente attualmente a schermo
            if (snapshot != null && snapshot.visibleTexts != null) {
                for (String t : snapshot.visibleTexts) {
                    if (t.length() >= 3 && clean.contains(t.toLowerCase())) {
                        actions.put(new JSONObject().put("type", "click_text").put("text", t));
                        String cond = "{\"type\":\"contains_text\",\"value\":\"" + t + "\"}";
                        return new DiscoveryPlan(actions, cond, "Selezione elemento a schermo: \"" + t + "\"");
                    }
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
