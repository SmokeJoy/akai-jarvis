package it.akai.customremote;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.Image;
import android.media.ImageReader;
import android.media.projection.MediaProjection;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.os.SystemClock;
import android.util.DisplayMetrics;
import android.view.WindowManager;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;

import it.akai.customremote.ai.AiProviderAdapter;
import it.akai.customremote.ai.CloudProviderPolicy;
import it.akai.customremote.ai.RgbaFramePacker;
import it.akai.customremote.ai.ScreenPerceptionEngine;
import it.akai.customremote.ai.VisionCapturePolicy;
import it.akai.customremote.ai.VisualCaptureSessionGate;
import it.akai.customremote.ai.FrameSequenceGate;
import it.akai.customremote.ai.VisualObservationProvider;
import it.akai.customremote.ai.VisionSessionCoordinator;

/**
 * Android 9 on-demand multi-frame MediaProjection service for JARVIS.
 *
 * A single explicit OS consent -> ONE MediaProjection -> ONE VirtualDisplay.
 * Frames are extracted only when an active task requests them. No image is
 * stored or served over LAN. The notification includes a user-owned STOP.
 * Not started at boot and never restarted automatically (START_NOT_STICKY).
 *
 * The controller must separately verify DeepSeek/Kimi cloud-context consent,
 * then send each frame with describeScreenJpegOnce; this service never calls
 * AI APIs or runs any local inference model.
 */
public final class VisualProjectionService extends Service {
    public static final String ACTION_START = "it.akai.customremote.vision.START";
    public static final String ACTION_STOP = "it.akai.customremote.vision.STOP";
    public static final String EXTRA_RESULT_CODE = "result_code";
    public static final String EXTRA_GRANT = "projection_grant";
    public static final String EXTRA_PROVIDER = "cloud_provider";
    private static final String CHANNEL_ID = "jarvis_vision_session";
    private static final int NOTIFICATION_ID = 4242;
    private static final int FRAME_TIMEOUT_MS = 3800;

    public interface FrameCallback {
        void onFrame(FrameResult result);
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
        private FrameResult(byte[] jpeg, int width, int height, String provider,
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
        public boolean ok() { return jpeg != null && jpeg.length > 0 && error == null; }
        static FrameResult denied(String reason) {
            return new FrameResult(null, 0, 0, null, null, null, 0L, reason);
        }
    }

    private static volatile VisualProjectionService active;
    private HandlerThread workerThread;
    private Handler worker;
    private MediaProjection projection;
    private VirtualDisplay display;
    private ImageReader reader;
    private VisualCaptureSessionGate gate;
    private final FrameSequenceGate frameSequenceGate = new FrameSequenceGate();
    private String provider;
    private int frameWidth, frameHeight;
    private FrameCallback pending;
    private Runnable pendingTimeout;
    private Runnable expiration;
    private volatile boolean closed;
    private VisualObservationProvider.Session observationSession;

    /** The returned object lives only in this process; no result is persisted. */
    public static boolean requestFrame(final String expectedProvider, final FrameCallback callback) {
        final VisualProjectionService service = active;
        if (service == null || service.closed || service.worker == null || callback == null) return false;
        // A stopped HandlerThread may reject a post during shutdown. Do not
        // claim that a capture was queued when its Looper is already quitting.
        return service.worker.post(new Runnable() {
            @Override public void run() {
                service.requestOnWorker(expectedProvider, callback);
            }
        });
    }

    public static boolean isSessionActive() {
        VisualProjectionService s = active;
        return s != null && !s.closed && s.gate != null && s.gate.isActive();
    }

    public static void stopOwnerSession(Context ctx) {
        // Always enqueue STOP, including while START is still initializing.
        // The service may not yet have published itself in active.
        Intent stop = new Intent(ctx, VisualProjectionService.class).setAction(ACTION_STOP);
        ctx.startService(stop);
    }

