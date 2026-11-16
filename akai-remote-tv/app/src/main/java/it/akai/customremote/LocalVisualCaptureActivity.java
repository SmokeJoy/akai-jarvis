package it.akai.customremote;

import android.app.Activity;
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
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.os.SystemClock;
import android.util.DisplayMetrics;
import android.view.View;
import android.widget.Button;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import it.akai.customremote.ai.ScreenPerceptionEngine;
import it.akai.customremote.ai.VisionCapturePolicy;
import it.akai.customremote.ai.RgbaFramePacker;

import java.nio.ByteBuffer;

/**
 * Android 9 / API 28 local-only MediaProjection diagnostic.
 *
 * One explicit user press -> one Android system consent dialog -> one
 * small in-memory frame -> all MediaProjection resources released.
 * Never writes an image to disk, serves it on HTTP, or invokes cloud APIs.
 */
public final class LocalVisualCaptureActivity extends Activity {
    private static final int REQUEST_SCREEN = 718;
    private static final long TIMEOUT_MS = 4000L;
    private final Handler ui = new Handler(Looper.getMainLooper());

    private Button captureButton;
    private TextView status;
    private ImageView preview;
    private Bitmap previewBitmap;

    private MediaProjectionManager projectionManager;
    private MediaProjection projection;
    private VirtualDisplay virtualDisplay;
    private ImageReader reader;
    private HandlerThread captureThread;
    private Handler captureHandler;
    private Runnable timeout;
    private final java.util.concurrent.atomic.AtomicBoolean frameQueued = new java.util.concurrent.atomic.AtomicBoolean(false);
    private volatile boolean completed = true;
    private volatile boolean destroyed = false;
    private long startedAt;
    private int frameWidth;
    private int frameHeight;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        setTitle("JARVIS - visione locale di prova");
        int pad = (int) (20f * getResources().getDisplayMetrics().density);
        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(pad, pad, pad, pad);
        content.setBackgroundColor(Color.rgb(12, 16, 26));
        ScrollView scroll = new ScrollView(this);
        scroll.addView(content);
        setContentView(scroll);

        TextView heading = new TextView(this);
        heading.setText("JARVIS A2 - Cattura locale dello schermo");
        heading.setTextSize(20);
        heading.setTextColor(Color.WHITE);
        content.addView(heading);

        TextView privacy = new TextView(this);
        privacy.setText("Test volontario: Android chiede il consenso. La TV cattura UN SOLO fotogramma dopo aver nascosto questa schermata. L'immagine resta soltanto nella memoria della TV: nessun salvataggio, invio a DeepSeek/Kimi o condivisione LAN. Per annullare, rifiuta il consenso.");
        privacy.setTextColor(Color.LTGRAY);
        privacy.setTextSize(14);
        privacy.setPadding(0, pad / 2, 0, pad / 2);
        content.addView(privacy);

