package it.akai.customremote.ai;

import android.content.Context;

import java.util.Arrays;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

import it.akai.customremote.VisualProjectionService;

/**
 * Bounded off-main-thread bridge between a real MediaProjection frame and
 * DeepSeek/Kimi cloud vision. Never executes actions or models locally.
 * The screenshot is erased immediately after the HTTPS attempt.
 */
public final class VisionSessionCoordinator {
    private static final long FRAME_WAIT_MS = 4300L;

    public interface Cancellation {
        boolean isCancelled();
    }

    public static final class Observation {
        public final boolean usable;
        public final String reason;
        public final String provider;
        public final String description;
        public final String packageName;
        public final String redactedContext;
        public final long frameTimeMs;
        public final int tokens;
        public final double costEur;

        private Observation(boolean usable, String reason, String provider, String description,
                String packageName, String redactedContext, long frameTimeMs,
                int tokens, double costEur) {
            this.usable = usable;
            this.reason = reason;
            this.provider = provider;
            this.description = description;
            this.packageName = packageName;
            this.redactedContext = redactedContext;
            this.frameTimeMs = frameTimeMs;
            this.tokens = tokens;
            this.costEur = costEur;
        }

        public static Observation denied(String code) {
            return new Observation(false, code, null, null, null, null, 0, 0, 0.0);
        }
    }

    private VisionSessionCoordinator() {}

    public static Observation observe(Context context, AiProviderAdapter adapter,
            String selectedProvider, String expectedPackage, String expectedUi,
            Cancellation cancel) {
        if (!CloudProviderPolicy.isSupportedCloudProvider(selectedProvider)
                || adapter == null || !adapter.hasCloudContextConsent()
                || AkaiAiController.isStrictLocalOnly()
                || !VisualProjectionService.isSessionActive()) {
            return Observation.denied("SESSION_OR_CONSENT_UNAVAILABLE");
        }
        if (cancel != null && cancel.isCancelled()) return Observation.denied("TASK_CANCELLED");
        if (expectedPackage == null || expectedPackage.isEmpty()
                || expectedUi == null || expectedUi.isEmpty()
                || expectedUi.contains("blocked_sensitive_screen")) {
            return Observation.denied("NO_SAFE_UI_CONTEXT");
        }

        final AtomicBoolean accepting = new AtomicBoolean(true);
        final AtomicReference<VisualProjectionService.FrameResult> received =
                new AtomicReference<>();
        final CountDownLatch latch = new CountDownLatch(1);

        boolean accepted = VisualProjectionService.requestFrame(selectedProvider,
                new VisualProjectionService.FrameCallback() {
                    @Override public void onFrame(VisualProjectionService.FrameResult frame) {
                        if (!accepting.compareAndSet(true, false)) {
                            if (frame != null && frame.jpeg != null) Arrays.fill(frame.jpeg, (byte) 0);
                            return;
                        }
                        received.set(frame);
                        latch.countDown();
                    }
                });
        if (!accepted) return Observation.denied("CAPTURE_SERVICE_UNAVAILABLE");

        long begun = System.currentTimeMillis();
        boolean ready = false;
        try {
            while (System.currentTimeMillis() - begun < FRAME_WAIT_MS) {
                if (cancel != null && cancel.isCancelled()) break;
                if (latch.await(100L, TimeUnit.MILLISECONDS)) {
                    ready = true;
                    break;
                }
            }
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
        } finally {
            if (!ready) accepting.set(false);
        }
        if (!ready) {
            VisualProjectionService.FrameResult late = received.getAndSet(null);
            if (late != null && late.jpeg != null) Arrays.fill(late.jpeg, (byte) 0);
            return Observation.denied(cancel != null && cancel.isCancelled()
                    ? "TASK_CANCELLED" : "FRAME_TIMEOUT");
        }

        VisualProjectionService.FrameResult frame = received.getAndSet(null);
        if (frame == null || !frame.ok()) {
            return Observation.denied(frame == null ? "FRAME_MISSING" : frame.error);
        }
        try {
            if (cancel != null && cancel.isCancelled()) return Observation.denied("TASK_CANCELLED");
            if (!selectedProvider.equals(frame.provider)
                    || !expectedPackage.equals(frame.foregroundPackage)
                    || !expectedUi.equals(frame.redactedUiContext)) {
                return Observation.denied("UI_CHANGED_BEFORE_UPLOAD");
            }
            AiProviderAdapter.VisionCloudResult described = adapter.describeScreenJpegOnce(
                    frame.jpeg, frame.width, frame.height,
                    true, true, false);
            if (!described.success) {
                return Observation.denied(described.error);
            }
            if (cancel != null && cancel.isCancelled()) return Observation.denied("TASK_CANCELLED");
            return new Observation(true, "REMOTE_IMAGE_DESCRIPTION_UNVERIFIED",
                    selectedProvider, described.description, frame.foregroundPackage,
                    frame.redactedUiContext, frame.observedAtMs,
                    described.tokens, described.estimatedCostEur);
        } finally {
            Arrays.fill(frame.jpeg, (byte) 0);
        }
    }
}
