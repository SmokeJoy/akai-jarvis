package it.akai.customremote.ai;

/**
 * Ensures frames acquired from ONE ImageReader/VirtualDisplay session advance
 * monotonically. Image.getTimestamp() is source-specific: it MUST NOT be
 * compared against System.nanoTime() or SystemClock.elapsedRealtimeNanos().
 *
 * A frame with no usable timestamp fails closed instead of risking navigation
 * with a screenshot from the previously opened application.
 * This is a lightweight deterministic check, NOT an on-device AI model.
 */
public final class FrameSequenceGate {
    private long mostRecentTimestampNs = Long.MIN_VALUE;
    private int accepted;

    public synchronized boolean accept(long frameTimestampNs) {
        if (frameTimestampNs <= 0) return false;
        if (mostRecentTimestampNs > 0 && frameTimestampNs <= mostRecentTimestampNs) {
            return false;
        }
        mostRecentTimestampNs = frameTimestampNs;
        accepted++;
        return true;
    }

    public synchronized int acceptedCount() {
        return accepted;
    }
}