        captureButton = new Button(this);
        captureButton.setText("Cattura 1 fotogramma (consenso Android)");
        content.addView(captureButton);
        captureButton.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                requestProjection();
            }
        });

        status = new TextView(this);
        status.setText("Nessuna cattura attiva");
        status.setTextColor(Color.rgb(125, 211, 252));
        status.setTextSize(15);
        status.setPadding(0, pad / 2, 0, pad / 2);
        content.addView(status);

        preview = new ImageView(this);
        preview.setAdjustViewBounds(true);
        preview.setMaxWidth(960);
        preview.setMaxHeight(540);
        content.addView(preview);

        Button clearButton = new Button(this);
        clearButton.setText("Cancella anteprima e chiudi");
        content.addView(clearButton);
        clearButton.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                clearPreview();
                finish();
            }
        });
    }

    private void requestProjection() {
        if (!completed || destroyed) return;
        clearPreview();
        frameQueued.set(false);
        projectionManager = (MediaProjectionManager) getSystemService(Context.MEDIA_PROJECTION_SERVICE);
        if (projectionManager == null) {
            status.setText("MediaProjection non disponibile su questa TV.");
            return;
        }
        try {
            completed = false;
            captureButton.setEnabled(false);
            status.setText("Conferma o annulla nella finestra Android...");
            startActivityForResult(projectionManager.createScreenCaptureIntent(), REQUEST_SCREEN);
        } catch (RuntimeException e) {
            completed = true;
            captureButton.setEnabled(true);
            status.setText("Impossibile aprire il consenso Android.");
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != REQUEST_SCREEN) return;
        if (resultCode != RESULT_OK || data == null) {
            finishCapture(null, "Cattura annullata: nessun consenso.");
            return;
        }
        // Reveal the underlying TV app rather than capturing our own settings/PIN UI.
        status.setText("Consenso ricevuto. Osservazione locale singola...");
        moveTaskToBack(true);
        final Intent grant = data;
        ui.postDelayed(new Runnable() {
            @Override public void run() {
                startOneShotCapture(grant);
            }
        }, 400L);
    }

    private void startOneShotCapture(Intent grant) {
        if (destroyed || completed) return;
        ScreenPerceptionEngine.PerceptionSnapshot snap = ScreenPerceptionEngine.capture(this);
        if (!VisionCapturePolicy.mayCapture(true, snap)) {
            finishCapture(null, "Cattura bloccata: interfaccia sensibile o schermata non osservabile.");
            return;
        }
        try {
            DisplayMetrics metrics = new DisplayMetrics();
            getWindowManager().getDefaultDisplay().getRealMetrics(metrics);
            float scale = Math.min(1.0f,
                    Math.min(960f / Math.max(1, metrics.widthPixels),
                             540f / Math.max(1, metrics.heightPixels)));
            frameWidth = Math.max(1, Math.round(metrics.widthPixels * scale));
            frameHeight = Math.max(1, Math.round(metrics.heightPixels * scale));
            if (!VisionCapturePolicy.withinBudget(frameWidth, frameHeight, 0)) {
                finishCapture(null, "Dimensioni fotogramma non consentite.");
                return;
            }
            projection = projectionManager.getMediaProjection(RESULT_OK, grant);
            if (projection == null) {
                finishCapture(null, "Android non ha concesso la proiezione.");
                return;
            }
            projection.registerCallback(new MediaProjection.Callback() {
                @Override public void onStop() {
                    ui.post(new Runnable() {
                        @Override public void run() {
                            if (!completed) finishCapture(null, "Proiezione interrotta dal sistema.");
                        }
                    });
                }
            }, ui);

            captureThread = new HandlerThread("jarvis-one-frame");
            captureThread.start();
            captureHandler = new Handler(captureThread.getLooper());
            reader = ImageReader.newInstance(frameWidth, frameHeight, PixelFormat.RGBA_8888, 2);
            startedAt = SystemClock.elapsedRealtime();
            reader.setOnImageAvailableListener(new ImageReader.OnImageAvailableListener() {
                @Override public void onImageAvailable(ImageReader source) {
                    consumeFrame(source);
                }
            }, captureHandler);
            virtualDisplay = projection.createVirtualDisplay("jarvis-local-one-frame",
                    frameWidth, frameHeight, metrics.densityDpi,
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                    reader.getSurface(), null, captureHandler);
            if (virtualDisplay == null) {
                finishCapture(null, "Display virtuale non disponibile.");
                return;
            }
            timeout = new Runnable() {
                @Override public void run() {
                    if (!completed) finishCapture(null, "Nessun fotogramma leggibile ricevuto.");
                }
            };
            ui.postDelayed(timeout, TIMEOUT_MS);
        } catch (RuntimeException e) {
            finishCapture(null, "Il firmware non ha consentito la cattura locale.");
        }
    }

    private void consumeFrame(ImageReader source) {
        Image frame = null;
        Bitmap full = null;
        try {
            frame = source.acquireLatestImage();
            if (frame == null || completed) return;
            long elapsed = SystemClock.elapsedRealtime() - startedAt;
            if (!VisionCapturePolicy.withinBudget(frameWidth, frameHeight, elapsed)) return;
            if (!VisionCapturePolicy.mayCapture(true, ScreenPerceptionEngine.capture(this))) {
                ui.post(new Runnable() {
                    @Override public void run() {
                        finishCapture(null, "Schermata sensibile rilevata; fotogramma scartato.");
                    }
                });
                return;
            }

            Image.Plane plane = frame.getPlanes()[0];
            if (!frameQueued.compareAndSet(false, true)) return;
            ByteBuffer packed = RgbaFramePacker.pack(
                    plane.getBuffer(), frameWidth, frameHeight,
                    plane.getRowStride(), plane.getPixelStride());
            full = Bitmap.createBitmap(frameWidth, frameHeight, Bitmap.Config.ARGB_8888);
            full.copyPixelsFromBuffer(packed);
            final Bitmap result = full;
            full = null;
            final boolean dark = isMostlyBlack(result);
            ui.post(new Runnable() {
                @Override public void run() {
                    finishCapture(result, dark
                            ? "Fotogramma acquisito, ma quasi nero: possibile DRM o schermata protetta."
                            : "Fotogramma acquisito SOLO in RAM. Nessuna API chiamata.");
                }
            });
        } catch (RuntimeException e) {
            ui.post(new Runnable() {
                @Override public void run() {
                    finishCapture(null, "Formato fotogramma non supportato.");
                }
            });
        } finally {
            if (full != null) full.recycle();
            if (frame != null) frame.close();
        }
    }

    private static boolean isMostlyBlack(Bitmap bitmap) {
        if (bitmap == null) return true;
        int dark = 0, samples = 0;
        for (int y = 0; y < 8; y++) {
            for (int x = 0; x < 8; x++) {
                int p = bitmap.getPixel(Math.min(bitmap.getWidth() - 1,
                                (x * bitmap.getWidth()) / 8),
                        Math.min(bitmap.getHeight() - 1, (y * bitmap.getHeight()) / 8));
                if (Color.red(p) < 12 && Color.green(p) < 12 && Color.blue(p) < 12) dark++;
                samples++;
            }
        }
        return dark >= samples * 9 / 10;
    }

    private void finishCapture(Bitmap image, String message) {
        if (destroyed || completed) {
            if (image != null) image.recycle();
            return;
        }
        completed = true;
        stopResources();
        if (image != null) {
            clearPreview();
            previewBitmap = image;
            preview.setImageBitmap(image);
        }
        status.setText(message);
        captureButton.setEnabled(true);
        // Capture was performed with this activity in the background.
        // Bring its local preview back without exposing any image to the LAN.
        try {
            Intent back = new Intent(this, LocalVisualCaptureActivity.class);
            back.addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT | Intent.FLAG_ACTIVITY_SINGLE_TOP);
            startActivity(back);
        } catch (RuntimeException ignored) {}
    }

    private void clearPreview() {
        if (preview != null) preview.setImageBitmap(null);
        if (previewBitmap != null) {
            previewBitmap.recycle();
            previewBitmap = null;
        }
    }

    private void stopResources() {
        if (timeout != null) {
            ui.removeCallbacks(timeout);
            timeout = null;
        }
        if (reader != null) {
            try { reader.setOnImageAvailableListener(null, null); } catch (Exception ignored) {}
        }
        if (virtualDisplay != null) {
            try { virtualDisplay.release(); } catch (Exception ignored) {}
            virtualDisplay = null;
        }
        if (reader != null) {
            try { reader.close(); } catch (Exception ignored) {}
            reader = null;
        }
        if (projection != null) {
            try { projection.stop(); } catch (Exception ignored) {}
            projection = null;
        }
        if (captureThread != null) {
            captureThread.quitSafely();
            captureThread = null;
            captureHandler = null;
        }
    }

    @Override
    protected void onDestroy() {
        destroyed = true;
        completed = true;
        stopResources();
        clearPreview();
        super.onDestroy();
    }
}
