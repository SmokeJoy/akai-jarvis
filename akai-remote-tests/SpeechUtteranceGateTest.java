package it.akai.customremote;

import it.akai.customremote.ai.SpeechUtteranceGate;

public final class SpeechUtteranceGateTest {
    private static int checks;
    private static void expect(boolean condition, String message) {
        checks++;
        if (!condition) throw new AssertionError(message);
    }

    public static void main(String[] args) {
        SpeechUtteranceGate gate = new SpeechUtteranceGate();
        expect(!gate.isCurrent("one"), "idle before first request");
        expect(!gate.finish("one"), "no finish without a live request");
        gate.activate("one");
        expect(gate.isCurrent("one"), "first active");
        gate.stop();
        gate.activate("two");
        expect(!gate.isCurrent("one"), "STOP invalidates older utterance");
        expect(!gate.finish("one"), "old callback cannot finish replacement");
        expect(gate.isCurrent("two"), "replacement stays active");
        expect(gate.finish("two"), "current callback completes");
        expect(!gate.finish("two"), "duplicate callback is ignored");
        gate.activate("three");
        gate.activate("four");
        expect(!gate.finish("three"), "late callback cannot clear latest utterance");
        expect(gate.isCurrent("four"), "latest utterance remains active");
        gate.stop();
        expect(!gate.finish("four"), "STOP invalidates current callback");
        expect(!gate.isCurrent(null), "null callback cannot be current");
        expect(!gate.finish(null), "null callback cannot complete");
        boolean invalidRejected = false;
        try { gate.activate(""); } catch (IllegalArgumentException expected) {
            invalidRejected = true;
        }
        expect(invalidRejected, "empty identifiers forbidden");
        System.out.println("SpeechUtteranceGateTest PASS: " + checks + " checks");
    }
}
