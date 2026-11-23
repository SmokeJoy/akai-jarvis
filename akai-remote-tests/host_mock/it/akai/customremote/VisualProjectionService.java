package it.akai.customremote;

import android.content.Context;

/**
 * Host mock for VisualProjectionService used by deterministic unit tests of
 * VisionSessionCoordinator timeout/callback handoff and byte scrubbing.
 */
public final class VisualProjectionService {
    public interface FrameCallback {
        void onFrame(FrameResult result);
    }

    public interface RequestHandler {
        boolean onRequest(String expectedProvider, FrameCallback callback);
    }

    public static final class FrameResult {
        public final byte[] jpeg;
        public final int width;
        public final int height;
        public final String provider;
        public final String foregroundPackage;
        public final String redactedUiContext;
        public final long observedAtMs;
        public final String error;

        public FrameResult(byte[] jpeg, int width, int height, String provider,
                String foregroundPackage, String redactedUiContext,
                long observedAtMs, String error) {
            this.jpeg = jpeg;
            this.width = width;
            this.height = height;
            this.provider = provider;
            this.foregroundPackage = foregroundPackage;
            this.redactedUiContext = redactedUiContext;
            this.observedAtMs = observedAtMs;
            this.error = error;
        }

        public boolean ok() {
            return jpeg != null && jpeg.length > 0 && error == null;
        }

        public static FrameResult denied(String reason) {
            return new FrameResult(null, 0, 0, null, null, null, 0L, reason);
        }
    }

    private static volatile boolean sSessionActive = false;
    private static volatile RequestHandler sRequestHandler = null;

    public static void setSessionActiveForTest(boolean active) {
        sSessionActive = active;
    }

    public static void setRequestHandlerForTest(RequestHandler handler) {
        sRequestHandler = handler;
    }

    public static boolean isSessionActive() {
        return sSessionActive;
    }

    public static boolean requestFrame(String expectedProvider, FrameCallback callback) {
        if (!sSessionActive || callback == null) return false;
        RequestHandler handler = sRequestHandler;
        if (handler != null) {
            return handler.onRequest(expectedProvider, callback);
        }
        return false;
    }

    public static void stopOwnerSession(Context ctx) {
        sSessionActive = false;
    }
}
