package it.akai.customremote;

import it.akai.customremote.ai.VisualCaptureSessionGate;

public final class VisualCaptureSessionGateTest {
    private static int checks;
    private static final long NOW = 1_700_000_000_000L;

    private static void verify(boolean condition, String reason) {
        checks++;
        if (!condition) throw new AssertionError(reason);
    }

    private static VisualCaptureSessionGate.Verdict next(VisualCaptureSessionGate gate,
            String provider, boolean consent, boolean sensitive, boolean drm, long now) {
        return gate.reserveNextFrame(provider, consent, sensitive, drm, now);
    }

    public static void main(String[] args) {
        verify(VisualCaptureSessionGate.begin(false, true, "deepseek", NOW) == null,
                "Android projection approval is mandatory");
        verify(VisualCaptureSessionGate.begin(true, false, "deepseek", NOW) == null,
                "separate owner cloud-image consent is mandatory");
        verify(VisualCaptureSessionGate.begin(true, true, "local", NOW) == null,
                "a local AI model is forbidden");
        verify(VisualCaptureSessionGate.begin(true, true, "openai", NOW) == null,
                "a third-party AI model is forbidden");
        verify(VisualCaptureSessionGate.begin(true, true, "kimi", 0) == null,
                "invalid session timestamp");

        VisualCaptureSessionGate gate = VisualCaptureSessionGate.begin(true, true, "deepseek", NOW);
        verify(gate != null && gate.isActive(), "session starts with owner consent");
        verify(!next(gate, "kimi", true, false, false, NOW).allowed,
                "provider switching cannot reuse cloud image consent");
        verify(!next(gate, "deepseek", false, false, false, NOW).allowed,
                "revoked cloud context opt-in");
        verify(!next(gate, "deepseek", true, true, false, NOW).allowed,
                "sensitive UI is never captured");
        verify(!next(gate, "deepseek", true, false, true, NOW).allowed,
                "protected/DRM screen never captured");
        verify(next(gate, "deepseek", true, false, false, NOW).allowed,
                "first frame permitted");
        verify(!next(gate, "deepseek", true, false, false, NOW + 1000).allowed,
                "cannot overlap frame encoding/cloud calls");
        gate.completeFrame(true);
        verify(!next(gate, "deepseek", true, false, false, NOW + 500).allowed,
                "minimum frame spacing");
        verify(next(gate, "deepseek", true, false, false, NOW + 750).allowed,
                "new frame after app transition");
        gate.completeFrame(true);
        verify(gate.getFrameCount() == 2, "two real frame reservations");
        verify(!next(gate, "deepseek", true, false, false,
                NOW + VisualCaptureSessionGate.MAX_SESSION_MS).allowed, "session expiry");
        verify(!gate.isActive(), "expired session stops");

        VisualCaptureSessionGate failing = VisualCaptureSessionGate.begin(true, true, "kimi", NOW);
        for (int i = 0; i < 3; i++) {
            verify(next(failing, "kimi", true, false, false,
                    NOW + i * VisualCaptureSessionGate.MIN_FRAME_SPACING_MS).allowed,
                    "bounded retries");
            failing.completeFrame(false);
        }
        verify(!failing.isActive(), "3 consecutive capture failures stop session");

        VisualCaptureSessionGate allowed = VisualCaptureSessionGate.begin(true, true, "deepseek", NOW);
        for (int i = 0; i < VisualCaptureSessionGate.MAX_FRAMES; i++) {
            verify(next(allowed, "deepseek", true, false, false,
                    NOW + i * VisualCaptureSessionGate.MIN_FRAME_SPACING_MS).allowed,
                    "bounded on-demand captures");
            allowed.completeFrame(true);
        }
        verify(allowed.getFrameCount() == VisualCaptureSessionGate.MAX_FRAMES, "max frames");
        verify(!next(allowed, "deepseek", true, false, false,
                NOW + VisualCaptureSessionGate.MAX_FRAMES
                * VisualCaptureSessionGate.MIN_FRAME_SPACING_MS).allowed,
                "frame limit cannot be exceeded");
        verify(!allowed.isActive(), "session closes after cap");
        VisualCaptureSessionGate cancelled = VisualCaptureSessionGate.begin(true, true, "kimi", NOW);
        cancelled.stop();
        verify(!cancelled.isActive(), "owner cancel closes session");
        verify(!next(cancelled, "kimi", true, false, false, NOW).allowed,
                "cancellation prevents future frames");
        System.out.println("VisualCaptureSessionGateTest PASS: " + checks
                + " assertions (deterministic policy; no pixels/API calls).");
    }
}
