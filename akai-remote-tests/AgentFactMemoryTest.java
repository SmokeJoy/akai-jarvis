package it.akai.customremote;

import android.content.Context;
import android.util.Log;
import it.akai.customremote.ai.AgentFactMemory;
import it.akai.customremote.ai.AkaiMemoryEngine;
import it.akai.customremote.ai.LocalIntentParser;

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

        m.setGuestMode(true);
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
