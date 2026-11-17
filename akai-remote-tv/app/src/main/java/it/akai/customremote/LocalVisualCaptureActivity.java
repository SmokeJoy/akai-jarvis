package it.akai.customremote;

import android.app.Activity;
import android.app.AlertDialog;
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
import it.akai.customremote.ai.AiProviderAdapter;
import it.akai.customremote.ai.CloudProviderPolicy;
import it.akai.customremote.ai.VisualObservationBridge;

import java.nio.ByteBuffer;
import java.io.ByteArrayOutputStream;
import java.util.Arrays;

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
    private Button cloudVisionButton;
    private TextView cloudVisionResult;
    private volatile boolean cloudVisionInFlight = false;
    private boolean capturedNonSensitiveFrame = false;
    private String capturedForegroundPackage;
    private String capturedRedactedUiContext;
    private long capturedFrameTimeMs;
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

        // Deliberate second consent, separate from the Android screen capture
        // grant. Never automatically uploads a screenshot or runs a local LLM.
        cloudVisionButton = new Button(this);
        cloudVisionButton.setText("Analizza con DeepSeek/Kimi (consenso cloud separato)");
        cloudVisionButton.setEnabled(false);
        content.addView(cloudVisionButton);
        cloudVisionButton.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { confirmCloudVision(); }
        });

        cloudVisionResult = new TextView(this);
        cloudVisionResult.setTextColor(Color.LTGRAY);
        cloudVisionResult.setTextSize(13);
        cloudVisionResult.setPadding(0, pad / 2, 0, pad / 2);
        content.addView(cloudVisionResult);

        Button returnButton = new Button(this);
        returnButton.setText("Torna alla TV (usa JARVIS entro 45 secondi)");
        content.addView(returnButton);
        returnButton.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                moveTaskToBack(true); // backend service and pending hint remain, no new install
            }
        });

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
            final ScreenPerceptionEngine.PerceptionSnapshot sourceSnapshot =
                    ScreenPerceptionEngine.capture(this);
            if (!VisionCapturePolicy.mayCapture(true, sourceSnapshot)) {
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
            final String imagePackage = sourceSnapshot.foregroundPackage;
            final String imageContext = sourceSnapshot.toRedactedMinimalContextPrompt();
            final long imageTimeMs = System.currentTimeMillis();
            ui.post(new Runnable() {
                @Override public void run() {
                    finishCapture(result, dark
                            ? "Fotogramma acquisito, ma quasi nero: possibile DRM o schermata protetta."
                            : "Fotogramma acquisito SOLO in RAM. Nessuna API chiamata.");
                    if (!dark && previewBitmap == result) {
                        capturedForegroundPackage = imagePackage;
                        capturedRedactedUiContext = imageContext;
                        capturedFrameTimeMs = imageTimeMs;
                    }
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
            capturedNonSensitiveFrame = !isMostlyBlack(image);
            cloudVisionButton.setEnabled(capturedNonSensitiveFrame && !cloudVisionInFlight);
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

    /**
     * UI-only diagnostic: explicit separate permission BEFORE any image is
     * transferred to the selected DeepSeek or Kimi API. The AI response is
     * displayed as untrusted text and NEVER executed as a TV command.
     */
    private void confirmCloudVision() {
        if (destroyed || !completed || !capturedNonSensitiveFrame || previewBitmap == null
                || cloudVisionInFlight) return;
        final AiProviderAdapter adapter = new AiProviderAdapter(getApplicationContext());
        final String provider = adapter.getActiveProvider();
        if (!CloudProviderPolicy.isSupportedCloudProvider(provider)) {
            status.setText("Seleziona DeepSeek o Kimi. Nessun modello AI locale.");
            return;
        }
        if (!adapter.hasCloudContextConsent()) {
            status.setText("Consenso dati AI cloud disabilitato. Attivalo nelle impostazioni JARVIS.");
            return;
        }
        new AlertDialog.Builder(this)
                .setTitle("Invio volontario immagine a " + provider)
                .setMessage("Stai per inviare UN fotogramma della TV a " + provider
                        + " tramite API esterna. Non inviare account, messaggi privati,"
                        + " password, PIN, QR, pagamenti o dati personali."
                        + " La richiesta puo' consumare credito API."
                        + " Il risultato non eseguira' comandi automaticamente. Confermi?")
                .setNegativeButton("Annulla", null)
                .setPositiveButton("Confermo l'invio", new android.content.DialogInterface.OnClickListener() {
                    @Override public void onClick(android.content.DialogInterface dialog, int which) {
                        sendCloudVisionOnce(adapter);
                    }
                })
                .show();
    }

    private void sendCloudVisionOnce(final AiProviderAdapter adapter) {
        if (destroyed || previewBitmap == null || !capturedNonSensitiveFrame
                || cloudVisionInFlight) return;
        // JPEG encoding operates locally and never persists to filesystem.
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        if (!previewBitmap.compress(Bitmap.CompressFormat.JPEG, 58, out)) {
            status.setText("Errore di compressione JPEG.");
            return;
        }
        final byte[] jpeg = out.toByteArray();
        final int width = previewBitmap.getWidth();
        final int height = previewBitmap.getHeight();
        cloudVisionInFlight = true;
        cloudVisionButton.setEnabled(false);
        captureButton.setEnabled(false);
        status.setText("Invio volontario a DeepSeek/Kimi, attesa risposta...");
        new Thread(new Runnable() {
            @Override public void run() {
                AiProviderAdapter.VisionCloudResult result;
                try {
                    result = adapter.describeScreenJpegOnce(jpeg, width, height,
                            true, true, false);
                } catch (Exception ignored) {
                    result = AiProviderAdapter.VisionCloudResult.blocked("REQUEST_FAILED");
                } finally {
                    Arrays.fill(jpeg, (byte) 0);
                }
                final AiProviderAdapter.VisionCloudResult answer = result;
                ui.post(new Runnable() {
                    @Override public void run() {
                        cloudVisionInFlight = false;
                        if (destroyed) return;
                        captureButton.setEnabled(true);
                        cloudVisionButton.setEnabled(previewBitmap != null && capturedNonSensitiveFrame);
                        if (answer.success) {
                            boolean prepared = VisualObservationBridge.publish(
                                    adapter.getActiveProvider(), capturedForegroundPackage,
                                    capturedRedactedUiContext, answer.description,
                                    capturedFrameTimeMs, System.currentTimeMillis());
                            cloudVisionResult.setText(answer.description);
                            if (!prepared) status.setText("Descrizione visiva disponibile, ma troppo vecchia o senza origine verificabile: non utilizzabile nel planner.");
                            if (prepared) status.setText("Descrizione cloud pronta per un SOLO piano JARVIS sulla stessa schermata (45s). "
                                    + "Non autorizza clic non visibili. Token: " + answer.tokens);
                        } else {
                            status.setText("Analisi non eseguita: " + answer.error);
                        }
                    }
                });
            }
        }, "jarvis-approved-cloud-vision").start();
    }

    private void clearPreview() {
        capturedNonSensitiveFrame = false;
        capturedForegroundPackage = null;
        capturedRedactedUiContext = null;
        capturedFrameTimeMs = 0L;
        VisualObservationBridge.clear();
        if (cloudVisionButton != null) cloudVisionButton.setEnabled(false);
        if (cloudVisionResult != null) cloudVisionResult.setText("");
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
        // Android may destroy this Activity after user returns to the TV app;
        // discard pixels but keep the explicit 45s one-shot observation.
        if (preview != null) preview.setImageBitmap(null);
        if (previewBitmap != null) {
            previewBitmap.recycle();
            previewBitmap = null;
        }
        super.onDestroy();
    }
}
