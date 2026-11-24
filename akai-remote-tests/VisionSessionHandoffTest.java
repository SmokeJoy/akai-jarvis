package it.akai.customremote;

import android.content.Context;
import android.os.SystemClock;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

import it.akai.customremote.ai.AiProviderAdapter;
import it.akai.customremote.ai.AkaiAiController;
import it.akai.customremote.ai.VisionSessionCoordinator;
import it.akai.customremote.ai.VisualObservationProvider;

/**
 * Deterministic concurrency and memory-scrubbing tests for NEXT-5 (#7088137907):
 * linearizable timeout/callback handoff in VisionSessionCoordinator, zero JPEG
 * buffer retention across all interleavings, and scrubbing on malformed !ok() frames.
 */
public final class VisionSessionHandoffTest {
    private static final String PKG = "it.mediaset.infinitytv";
    private static final String UI = "{\"active_package\":\"it.mediaset.infinitytv\"}";
    private static int checks = 0;

    private static void verify(boolean cond, String msg) {
        checks++;
        if (!cond) throw new AssertionError(msg);
    }

    private static boolean allZero(byte[] buf) {
        if (buf == null) return true;
        for (byte b : buf) {
            if (b != 0) return false;
        }
        return true;
    }

    private static byte[] sampleJpeg() {
        return new byte[] { (byte) 0xFF, (byte) 0xD8, (byte) 0xFF, (byte) 0xE0, 0x11, 0x22, 0x33, (byte) 0xFF, (byte) 0xD9 };
    }

