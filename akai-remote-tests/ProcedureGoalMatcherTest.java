package it.akai.customremote;

import it.akai.customremote.ai.ProcedureGoalMatcher;

public final class ProcedureGoalMatcherTest {
    private static int checks;
    private static void expect(boolean expected, String requested, String stored, String label) {
        checks++;
        boolean actual = ProcedureGoalMatcher.matches(requested, stored);
        if (actual != expected) throw new AssertionError(label + " requested="
                + requested + " stored=" + stored + " got=" + actual);
    }

    public static void main(String[] args) {
        expect(true, "Metti Italia 2 in diretta", "italia2", "compact channel key");
        expect(true, "Metti Italia 2", "metti italia 2", "complete known intent");
        expect(true, "Italia 2", "metti Italia 2 in diretta", "short channel request");
        expect(true, "Rai 1", "rai1", "adjacent number");
        expect(true, "Apri YouTube!", "youtube", "ordinary named app");
        expect(true, "YouTube", "apri youtube", "stored goal with verb");
        expect(true, "Apri Netflix", "apri Netflix", "exact goal");
        expect(true, "Avvia l'app Musica", "musica", "named app in phrase");
        expect(true, "Accendi piu' tardi", "accendi più tardi", "accent normalization");
        expect(false, "attiva", "tv", "substring inside word forbidden");
        expect(false, "Italia 20", "italia2", "cannot confuse channel 2 with 20");
        expect(false, "Rai 10", "rai1", "cannot confuse channel 1 with 10");
        expect(false, "apri", "apri youtube", "generic verb forbidden");
        expect(false, "metti", "metti italia 2", "generic verb forbidden");
        expect(false, "vai", "vai alla home", "generic command forbidden");
        expect(false, "apri youtube", "apri netflix", "different installed apps");
        expect(false, "youtube kids", "youtube", "different product variant");
        expect(false, "Metti Italia2", "italia20", "different compact key");
        expect(false, "attiva il timer", "tv", "short key isn't match");
        expect(false, null, "youtube", "null query");
        expect(false, "youtube", null, "null stored");
        expect(false, "", "youtube", "empty query");
        System.out.println("ProcedureGoalMatcherTest PASS: " + checks + " safety checks");
    }
}
