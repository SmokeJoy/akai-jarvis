package it.akai.customremote.ai;

import java.util.concurrent.atomic.AtomicReference;

/**
 * Pure Java handoff between the real MediaProjection service and the planner.
 * A session is registered only after visible owner/Android consent. There is
 * no local AI model; the Android implementation calls DeepSeek/Kimi APIs.
 */
public final class VisualObservationProvider {
    public interface Cancellation {
        boolean isCancelled();
    }

    public interface Session {
        Result observe(String provider, String expectedPackage,
                String expectedUiContext, Cancellation cancel);

        default void stopByOwner() {
            // Host tests can use a no-op. Production stops MediaProjection.
        }
    }

    public static final class Result {
        public final boolean success;
        public final String reason;
        public final String provider;
        public final String packageName;
        public final String uiContext;
        public final String description;
        public final long frameTimeMs;
        public final int tokens;
        public final double costEur;

        private Result(boolean success, String reason, String provider, String packageName,
                String uiContext, String description, long frameTimeMs,
                int tokens, double costEur) {
            this.success = success;
            this.reason = reason;
            this.provider = provider;
            this.packageName = packageName;
            this.uiContext = uiContext;
            this.description = description;
            this.frameTimeMs = frameTimeMs;
            this.tokens = tokens;
            this.costEur = costEur;
        }

        public static Result unavailable(String reason) {
            return new Result(false, reason, null, null, null, null, 0, 0, 0.0);
        }

        public static Result observed(String provider, String packageName,
                String uiContext, String description, long frameTimeMs,
                int tokens, double costEur) {
            return new Result(true, "UNTRUSTED_REMOTE_DESCRIPTION", provider, packageName,
                    uiContext, description, frameTimeMs, tokens, costEur);
        }
    }

    private static final AtomicReference<Session> ACTIVE = new AtomicReference<>();

    private VisualObservationProvider() {}

    public static boolean install(Session session) {
        return session != null && ACTIVE.compareAndSet(null, session);
    }

    public static void clear(Session session) {
        if (session != null) ACTIVE.compareAndSet(session, null);
    }

    public static boolean active() {
        return ACTIVE.get() != null;
    }

    /** Cancelling a task also revokes its live screen capture authorization. */
    public static void stopAndRevoke() {
        Session current = ACTIVE.getAndSet(null);
        if (current != null) {
            try { current.stopByOwner(); } catch (RuntimeException ignored) {}
        }
    }

    /**
     * No provider substitution or reused observation across a screen change.
     * The description remains untrusted, and a successful result DOES NOT
     * grant permission to click or constitute proof of task completion.
     */
    public static Result observe(String provider, String expectedPackage,
            String expectedUi, Cancellation cancel) {
        Session session = ACTIVE.get();
        if (session == null) return Result.unavailable("NO_CONSENTED_SESSION");
        if (!CloudProviderPolicy.isSupportedCloudProvider(provider)
                || expectedPackage == null || expectedPackage.isEmpty()
                || expectedUi == null || expectedUi.isEmpty()
                || expectedUi.contains("blocked_sensitive_screen")
                || (cancel != null && cancel.isCancelled())) {
            return Result.unavailable("UNSAFE_OBSERVATION_REQUEST");
        }
        Result result;
        try {
            result = session.observe(provider, expectedPackage, expectedUi, cancel);
        } catch (RuntimeException ignored) {
            return Result.unavailable("CAPTURE_FAILED");
        }
        // STOP or service teardown may revoke/replace this session while
        // an Android capture or DeepSeek/Kimi request is still in flight.
        // Never feed an observation from an old consent grant to the planner.
        if (ACTIVE.get() != session) {
            return Result.unavailable("SESSION_REVOKED_DURING_OBSERVATION");
        }
        if (result == null || !result.success) {
            return result == null ? Result.unavailable("NO_RESULT") : result;
        }
        if (!provider.equals(result.provider)
                || !expectedPackage.equals(result.packageName)
                || !expectedUi.equals(result.uiContext)
                || result.description == null || result.description.trim().isEmpty()
                || result.frameTimeMs <= 0L || result.tokens < 0
                || !Double.isFinite(result.costEur) || result.costEur < 0
                || (cancel != null && cancel.isCancelled())) {
            return Result.unavailable("STALE_OR_INVALID_VISUAL_EVIDENCE");
        }
        return result;
    }
}