    @Override public IBinder onBind(Intent intent) { return null; }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null || ACTION_STOP.equals(intent.getAction())) {
            stopCapture();
            stopSelf();
            return START_NOT_STICKY;
        }
        if (active != null && !active.closed) {
            // Repeated START must not stop the already approved session.
            return START_NOT_STICKY;
        }
        if (!ACTION_START.equals(intent.getAction())) {
            stopSelf(startId);
            return START_NOT_STICKY;
        }
        final String targetProvider = intent.getStringExtra(EXTRA_PROVIDER);
        final int resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0);
        final Intent grant = intent.getParcelableExtra(EXTRA_GRANT);
        if (!CloudProviderPolicy.isSupportedCloudProvider(targetProvider)
                || resultCode != android.app.Activity.RESULT_OK || grant == null) {
            stopSelf(startId);
            return START_NOT_STICKY;
        }
        VisualCaptureSessionGate nextGate = VisualCaptureSessionGate.begin(
                true, true, targetProvider, SystemClock.elapsedRealtime());
        if (nextGate == null) {
            stopSelf(startId);
            return START_NOT_STICKY;
        }
        closed = false;
        try {
            createForegroundNotification();
            provider = targetProvider;
            gate = nextGate;
            workerThread = new HandlerThread("jarvis-vision-frames");
            workerThread.start();
            worker = new Handler(workerThread.getLooper());
            final MediaProjectionManager mgr = (MediaProjectionManager)
                    getSystemService(Context.MEDIA_PROJECTION_SERVICE);
            if (mgr == null) throw new IllegalStateException("MediaProjectionManager unavailable");
            projection = mgr.getMediaProjection(resultCode, grant);
            if (projection == null) throw new IllegalStateException("Android projection denied");
            projection.registerCallback(new MediaProjection.Callback() {
                @Override public void onStop() {
                    Handler handler = worker;
                    // Projection revocation must terminate the service even if
                    // the frame worker is already quitting and rejects post().
                    boolean queued = handler != null && handler.post(new Runnable() {
                        @Override public void run() {
                            stopCapture();
                            stopSelf();
                        }
                    });
                    if (!queued) {
                        stopCapture();
                        stopSelf();
                    }
                }
            }, worker);
            DisplayMetrics dm = new DisplayMetrics();
            ((WindowManager) getSystemService(Context.WINDOW_SERVICE))
                    .getDefaultDisplay().getRealMetrics(dm);
            float scale = Math.min(1f,
                    Math.min(960f / Math.max(1, dm.widthPixels),
                             540f / Math.max(1, dm.heightPixels)));
            frameWidth = Math.max(1, Math.round(dm.widthPixels * scale));
            frameHeight = Math.max(1, Math.round(dm.heightPixels * scale));
            if (!VisionCapturePolicy.withinBudget(frameWidth, frameHeight, 0)) {
                throw new IllegalStateException("Frame dimensions rejected");
            }
            reader = ImageReader.newInstance(frameWidth, frameHeight,
                    PixelFormat.RGBA_8888, 2);
            reader.setOnImageAvailableListener(new ImageReader.OnImageAvailableListener() {
                @Override public void onImageAvailable(ImageReader source) {
                    consumeOnlyOnDemand(source);
                }
            }, worker);
            display = projection.createVirtualDisplay("jarvis-on-demand",
                    frameWidth, frameHeight, dm.densityDpi,
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                    null, null, worker);
            if (display == null) throw new IllegalStateException("VirtualDisplay unavailable");
            // A MediaProjection revocation can race initialization on the worker.
            // Never resurrect an already stopped session by resetting closed here.
            synchronized (this) {
                if (closed) throw new IllegalStateException("Projection revoked during startup");
                active = this;
            }
            observationSession = new VisualObservationProvider.Session() {
                @Override public void stopByOwner() {
                    VisualProjectionService.stopOwnerSession(getApplicationContext());
                }

                @Override public VisualObservationProvider.Result observe(
                        String targetProvider, String expectedPkg, String expectedUi,
                        final VisualObservationProvider.Cancellation cancel) {
                    final AiProviderAdapter adapter =
                            new AiProviderAdapter(getApplicationContext());
                    VisionSessionCoordinator.Observation result =
                            VisionSessionCoordinator.observe(
                                    getApplicationContext(), adapter, targetProvider,
                                    expectedPkg, expectedUi,
                                    new VisionSessionCoordinator.Cancellation() {
                                        @Override public boolean isCancelled() {
                                            return cancel != null && cancel.isCancelled();
                                        }
                                    });
                    return result.usable
                            ? VisualObservationProvider.Result.observed(
                                    result.provider, result.packageName,
                                    result.redactedContext, result.description,
                                    result.frameTimeMs, result.tokens, result.costEur)
                            : VisualObservationProvider.Result.unavailable(result.reason);
                }
            };
            synchronized (this) {
                if (closed) throw new IllegalStateException("Projection revoked before session install");
                if (!VisualObservationProvider.install(observationSession)) {
                    throw new IllegalStateException("A visual session is already active");
                }
            }
            expiration = new Runnable() {
                @Override public void run() {
                    stopCapture();
                    stopSelf();
                }
            };
            // Never leave an unbounded projection if shutdown rejects expiry scheduling.
            if (!worker.postDelayed(expiration, VisualCaptureSessionGate.MAX_SESSION_MS)) {
                stopCapture();
                stopSelf();
            }
        } catch (Exception failure) {
            stopCapture();
            stopSelf();
        }
        return START_NOT_STICKY;
    }

    private void createForegroundNotification() {
        NotificationManager manager = (NotificationManager)
                getSystemService(Context.NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(new NotificationChannel(CHANNEL_ID,
                    "JARVIS sessione visiva", NotificationManager.IMPORTANCE_LOW));
        }
        Intent stopIntent = new Intent(this, VisualProjectionService.class).setAction(ACTION_STOP);
        PendingIntent stop = PendingIntent.getService(this, 42, stopIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Notification.Builder notification = Build.VERSION.SDK_INT >= 26
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);
        notification.setSmallIcon(R.drawable.akai_app_icon)
                .setContentTitle("JARVIS: osservazione TV autorizzata")
                .setContentText("Screenshot solo su richiesta. Tocca Interrompi per fermare.")
                .setOngoing(true).addAction(android.R.drawable.ic_menu_close_clear_cancel,
                        "Interrompi", stop);
        startForeground(NOTIFICATION_ID, notification.build());
    }

    // A caller-provided callback must not crash the MediaProjection worker.
    private static void deliverDenied(FrameCallback callback, String reason) {
        try { callback.onFrame(FrameResult.denied(reason)); }
        catch (RuntimeException ignored) {}
    }

    // Serialize request reservation and surface attachment with STOP. Without
    // this lock, STOP can clear pending and release the display between the
    // initial closed check and pending assignment, stranding a callback.
    private synchronized void requestOnWorker(String expectedProvider, FrameCallback callback) {
        if (closed || gate == null || reader == null) {
            deliverDenied(callback, "SESSION_CLOSED");
            return;
        }
        // A second caller must never replace the first callback or its timeout.
        // Reject before reserving a frame quota: a busy request is not a capture.
        if (pending != null) {
            deliverDenied(callback, "FRAME_REQUEST_BUSY");
            return;
        }
        // OEM Accessibility and preference reads can fail during an app switch
        // or shutdown. Reject the request rather than losing its callback or
        // leaving the MediaProjection worker with an uncaught exception.
        final ScreenPerceptionEngine.PerceptionSnapshot snap;
        final boolean cloudConsent;
        try {
            snap = ScreenPerceptionEngine.capture(this);
            cloudConsent = new AiProviderAdapter(this).hasCloudContextConsent();
        } catch (RuntimeException unavailable) {
            deliverDenied(callback, "FRAME_CONTEXT_UNAVAILABLE");
            return;
        }
        boolean sensitive = snap == null || snap.hasSensitiveFields
                || !VisionCapturePolicy.mayCapture(true, snap);
        VisualCaptureSessionGate.Verdict verdict = gate.reserveNextFrame(
                expectedProvider, cloudConsent, sensitive, false, SystemClock.elapsedRealtime());
        if (!verdict.allowed) {
            deliverDenied(callback, verdict.reason);
            if (!gate.isActive()) {
                stopCapture();
                stopSelf();
            }
            return;
        }
        pending = callback;
        // Empty any older buffered image. The next frame must be fresh.
        Image stale = null;
        try {
            stale = reader.acquireLatestImage();
        } catch (RuntimeException ignored) {
        } finally {
            if (stale != null) {
                try { stale.close(); } catch (RuntimeException ignored) {}
            }
        }
        // Avoid streaming frames continuously on the low-memory ARMv7 TV.
        // A detached VirtualDisplay preserves the ONE owner-consented
        // MediaProjection session, then emits frames only for a live request.
        try {
            if (display == null) throw new IllegalStateException("DISPLAY_UNAVAILABLE");
            display.setSurface(reader.getSurface());
        } catch (RuntimeException ex) {
            finishRequest(FrameResult.denied("FRAME_SURFACE_ATTACH_FAILED"));
            return;
        }
        pendingTimeout = new Runnable() {
            @Override public void run() {
                finishRequest(FrameResult.denied("NO_NEW_FRAME_TIMEOUT"));
            }
        };
        // A shutting-down Looper may refuse the timeout. Never leave a
        // pending capture without a deadline or strand its callback.
        if (!worker.postDelayed(pendingTimeout, FRAME_TIMEOUT_MS)) {
            finishRequest(FrameResult.denied("FRAME_TIMEOUT_SCHEDULE_REJECTED"));
        }
    }

    private void consumeOnlyOnDemand(ImageReader source) {
        // Drain a rare late image after surface detachment. Holding stale
        // ImageReader buffers could block the NEXT requested frame entirely.
        if (pending == null || closed) {
            Image stale = null;
            try { stale = source.acquireLatestImage(); }
            catch (RuntimeException ignored) {}
            finally { if (stale != null) {
                try { stale.close(); } catch (RuntimeException ignored) {}
            } }
            return;
        }
        Image image = null;
        Bitmap bitmap = null;
        try {
            image = source.acquireLatestImage();
            if (image == null) return;
            // Android image timestamps are producer-specific, so compare only
            // with prior frames from THIS SAME ImageReader, never with system
            // wall/monotonic time. A buffered old/duplicate frame cannot be
            // accepted as a new screenshot after an application transition.
            // Keep the request pending for a newer frame until its timeout.
            if (!frameSequenceGate.accept(image.getTimestamp())) return;
            ScreenPerceptionEngine.PerceptionSnapshot snap = ScreenPerceptionEngine.capture(this);
            if (!VisionCapturePolicy.mayCapture(true, snap)) {
                finishRequest(FrameResult.denied("SENSITIVE_OR_UNKNOWN_SCREEN"));
                return;
            }
            Image.Plane plane = image.getPlanes()[0];
            ByteBuffer packed = RgbaFramePacker.pack(plane.getBuffer(),
                    frameWidth, frameHeight, plane.getRowStride(), plane.getPixelStride());
            bitmap = Bitmap.createBitmap(frameWidth, frameHeight, Bitmap.Config.ARGB_8888);
            bitmap.copyPixelsFromBuffer(packed);
            if (mostlyBlack(bitmap)) {
                finishRequest(FrameResult.denied("BLACK_OR_DRM_PROTECTED_FRAME"));
                return;
            }
            byte[] jpeg = null;
            for (int quality : new int[]{62, 42, 25}) {
                ByteArrayOutputStream stream = new ByteArrayOutputStream(64 * 1024);
                if (!bitmap.compress(Bitmap.CompressFormat.JPEG, quality, stream)) continue;
                byte[] candidate = stream.toByteArray();
                if (candidate.length >= 128 && candidate.length <= 256 * 1024) {
                    jpeg = candidate;
                    break;
                }
            }
            if (jpeg == null) {
                finishRequest(FrameResult.denied("JPEG_TOO_LARGE"));
                return;
            }
            finishRequest(new FrameResult(jpeg, frameWidth, frameHeight, provider,
                    snap.foregroundPackage, snap.toRedactedMinimalContextPrompt(),
                    System.currentTimeMillis(), null));
        } catch (RuntimeException failure) {
            finishRequest(FrameResult.denied("FRAME_DECODING_FAILED"));
        } finally {
            // STOP may close ImageReader concurrently on the main thread.
            // Image.close() can then throw IllegalStateException; cleanup must
            // not crash the worker or mask the cancellation result.
            if (image != null) {
                try { image.close(); } catch (RuntimeException ignored) {}
            }
            if (bitmap != null) {
                try { bitmap.recycle(); } catch (RuntimeException ignored) {}
            }
        }
    }

    private static boolean mostlyBlack(Bitmap image) {
        int dark = 0;
        for (int y = 0; y < 8; y++) {
            for (int x = 0; x < 8; x++) {
                int color = image.getPixel(Math.min(image.getWidth() - 1,
                        x * image.getWidth() / 8),
                        Math.min(image.getHeight() - 1, y * image.getHeight() / 8));
                if (Color.red(color) < 12 && Color.green(color) < 12
                        && Color.blue(color) < 12) dark++;
            }
        }
        return dark >= 56;
    }

    // Serialize completion with owner STOP: a late worker must never deliver
    // a successful frame after the session has been revoked.
    private synchronized void finishRequest(FrameResult result) {
        if (closed) return;
        FrameCallback deliver = pending;
        pending = null;
        // Stop frame production immediately after the requested image has
        // been taken, before any cloud latency or callback processing.
        if (display != null) {
            try { display.setSurface(null); }
            catch (RuntimeException ignored) {}
        }
        if (pendingTimeout != null && worker != null) {
            worker.removeCallbacks(pendingTimeout);
            pendingTimeout = null;
        }
        if (gate != null) gate.completeFrame(result.ok());
        if (deliver != null) {
            try {
                deliver.onFrame(result);
            } catch (RuntimeException ignored) {}
        }
        if (gate != null && !gate.isActive()) {
            stopCapture();
            stopSelf();
        }
    }

    // STOP can arrive on the main thread while MediaProjection.onStop or a
    // frame timeout is tearing down the same session on the worker thread.
    // Serialize teardown so VirtualDisplay/ImageReader/MediaProjection are
    // released once, and callbacks cannot race a second cleanup pass.
    private synchronized void stopCapture() {
        if (closed) return;
        closed = true;
        if (active == this) active = null;
        if (observationSession != null) {
            VisualObservationProvider.clear(observationSession);
            observationSession = null;
        }
        if (gate != null) gate.stop();
        if (worker != null) {
            if (pendingTimeout != null) worker.removeCallbacks(pendingTimeout);
            if (expiration != null) worker.removeCallbacks(expiration);
        }
        FrameCallback aborted = pending;
        pending = null;
        if (aborted != null) {
            try { aborted.onFrame(FrameResult.denied("SESSION_STOPPED")); }
            catch (RuntimeException ignored) {}
        }
        if (reader != null) {
            try { reader.setOnImageAvailableListener(null, null); } catch (Exception ignored) {}
        }
        if (display != null) {
            try { display.release(); } catch (Exception ignored) {}
            display = null;
        }
        if (reader != null) {
            try { reader.close(); } catch (Exception ignored) {}
            reader = null;
        }
        if (projection != null) {
            MediaProjection old = projection;
            projection = null;
            try { old.stop(); } catch (Exception ignored) {}
        }
        if (workerThread != null) {
            workerThread.quitSafely();
            workerThread = null;
            worker = null;
        }
        stopForeground(true);
    }

    @Override public void onDestroy() {
        stopCapture();
        super.onDestroy();
    }
}