    public static void main(String[] args) throws Exception {
        Context ctx = new Context() {};
        boolean prevStrict = AkaiAiController.isStrictLocalOnly();
        AkaiAiController.setStrictLocalOnly(false);

        final AtomicInteger uploadCalls = new AtomicInteger(0);
        final AtomicBoolean sawNonZeroAtUpload = new AtomicBoolean(false);
        final AtomicBoolean consentFlag = new AtomicBoolean(true);
        final Runnable[] duringUploadHook = new Runnable[1];

        AiProviderAdapter mockAdapter = new AiProviderAdapter(ctx) {
            @Override public boolean hasCloudContextConsent() { return consentFlag.get(); }
            @Override
            public VisionCloudResult describeScreenJpegOnce(byte[] jpegBytes, int width, int height,
                    boolean userApprovedVisionThisTask, boolean androidProjectionActive,
                    boolean sensitiveScreenDetected) {
                uploadCalls.incrementAndGet();
                sawNonZeroAtUpload.set(jpegBytes != null && !allZero(jpegBytes));
                if (duringUploadHook[0] != null) {
                    duringUploadHook[0].run();
                }
                return VisionCloudResult.describedForTest("Schermata test valida", 18, 0.001);
            }
        };

        VisualObservationProvider.Session dummyProviderSession = new VisualObservationProvider.Session() {
            @Override
            public VisualObservationProvider.Result observe(String provider, String expectedPackage,
                    String expectedUiContext, VisualObservationProvider.Cancellation cancel) {
                return VisualObservationProvider.Result.unavailable("UNUSED");
            }
        };

        try {
            // =================================================================
            // (1) Callback before timeout: normal delivery + JPEG zeroed in finally
            // =================================================================
            SystemClock.resetForTest();
            VisualObservationProvider.stopAndRevoke();
            verify(VisualObservationProvider.install(dummyProviderSession), "(1) install provider session");
            VisualProjectionService.setSessionActiveForTest(true);
            uploadCalls.set(0);
            sawNonZeroAtUpload.set(false);
            final byte[] jpeg1 = sampleJpeg();
            final VisualProjectionService.FrameResult frame1 = new VisualProjectionService.FrameResult(
                    jpeg1, 960, 540, "deepseek", PKG, UI, 1_700_000_000_000L, null);
            VisualProjectionService.setRequestHandlerForTest(new VisualProjectionService.RequestHandler() {
                @Override
                public boolean onRequest(String expectedProvider, VisualProjectionService.FrameCallback callback) {
                    callback.onFrame(frame1);
                    return true;
                }
            });
            VisionSessionCoordinator.Observation obs1 = VisionSessionCoordinator.observe(
                    ctx, mockAdapter, "deepseek", PKG, UI, null);
            verify(obs1.usable, "(1) callback before timeout produces usable observation");
            verify(uploadCalls.get() == 1 && sawNonZeroAtUpload.get(), "(1) upload received non-zero JPEG bytes");
            verify(allZero(jpeg1), "(1) JPEG buffer zeroed immediately after observe()");

            // =================================================================
            // (2) Timeout before callback: late callback scrubs JPEG immediately
            // =================================================================
            SystemClock.resetForTest();
            uploadCalls.set(0);
            final byte[] jpeg2 = sampleJpeg();
            final VisualProjectionService.FrameResult frame2 = new VisualProjectionService.FrameResult(
                    jpeg2, 960, 540, "deepseek", PKG, UI, 1_700_000_000_000L, null);
            final AtomicReference<VisualProjectionService.FrameCallback> lateCb2 = new AtomicReference<>();
            VisualProjectionService.setRequestHandlerForTest(new VisualProjectionService.RequestHandler() {
                @Override
                public boolean onRequest(String expectedProvider, VisualProjectionService.FrameCallback callback) {
                    lateCb2.set(callback);
                    SystemClock.advanceElapsedRealtimeForTest(5000L);
                    return true;
                }
            });
            VisionSessionCoordinator.Observation obs2 = VisionSessionCoordinator.observe(
                    ctx, mockAdapter, "deepseek", PKG, UI, null);
            verify(!obs2.usable && "FRAME_TIMEOUT".equals(obs2.reason), "(2) timed out cleanly");
            verify(uploadCalls.get() == 0, "(2) zero upload calls on timeout");
            lateCb2.get().onFrame(frame2);
            verify(allZero(jpeg2), "(2) late callback after timeout immediately scrubs JPEG bytes");

            // =================================================================
            // (3a) Exact #7088137907 Race 1: callback enters offer() and pauses
            //      before lock while timeout closes handoff, then callback resumes
            // =================================================================
            SystemClock.resetForTest();
            uploadCalls.set(0);
            final byte[] jpeg3a = sampleJpeg();
            final VisualProjectionService.FrameResult frame3a = new VisualProjectionService.FrameResult(
                    jpeg3a, 960, 540, "deepseek", PKG, UI, 1_700_000_000_000L, null);
            final CountDownLatch cbEntered3a = new CountDownLatch(1);
            final CountDownLatch allowLock3a = new CountDownLatch(1);
            final VisionSessionCoordinator.FrameHandoff handoff3a =
                    new VisionSessionCoordinator.FrameHandoff(new Runnable() {
                        @Override public void run() {
                            cbEntered3a.countDown();
                            try { allowLock3a.await(5, TimeUnit.SECONDS); }
                            catch (InterruptedException e) { Thread.currentThread().interrupt(); }
                        }
                    }, null);
            Thread worker3a = new Thread(new Runnable() {
                @Override public void run() {
                    handoff3a.offer(frame3a);
                }
            });
            worker3a.start();
            verify(cbEntered3a.await(5, TimeUnit.SECONDS), "(3a) worker entered offer()");
            // Timeout thread closes and scrubs while worker is paused inside offer()
            verify(handoff3a.finishOrClose(false) == null, "(3a) timeout closes handoff");
            allowLock3a.countDown();
            worker3a.join(5000L);
            verify(!worker3a.isAlive(), "(3a) worker finished");
            verify(allZero(jpeg3a), "(3a) racing callback JPEG scrubbed when timeout closed first");
            verify(!handoff3a.hasRetainedFrame() && handoff3a.isClosed(), "(3a) zero retained FrameResult in slot");

            // =================================================================
            // (3b) Exact #7088137907 Race 2: callback acquires lock and stores slot,
            //      pauses before latch.countDown() while timeout runs finishOrClose(false)
            //      in VisionSessionCoordinator.observe()
            // =================================================================
            SystemClock.resetForTest();
            uploadCalls.set(0);
            final byte[] jpeg3b = sampleJpeg();
            final VisualProjectionService.FrameResult frame3b = new VisualProjectionService.FrameResult(
                    jpeg3b, 960, 540, "deepseek", PKG, UI, 1_700_000_000_000L, null);
            final CountDownLatch publishedSlot3b = new CountDownLatch(1);
            final CountDownLatch allowCountDown3b = new CountDownLatch(1);
            VisionSessionCoordinator.setNextOfferHooksForTest(null, new Runnable() {
                @Override public void run() {
                    publishedSlot3b.countDown();
                    try { allowCountDown3b.await(5, TimeUnit.SECONDS); }
                    catch (InterruptedException e) { Thread.currentThread().interrupt(); }
                }
            });
            final AtomicReference<Thread> workerRef3b = new AtomicReference<>();
            VisualProjectionService.setRequestHandlerForTest(new VisualProjectionService.RequestHandler() {
                @Override
                public boolean onRequest(String expectedProvider, final VisualProjectionService.FrameCallback callback) {
                    Thread t = new Thread(new Runnable() {
                        @Override public void run() {
                            callback.onFrame(frame3b);
                        }
                    });
                    workerRef3b.set(t);
                    t.start();
                    try { publishedSlot3b.await(5, TimeUnit.SECONDS); }
                    catch (InterruptedException e) { Thread.currentThread().interrupt(); }
                    // Force timeout while callback is paused after storing slot but before latch.countDown()
                    SystemClock.advanceElapsedRealtimeForTest(5000L);
                    return true;
                }
            });
            VisionSessionCoordinator.Observation obs3b = VisionSessionCoordinator.observe(
                    ctx, mockAdapter, "deepseek", PKG, UI, null);
            allowCountDown3b.countDown();
            workerRef3b.get().join(5000L);
            verify(!obs3b.usable && "FRAME_TIMEOUT".equals(obs3b.reason), "(3b) coordinator returned FRAME_TIMEOUT");
            verify(uploadCalls.get() == 0, "(3b) zero uploads on raced timeout");
            verify(allZero(jpeg3b), "(3b) slot-published JPEG scrubbed by finishOrClose(false)");

            // =================================================================
            // (4) STOP / cancellation during wait: returns TASK_CANCELLED & scrubs JPEG
            // =================================================================
            SystemClock.resetForTest();
            uploadCalls.set(0);
            final byte[] jpeg4 = sampleJpeg();
            final VisualProjectionService.FrameResult frame4 = new VisualProjectionService.FrameResult(
                    jpeg4, 960, 540, "deepseek", PKG, UI, 1_700_000_000_000L, null);
            final AtomicBoolean cancelled4 = new AtomicBoolean(false);
            VisualProjectionService.setRequestHandlerForTest(new VisualProjectionService.RequestHandler() {
                @Override
                public boolean onRequest(String expectedProvider, VisualProjectionService.FrameCallback callback) {
                    cancelled4.set(true);
                    callback.onFrame(frame4);
                    return true;
                }
            });
            VisionSessionCoordinator.Observation obs4 = VisionSessionCoordinator.observe(
                    ctx, mockAdapter, "deepseek", PKG, UI, new VisionSessionCoordinator.Cancellation() {
                        @Override public boolean isCancelled() { return cancelled4.get(); }
                    });
            verify(!obs4.usable && "TASK_CANCELLED".equals(obs4.reason), "(4) STOP during wait returns TASK_CANCELLED");
            verify(uploadCalls.get() == 0, "(4) zero upload calls after STOP");
            verify(allZero(jpeg4), "(4) delivered frame JPEG scrubbed when STOP cancelled wait");

            // =================================================================
            // (5) Malformed FrameResult with jpeg != null AND error != null (!frame.ok())
            // =================================================================
            SystemClock.resetForTest();
            uploadCalls.set(0);
            final byte[] jpeg5 = sampleJpeg();
            final VisualProjectionService.FrameResult malformed5 = new VisualProjectionService.FrameResult(
                    jpeg5, 960, 540, "deepseek", PKG, UI, 1_700_000_000_000L, "MALFORMED_FRAME_WITH_BYTES");
            verify(!malformed5.ok(), "(5) malformed frame has !ok()");
            VisualProjectionService.setRequestHandlerForTest(new VisualProjectionService.RequestHandler() {
                @Override
                public boolean onRequest(String expectedProvider, VisualProjectionService.FrameCallback callback) {
                    callback.onFrame(malformed5);
                    return true;
                }
            });
            VisionSessionCoordinator.Observation obs5 = VisionSessionCoordinator.observe(
                    ctx, mockAdapter, "deepseek", PKG, UI, null);
            verify(!obs5.usable && "MALFORMED_FRAME_WITH_BYTES".equals(obs5.reason),
                    "(5) malformed frame denied with its error reason");
            verify(uploadCalls.get() == 0, "(5) malformed frame never uploaded");
            verify(allZero(jpeg5), "(5) malformed frame with non-null jpeg scrubbed on early !ok() return");

            // =================================================================
            // (6) Double callback: second duplicate frame scrubbed immediately, first consumed & scrubbed
            // =================================================================
            SystemClock.resetForTest();
            uploadCalls.set(0);
            final byte[] jpeg6First = sampleJpeg();
            final byte[] jpeg6Dup = sampleJpeg();
            final VisualProjectionService.FrameResult frame6First = new VisualProjectionService.FrameResult(
                    jpeg6First, 960, 540, "deepseek", PKG, UI, 1_700_000_000_000L, null);
            final VisualProjectionService.FrameResult frame6Dup = new VisualProjectionService.FrameResult(
                    jpeg6Dup, 960, 540, "deepseek", PKG, UI, 1_700_000_000_000L, null);
            VisualProjectionService.setRequestHandlerForTest(new VisualProjectionService.RequestHandler() {
                @Override
                public boolean onRequest(String expectedProvider, VisualProjectionService.FrameCallback callback) {
                    callback.onFrame(frame6First);
                    callback.onFrame(frame6Dup);
                    verify(allZero(jpeg6Dup), "(6) duplicate callback JPEG scrubbed synchronously on arrival");
                    return true;
                }
            });
            VisionSessionCoordinator.Observation obs6 = VisionSessionCoordinator.observe(
                    ctx, mockAdapter, "deepseek", PKG, UI, null);
            verify(obs6.usable && uploadCalls.get() == 1, "(6) first callback consumed once");
            verify(allZero(jpeg6First) && allZero(jpeg6Dup), "(6) both first and duplicate JPEGs zeroed");

            // =================================================================
            // (7) Revocation before & during upload: 0 describeScreenJpegOnce after revoke, JPEG scrubbed
            // =================================================================
            SystemClock.resetForTest();
            uploadCalls.set(0);
            final byte[] jpeg7a = sampleJpeg();
            final VisualProjectionService.FrameResult frame7a = new VisualProjectionService.FrameResult(
                    jpeg7a, 960, 540, "deepseek", PKG, UI, 1_700_000_000_000L, null);
            VisualProjectionService.setRequestHandlerForTest(new VisualProjectionService.RequestHandler() {
                @Override
                public boolean onRequest(String expectedProvider, VisualProjectionService.FrameCallback callback) {
                    callback.onFrame(frame7a);
                    // Revoke session right before coordinator checks pre-upload guard
                    VisualProjectionService.setSessionActiveForTest(false);
                    return true;
                }
            });
            VisionSessionCoordinator.Observation obs7a = VisionSessionCoordinator.observe(
                    ctx, mockAdapter, "deepseek", PKG, UI, null);
            verify(!obs7a.usable && "SESSION_REVOKED_BEFORE_UPLOAD".equals(obs7a.reason),
                    "(7a) revocation before upload blocks cloud call");
            verify(uploadCalls.get() == 0, "(7a) describeScreenJpegOnce never called after revocation");
            verify(allZero(jpeg7a), "(7a) JPEG scrubbed when revoked before upload");

            // (7b) Revocation during upload (describeScreenJpegOnce in flight)
            VisualProjectionService.setSessionActiveForTest(true);
            uploadCalls.set(0);
            final byte[] jpeg7b = sampleJpeg();
            final VisualProjectionService.FrameResult frame7b = new VisualProjectionService.FrameResult(
                    jpeg7b, 960, 540, "deepseek", PKG, UI, 1_700_000_000_000L, null);
            VisualProjectionService.setRequestHandlerForTest(new VisualProjectionService.RequestHandler() {
                @Override
                public boolean onRequest(String expectedProvider, VisualProjectionService.FrameCallback callback) {
                    callback.onFrame(frame7b);
                    return true;
                }
            });
            duringUploadHook[0] = new Runnable() {
                @Override public void run() {
                    VisualProjectionService.setSessionActiveForTest(false);
                }
            };
            VisionSessionCoordinator.Observation obs7b = VisionSessionCoordinator.observe(
                    ctx, mockAdapter, "deepseek", PKG, UI, null);
            duringUploadHook[0] = null;
            verify(!obs7b.usable && "SESSION_REVOKED_DURING_OBSERVATION".equals(obs7b.reason),
                    "(7b) revocation during upload discards cloud observation");
            verify(allZero(jpeg7b), "(7b) JPEG scrubbed when revoked during upload");
        } finally {
            duringUploadHook[0] = null;
            VisionSessionCoordinator.setNextOfferHooksForTest(null, null);
            VisualProjectionService.setRequestHandlerForTest(null);
            VisualProjectionService.setSessionActiveForTest(false);
            VisualObservationProvider.stopAndRevoke();
            SystemClock.resetForTest();
            AkaiAiController.setStrictLocalOnly(prevStrict);
        }

        System.out.println("VisionSessionHandoffTest PASS: " + checks
                + " assertions (linearizable handoff, 6 interleavings, !ok() scrub & 0 retained buffers).");
    }
}
