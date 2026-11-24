package android.os;

import java.util.concurrent.atomic.AtomicLong;

public final class SystemClock {
    private static final AtomicLong sOffsetMs = new AtomicLong(0L);

    private SystemClock() {}

    public static long elapsedRealtime() {
        return (System.nanoTime() / 1_000_000L) + sOffsetMs.get();
    }

    public static void advanceElapsedRealtimeForTest(long deltaMs) {
        sOffsetMs.addAndGet(deltaMs);
    }

    public static void resetForTest() {
        sOffsetMs.set(0L);
    }
}
