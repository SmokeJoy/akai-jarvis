package it.akai.customremote.ai;

/**
 * Lightweight, deterministic lifecycle guard for a future Android 9
 * MediaProjection session producing multiple on-demand frames.
 *
 * No AI inference, no screenshots, no networking, no Android dependencies.
 * One Android system consent starts exactly one bounded capture session.
 * The same VirtualDisplay may provide frames across different apps;
 * acquiring a new MediaProjection session requires fresh Android consent.
 *
 * A separate per-session owner opt-in is required before sending any of
 * those frames to DeepSeek or Kimi. A sensitive screen blocks the frame,
 * never authorizes blind navigation, and never lifts the privacy restriction.
 */
public final class VisualCaptureSessionGate {
    public static final long MAX_SESSION_MS = 180_000L; // 3 minutes
    public static final int MAX_FRAMES = 20;
    public static final long MIN_FRAME_SPACING_MS = 750L;
    public static final int MAX_CONSECUTIVE_FAILURES = 3;

    private final long startedAtMs;
    private final String provider;
    private boolean active;
    private boolean cloudImagesAllowed;
    private boolean frameInFlight;
    private long lastFrameAtMs = -1L;
    private int framesReserved;
    private int consecutiveFailures;

    private VisualCaptureSessionGate(String provider, long startedAtMs,
                                     boolean cloudImagesAllowed) {
        this.provider = provider;
        this.startedAtMs = startedAtMs;
        this.cloudImagesAllowed = cloudImagesAllowed;
        this.active = true;
    }

    public static VisualCaptureSessionGate begin(boolean androidConsent,
            boolean ownerSessionImageConsent, String provider, long startedAtMs) {
        if (!androidConsent || !ownerSessionImageConsent
                || startedAtMs <= 0L
                || !CloudProviderPolicy.isSupportedCloudProvider(provider)) {
            return null;
        }
        return new VisualCaptureSessionGate(provider, startedAtMs, true);
    }

    public static final class Verdict {
        public final boolean allowed;
        public final String reason;

        private Verdict(boolean allowed, String reason) {
            this.allowed = allowed;
            this.reason = reason;
        }
    }

    private static Verdict reject(String reason) {
        return new Verdict(false, reason);
    }

    /**
     * Called immediately BEFORE acquiring the next screen image.
     * Images must be captured only on demand, after a UI change or failed
     * observation; no continuous video stream or polling loop on the TV.
     */
    public synchronized Verdict reserveNextFrame(String selectedProvider,
            boolean cloudContextConsent, boolean sensitiveScreen,
            boolean appProtectedOrDrm, long nowMs) {
        if (!active) return reject("SESSION_CLOSED");
        if (nowMs < startedAtMs || nowMs - startedAtMs >= MAX_SESSION_MS) {
            stop();
            return reject("SESSION_EXPIRED");
        }
        if (!cloudImagesAllowed || !cloudContextConsent) {
            return reject("CLOUD_IMAGE_CONSENT_MISSING");
        }
        if (!CloudProviderPolicy.isSupportedCloudProvider(selectedProvider)
                || !provider.equals(selectedProvider)) {
            return reject("PROVIDER_CHANGED");
        }
        if (sensitiveScreen || appProtectedOrDrm) {
            return reject("SCREEN_BLOCKED");
        }
        if (frameInFlight) return reject("FRAME_ALREADY_PENDING");
        if (framesReserved >= MAX_FRAMES) {
            stop();
            return reject("FRAME_LIMIT_REACHED");
        }
        if (lastFrameAtMs >= 0L
                && nowMs - lastFrameAtMs < MIN_FRAME_SPACING_MS) {
            return reject("FRAME_RATE_LIMIT");
        }
        lastFrameAtMs = nowMs;
        framesReserved++;
        frameInFlight = true;
        return new Verdict(true, "FRAME_RESERVED");
    }

    /** Release a reserved frame after encoding/description or any failure. */
    public synchronized void completeFrame(boolean usable) {
        if (!frameInFlight || !active) return;
        frameInFlight = false;
        if (usable) {
            consecutiveFailures = 0;
        } else if (++consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
            stop();
        }
    }

    /** Must be invoked for UI Stop, Android MediaProjection.onStop and task cancel. */
    public synchronized void stop() {
        active = false;
        cloudImagesAllowed = false;
        frameInFlight = false;
    }

    public synchronized boolean isActive() {
        return active;
    }

    public synchronized int getFrameCount() {
        return framesReserved;
    }
}
