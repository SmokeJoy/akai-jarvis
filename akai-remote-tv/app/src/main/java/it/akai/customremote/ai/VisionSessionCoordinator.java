package it.akai.customremote.ai;

import android.content.Context;
import android.os.SystemClock;

import java.util.Arrays;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import it.akai.customremote.VisualProjectionService;

/**
 * Bounded off-main-thread bridge between a real MediaProjection frame and
 * DeepSeek/Kimi cloud vision. Never executes actions or models locally.
 * The screenshot is erased immediately after the HTTPS attempt.
 */
public final class VisionSessionCoordinator {
    private static final long FRAME_WAIT_MS = 4300L;
    private static volatile Runnable sNextOfferPreLockHookForTest;
    private static volatile Runnable sNextOfferPreCountDownHookForTest;

    public interface Cancellation {
        boolean isCancelled();
    }

    public static void setNextOfferHooksForTest(Runnable preLockHook, Runnable preCountDownHook) {
        sNextOfferPreLockHookForTest = preLockHook;
        sNextOfferPreCountDownHookForTest = preCountDownHook;
    }

    public static void scrubFrame(VisualProjectionService.FrameResult frame) {
        if (frame != null && frame.jpeg != null) {
            Arrays.fill(frame.jpeg, (byte) 0);
        }
    }

    /**
     * Linearizable single-frame handoff between the MediaProjection worker callback
     * and the waiting coordinator thread. Publish, duplicate-callback rejection, and
     * timeout/cancel close+scrub share one intrinsic lock so a racing or preempted
     * callback can never retain an un-zeroed JPEG buffer after timeout/return.
     */
    public static final class FrameHandoff {
        private final CountDownLatch latch = new CountDownLatch(1);
        private final Runnable preLockHook;
        private final Runnable preCountDownHook;
        private VisualProjectionService.FrameResult slot;
        private boolean delivered;
        private boolean closed;

        public FrameHandoff() {
            this(sNextOfferPreLockHookForTest, sNextOfferPreCountDownHookForTest);
            sNextOfferPreLockHookForTest = null;
            sNextOfferPreCountDownHookForTest = null;
        }

        public FrameHandoff(Runnable preLockHook, Runnable preCountDownHook) {
            this.preLockHook = preLockHook;
            this.preCountDownHook = preCountDownHook;
        }

        public boolean offer(VisualProjectionService.FrameResult frame) {
            if (preLockHook != null) {
                preLockHook.run();
            }
            final boolean accepted;
            synchronized (this) {
                if (closed || delivered) {
                    accepted = false;
                } else {
                    delivered = true;
                    slot = frame;
                    accepted = true;
                }
            }
            if (accepted) {
                if (preCountDownHook != null) {
                    preCountDownHook.run();
                }
                latch.countDown();
            } else {
                scrubFrame(frame);
            }
            return accepted;
        }

        public boolean awaitSlice(long timeoutMs) throws InterruptedException {
            return latch.await(timeoutMs, TimeUnit.MILLISECONDS);
        }

        public VisualProjectionService.FrameResult finishOrClose(boolean consume) {
            final VisualProjectionService.FrameResult taken;
            synchronized (this) {
                closed = true;
                taken = slot;
                slot = null;
            }
            if (!consume) {
                scrubFrame(taken);
                return null;
            }
            return taken;
        }

        public synchronized boolean isClosed() {
            return closed;
        }

        public synchronized boolean hasRetainedFrame() {
            return slot != null;
        }
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

        final FrameHandoff handoff = new FrameHandoff();

        boolean accepted = VisualProjectionService.requestFrame(selectedProvider,
                new VisualProjectionService.FrameCallback() {
                    @Override public void onFrame(VisualProjectionService.FrameResult frame) {
                        handoff.offer(frame);
                    }
                });
        if (!accepted) {
            handoff.finishOrClose(false);
            return Observation.denied("CAPTURE_SERVICE_UNAVAILABLE");
        }

        long begun = SystemClock.elapsedRealtime();
        boolean ready = false;
        VisualProjectionService.FrameResult frame = null;
        try {
            try {
                while (SystemClock.elapsedRealtime() - begun < FRAME_WAIT_MS) {
                    if (cancel != null && cancel.isCancelled()) break;
                    if (handoff.awaitSlice(100L)) {
                        ready = true;
                        break;
                    }
                }
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
            } finally {
                boolean mayConsume = ready
                        && !(cancel != null && cancel.isCancelled())
                        && !Thread.currentThread().isInterrupted();
                frame = handoff.finishOrClose(mayConsume);
            }
            if (!ready || (cancel != null && cancel.isCancelled()) || Thread.currentThread().isInterrupted()) {
                return Observation.denied(
                        ((cancel != null && cancel.isCancelled()) || Thread.currentThread().isInterrupted())
                                ? "TASK_CANCELLED" : "FRAME_TIMEOUT");
            }
            if (frame == null || !frame.ok()) {
                return Observation.denied(frame == null ? "FRAME_MISSING" : frame.error);
            }
            if (!selectedProvider.equals(frame.provider)
                    || !expectedPackage.equals(frame.foregroundPackage)
                    || !expectedUi.equals(frame.redactedUiContext)) {
                return Observation.denied("UI_CHANGED_BEFORE_UPLOAD");
            }
            // STOP may race the frame callback or the wait above. Avoid starting
            // a billable cloud request after the user revoked visual capture.
            if ((cancel != null && cancel.isCancelled())
                    || Thread.currentThread().isInterrupted()
                    || !VisualObservationProvider.active()
                    || !VisualProjectionService.isSessionActive()
                    || !adapter.hasCloudContextConsent()) {
                return Observation.denied("SESSION_REVOKED_BEFORE_UPLOAD");
            }
            AiProviderAdapter.VisionCloudResult described = adapter.describeScreenJpegOnce(
                    frame.jpeg, frame.width, frame.height,
                    true, true, false);
            if (!described.success) {
                return Observation.denied(described.error);
            }
            if ((cancel != null && cancel.isCancelled()) || Thread.currentThread().isInterrupted()) {
                return Observation.denied("TASK_CANCELLED");
            }
            if (!VisualObservationProvider.active()
                    || !VisualProjectionService.isSessionActive()
                    || !adapter.hasCloudContextConsent()) {
                return Observation.denied("SESSION_REVOKED_DURING_OBSERVATION");
            }
            return new Observation(true, "REMOTE_IMAGE_DESCRIPTION_UNVERIFIED",
                    selectedProvider, described.description, frame.foregroundPackage,
                    frame.redactedUiContext, frame.observedAtMs,
                    described.tokens, described.estimatedCostEur);
        } finally {
            scrubFrame(frame);
        }
    }
}
