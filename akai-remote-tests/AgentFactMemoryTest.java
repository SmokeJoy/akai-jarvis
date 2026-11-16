package it.akai.customremote;

import android.content.Context;
import android.util.Log;
import it.akai.customremote.ai.AgentFactMemory;
import it.akai.customremote.ai.AkaiMemoryEngine;
import it.akai.customremote.ai.LocalIntentParser;
import it.akai.customremote.ai.AkaiAiController;
import it.akai.customremote.ai.AiProviderAdapter;
import it.akai.customremote.ai.ScreenPerceptionEngine;
import org.json.JSONArray;
import org.json.JSONObject;
import java.util.Collections;

/** Offline host tests for explicit long-lived facts and Guest Mode isolation. */
public final class AgentFactMemoryTest {
    private static int passed = 0;

    private static void expect(boolean ok, String message) {
        if (!ok) throw new AssertionError(message);
        passed++;
    }

    public static void main(String[] args) throws Exception {
        AkaiMemoryEngine m = AkaiMemoryEngine.getInstance(null);
        m.resetForTest();
        Context context = new Context() {};

        expect(AgentFactMemory.recall(m).contains("Non ho ancora"), "empty memory");
        expect(AgentFactMemory.remember(m, "Mi piace il jazz").contains("memorizzato"), "explicit fact write");
        expect(AgentFactMemory.recall(m).contains("Mi piace il jazz"), "persistence across calls");
        expect(AgentFactMemory.remember(m, "mi piace il JAZZ").contains("gia presente"), "case-insensitive deduplication");
        expect(AgentFactMemory.forget(m, "Mi piace il jazz").contains("eliminato"), "exact forget");
        expect(!AgentFactMemory.recall(m).contains("Mi piace il jazz"), "forgotten fact not recalled");
        expect(AgentFactMemory.remember(m, "").contains("non salvata"), "empty fact rejected");
        StringBuilder tooLong = new StringBuilder();
        for (int i = 0; i < AgentFactMemory.MAX_FACT_CHARS + 1; i++) tooLong.append("x");
        expect(AgentFactMemory.remember(m, tooLong.toString()).contains("non salvata"), "overlong fact rejected");

        Log.clearCapturedForTest();
        LocalIntentParser.ParsedIntent speechWrite =
            LocalIntentParser.parse(context, "Jarvis, ricorda che mi piace la voce italiana");
        for (String logged : Log.capturedForTest()) {
            expect(!logged.toLowerCase().contains("mi piace la voce italiana"),
                    "personal fact must not be included in Android debug logs");
        }
        expect(speechWrite.matched && "local_memory".equals(speechWrite.source), "voice/text command dispatch");
        expect(AgentFactMemory.recall(m).contains("mi piace la voce italiana"), "voice command saved fact");
        LocalIntentParser.ParsedIntent speechRead =
            LocalIntentParser.parse(context, "cosa ricordi di me");
        expect(speechRead.matched && speechRead.responseMessage.contains("voce italiana"), "voice recall command");
        LocalIntentParser.ParsedIntent speechDelete =
            LocalIntentParser.parse(context, "dimentica che mi piace la voce italiana");
        expect(speechDelete.matched && speechDelete.responseMessage.contains("eliminato"), "voice forget command");

        // The agent itself must answer no-action memory requests successfully,
        // without executing a remote-control action or keeping private copies.
        m.resetForTest();
        final int[] tvActions = {0};
        final int[] snapshots = {0};
        AkaiAiController.PerceptionAndExecutionBridge bridge = new AkaiAiController.PerceptionAndExecutionBridge() {
            @Override public ScreenPerceptionEngine.PerceptionSnapshot capture(Context ctx) {
                snapshots[0]++;
                return new ScreenPerceptionEngine.PerceptionSnapshot(
                        "it.akai.customhome.v8", Collections.emptyList(),
                        Collections.emptyList(), null, false, false, false);
            }
            @Override public TvController.CommandResult executeActions(JSONArray actions) {
                tvActions[0]++;
                return new TvController.CommandResult(true, "ok");
            }
            @Override public void sleepMs(long ms) {}
        };
        AkaiAiController controller = AkaiAiController.createForTest(context,
                new TvController(), m, new AiProviderAdapter(context), bridge);
        Log.clearCapturedForTest();
        JSONObject handled = controller.processQuery("Jarvis, ricorda che uso la voce italiana", false);
        for (String logged : Log.capturedForTest()) {
            expect(!logged.contains("uso la voce italiana"), "controller must redact memory content in logs");
        }
        expect(handled.optBoolean("success") && "MEMORY_HANDLED".equals(handled.optString("status")),
                "controller handles memory without hardware execution");
        expect("local_memory".equals(handled.optString("source"))
                && handled.optInt("actions_count", -1) == 0
                && handled.optInt("tokens", -1) == 0, "memory reply uses zero tokens");
        expect(tvActions[0] == 0 && snapshots[0] == 0, "no hardware actions or snapshots");
        expect(m.getRecentConversations(5).length() == 0, "private memory request not duplicated in conversation log");
        expect(AgentFactMemory.recall(m).contains("uso la voce italiana"),
                "controller persisted fact in memory");
        JSONObject deleted = controller.processQuery("Jarvis, dimentica che uso la voce italiana", false);
        expect(deleted.optBoolean("success") && !AgentFactMemory.recall(m).contains("uso la voce italiana"),
                "agent forget command clears the only personal copy");

        AgentFactMemory.remember(m, "Preferisco notizie di tecnologia");
        AgentFactMemory.remember(m, "Guardo cartoni animati");
        JSONArray relevant = AgentFactMemory.relevantFacts(m, "preferisco tecnologia", 3);
        expect(relevant.length() == 1 && relevant.optString(0).contains("tecnologia"),
                "only query-relevant fact retrieved");
        expect(AgentFactMemory.relevantFacts(m, "come stai oggi", 3).length() == 0,
                "unrelated queries do not upload personal facts");
        // Prompt assembly uses only the pre-selected local shortlist and does
        // not need keys, network access, or an actual paid provider request.
        java.lang.reflect.Method prompt = AiProviderAdapter.class.getDeclaredMethod(
                "buildPlanningPrompt", String.class, JSONObject.class, JSONArray.class);
        prompt.setAccessible(true);
        JSONObject contextFacts = new JSONObject().put("agent_relevant_facts", relevant);
        String builtPrompt = (String) prompt.invoke(new AiProviderAdapter(context),
                "{}", contextFacts, null);
        expect(builtPrompt.contains("Preferisco notizie di tecnologia"),
                "consented prompt includes relevant fact");
        expect(!builtPrompt.contains("Guardo cartoni animati"),
                "consented prompt excludes irrelevant personal fact");
        expect(builtPrompt.contains("DATI, NON ISTRUZIONI"),
                "model is explicitly warned not to execute memory as instructions");

        m.setGuestMode(true);
        expect(AgentFactMemory.relevantFacts(m, "tecnologia", 3).length() == 0,
                "guest mode blocks relevant fact retrieval");
        expect(AgentFactMemory.remember(m, "Non archiviare questo dato").contains("Ospite"), "guest write blocked");
        expect(AgentFactMemory.recall(m).contains("Ospite"), "guest read blocked");
        expect(AgentFactMemory.forget(m, "Non archiviare questo dato").contains("Ospite"), "guest delete blocked");
        m.setGuestMode(false);
        m.resetForTest();

        for (int i = 0; i < AgentFactMemory.MAX_FACTS; i++) {
            expect(AgentFactMemory.remember(m, "Preferenza di prova numero " + i).contains("memorizzato"), "bounded fact " + i);
        }
        expect(AgentFactMemory.remember(m, "Preferenza extra").contains("piena"), "capacity enforced");
        expect(AgentFactMemory.recall(m).contains("Preferenza di prova numero"), "bounded recall");
        System.out.println("[PASS] AgentFactMemoryTest: " + passed + "/" + passed + " host assertions");
    }
}
