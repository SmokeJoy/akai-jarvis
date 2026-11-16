package it.akai.customremote;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.os.Bundle;
import android.os.CountDownTimer;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.KeyEvent;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.ImageView;
import android.widget.TextView;

import it.akai.customremote.qr.QrBitmapUtil;

public class PinActivity extends Activity {
    private static final String TAG = "AKAI_PinActivity";
    private static PinActivity sInstance = null;

    private CountDownTimer timer;
    private Button btnClose;

    public static synchronized void launch(Context context, String pin, int durationSeconds, String serverUrl) {
        launch(context, pin, durationSeconds, serverUrl, null);
    }

    public static synchronized void launch(Context context, String pin, int durationSeconds, String serverUrl, String caFingerprint) {
        try {
            Intent intent = new Intent(context, PinActivity.class);
            intent.putExtra("pin", pin);
            intent.putExtra("duration", durationSeconds);
            intent.putExtra("serverUrl", serverUrl);
            intent.putExtra("caFingerprint", caFingerprint);
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP);
            context.startActivity(intent);
        } catch (Exception e) {
            Log.e(TAG, "Error launching PinActivity: " + e.getMessage());
        }
    }

    public static synchronized void dismiss() {
        Handler mainHandler = new Handler(Looper.getMainLooper());
        mainHandler.post(new Runnable() {
            @Override
            public void run() {
                if (sInstance != null && !sInstance.isFinishing()) {
                    sInstance.finish();
                }
            }
        });
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        sInstance = this;
        requestWindowFeature(Window.FEATURE_NO_TITLE);
        setContentView(R.layout.dialog_pin);

        Window window = getWindow();
        if (window != null) {
            window.setLayout(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT);
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        }

        View backdrop = findViewById(R.id.pin_backdrop);
        if (backdrop != null) {
            backdrop.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    finish();
                }
            });
        }

        handleIntent(getIntent());
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        handleIntent(intent);
    }

    private void handleIntent(Intent intent) {
        if (intent == null) return;

        RemoteServerService s = RemoteServerService.getInstance();
        if (s == null || !s.isReady() || s.getSecurityManager() == null) {
            Log.w(TAG, "PinActivity invocata ma il server non è pronto. Chiusura di sicurezza fail-closed.");
            finish();
            return;
        }

        // Validazione rigorosa: il PIN mostrato deve provenire esclusivamente dallo stato interno del SecurityManager
        String realPin = s.getSecurityManager().getCurrentPin();
        if (realPin == null || realPin.trim().isEmpty() || realPin.length() < 6) {
            Log.w(TAG, "Nessun PIN attivo nel SecurityManager del server. Chiusura di sicurezza.");
            finish();
            return;
        }

        int duration = s.getSecurityManager().getPinRemainingSeconds();
        if (duration <= 0) duration = 120;

        String ip = s.getLocalIpAddress();
        String serverUrl = "https://" + ip + ":" + RemoteServerService.HTTPS_PORT + "/";

        TlsCertificateManager.TlsInfo info = TlsCertificateManager.getInstance().getOrGenerateTlsInfo(this, ip);
        String caFingerprint = (info != null) ? info.caFingerprintSha256 : null;

        TextView tvPin = findViewById(R.id.tv_pin_code);
        final TextView tvCountdown = findViewById(R.id.tv_countdown);
        TextView tvUrl = findViewById(R.id.tv_dialog_url);
        TextView tvCaFp = findViewById(R.id.tv_ca_fingerprint);
        TextView tvBootstrapHint = findViewById(R.id.tv_ca_bootstrap_hint);
        ImageView ivQr = findViewById(R.id.iv_qr_code);
        btnClose = findViewById(R.id.btn_close_dialog);

        if (tvBootstrapHint != null) {
            String caUrl = "http://" + ip + ":" + RemoteServerService.HTTP_PORT + "/api/auth/ca.crt";
            tvBootstrapHint.setText("Primo accesso? Scarica prima la Root CA da:\n" + caUrl);
        }

        if (realPin != null && realPin.length() >= 6 && tvPin != null) {
            tvPin.setText(realPin.substring(0, 3) + " " + realPin.substring(3));
        }

        if (tvCaFp != null) {
            if (caFingerprint != null && !caFingerprint.isEmpty()) {
                tvCaFp.setVisibility(View.VISIBLE);
                tvCaFp.setText("Impronta Sicurezza CA (SHA-256):\n" + caFingerprint);
            } else {
                tvCaFp.setVisibility(View.GONE);
            }
        }

        if (tvUrl != null) {
            tvUrl.setText(serverUrl);
        }

        if (ivQr != null) {
            Bitmap bmp = QrBitmapUtil.createQrBitmap(serverUrl, 6, 2);
            if (bmp != null) {
                ivQr.setImageBitmap(bmp);
            }
        }

        if (btnClose != null) {
            btnClose.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    finish();
                }
            });
            btnClose.requestFocus();
        }

        if (timer != null) {
            timer.cancel();
            timer = null;
        }

        timer = new CountDownTimer(duration * 1000L, 1000) {
            @Override
            public void onTick(long millisUntilFinished) {
                if (tvCountdown != null) {
                    tvCountdown.setText("Scade tra " + (millisUntilFinished / 1000) + "s");
                }
            }

            @Override
            public void onFinish() {
                finish();
            }
        }.start();
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        if (event.getAction() == KeyEvent.ACTION_DOWN) {
            if (event.getKeyCode() == KeyEvent.KEYCODE_BACK || event.getKeyCode() == KeyEvent.KEYCODE_HOME) {
                finish();
                return true;
            }
        }
        return super.dispatchKeyEvent(event);
    }

    @Override
    public void onBackPressed() {
        super.onBackPressed();
        finish();
    }

    @Override
    protected void onPause() {
        super.onPause();
        // Se perde il focus o l'utente torna alla home/altra app, chiudi immediatamente
        if (!isFinishing()) {
            finish();
        }
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (timer != null) {
            timer.cancel();
            timer = null;
        }
        if (sInstance == this) {
            sInstance = null;
        }
    }
}
