package it.akai.customremote;

import it.akai.customremote.ai.FrameSequenceGate;

public final class FrameSequenceGateTest {
    private static int assertions;
    private static void check(boolean value, String message) {
        assertions++;
        if (!value) throw new AssertionError(message);
    }

    public static void main(String[] args) {
        FrameSequenceGate gate = new FrameSequenceGate();
        check(!gate.accept(0L), "unknown image timestamp is not trusted");
        check(!gate.accept(-1L), "invalid image timestamp is not trusted");
        check(gate.accept(100_000L), "first timestamp from image source accepted");
        check(!gate.accept(100_000L), "duplicate frame rejected after app switch");
        check(!gate.accept(99_999L), "buffered older frame rejected");
        check(gate.accept(101_000L), "fresh post-navigation frame accepted");
        check(!gate.accept(100_500L), "late stale callback cannot go backwards");
        check(gate.accept(102_000L), "next valid frame accepted");
        check(gate.acceptedCount() == 3, "only distinct monotonic frames accepted");
        FrameSequenceGate newSession = new FrameSequenceGate();
        check(newSession.accept(1L), "new Android consent gets independent source timestamp state");
        check(newSession.acceptedCount() == 1, "new session counter independent");
        System.out.println("FrameSequenceGateTest PASS: " + assertions
                + " checks, no System clock assumptions or cloud inference.");
    }
}
