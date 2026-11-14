package it.akai.customremote;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import android.view.View;
import android.widget.Button;
import android.widget.ImageView;
import android.widget.TextView;
import android.widget.Toast;

import it.akai.customremote.qr.QrBitmapUtil;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class MainActivity extends Activity {
    private static final String TAG = "AKAI_MainActivity";
    private final ExecutorService bgExecutor = Executors.newSingleThreadExecutor();

    private TextView tvServiceStatus;
    private TextView tvServerUrl;
    private TextView tvUinputStatus;
    private TextView tvPairedCount;

    private TextView tvCaFingerprint;
    private TextView tvCaUrl;
    private TextView tvHttpsUrl;
    private ImageView ivQrCa;
    private ImageView ivQrHttps;

    private Button btnShowPin;
    private Button btnRevokeAll;
    private Button btnMinimize;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);
        Log.i(TAG, "MainActivity started. Launching RemoteServerService daemon.");

        tvServiceStatus = findViewById(R.id.tv_service_status);
        tvServerUrl = findViewById(R.id.tv_server_url);
        tvUinputStatus = findViewById(R.id.tv_uinput_status);
        tvPairedCount = findViewById(R.id.tv_paired_count);

        tvCaFingerprint = findViewById(R.id.tv_ca_fingerprint);
        tvCaUrl = findViewById(R.id.tv_ca_url);
        tvHttpsUrl = findViewById(R.id.tv_https_url);
        ivQrCa = findViewById(R.id.iv_qr_ca);
        ivQrHttps = findViewById(R.id.iv_qr_https);

        btnShowPin = findViewById(R.id.btn_show_pin);
        btnRevokeAll = findViewById(R.id.btn_revoke_all);
        btnMinimize = findViewById(R.id.btn_minimize);

        // Avvio del servizio autonomo in foreground
        Intent serviceIntent = new Intent(this, RemoteServerService.class);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent);
        } else {
            startService(serviceIntent);
        }

        updateUI();

        btnShowPin.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                RemoteServerService s = RemoteServerService.getInstance();
                String ip = (s != null) ? s.getLocalIpAddress() : getLocalIpAddress();
                String httpsUrl = "https://" + ip + ":" + RemoteServerService.HTTPS_PORT + "/";
                TlsCertificateManager.TlsInfo info = TlsCertificateManager.getInstance().getOrGenerateTlsInfo(MainActivity.this, ip);
                String caFp = (info != null) ? info.caFingerprintSha256 : null;

                if (s != null && s.getSecurityManager() != null) {
                    String pin = s.getSecurityManager().generateNewPin();
                    int remaining = s.getSecurityManager().getPinRemainingSeconds();
                    PinOverlayDialog.show(MainActivity.this, pin, remaining, httpsUrl, caFp);
                    Toast.makeText(MainActivity.this, "Schermata PIN aperta a schermo (valida 120s)", Toast.LENGTH_SHORT).show();
                } else {
                    SecurityManager sec = new SecurityManager(MainActivity.this);
                    String pin = sec.generateNewPin();
                    PinOverlayDialog.show(MainActivity.this, pin, 120, httpsUrl, caFp);
                    Toast.makeText(MainActivity.this, "Schermata PIN aperta a schermo (valida 120s)", Toast.LENGTH_SHORT).show();
                }
            }
        });

        btnRevokeAll.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                RemoteServerService s = RemoteServerService.getInstance();
                if (s != null && s.getSecurityManager() != null) {
                    s.getSecurityManager().revokeAll();
                    updateUI();
                    Toast.makeText(MainActivity.this, "Tutte le sessioni smartphone sono state revocate", Toast.LENGTH_SHORT).show();
                }
            }
        });

        btnMinimize.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                // Riduci a icona tornando a Home senza arrestare il server
                finish();
            }
        });
    }

    @Override
    protected void onResume() {
        super.onResume();
        updateUI();
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        try {
            bgExecutor.shutdownNow();
        } catch (Exception ignored) {}
    }

    private void updateUI() {
        RemoteServerService s = RemoteServerService.getInstance();
        boolean running = (s != null);

        if (tvServiceStatus != null) {
            tvServiceStatus.setText(running ? "Stato Server: IN ASCOLTO (Porte " + RemoteServerService.HTTP_PORT + " HTTP / " + RemoteServerService.HTTPS_PORT + " HTTPS)" : "Stato Server: In avvio...");
            tvServiceStatus.setTextColor(running ? 0xFF10B981 : 0xFFF59E0B);
        }

        boolean uinputOk = (s != null && s.getTvController() != null && s.getTvController().isUInputReady());
        if (tvUinputStatus != null) {
            tvUinputStatus.setText("Driver Linux /dev/uinput: " + (uinputOk ? "ATTIVO" : "In attesa..."));
            tvUinputStatus.setTextColor(uinputOk ? 0xFF34D399 : 0xFFF59E0B);
        }

        int activeSessions = (s != null && s.getSecurityManager() != null) ? s.getSecurityManager().getActiveSessionCount() : 0;
        if (tvPairedCount != null) {
            tvPairedCount.setText("Sessioni attive: " + activeSessions);
        }

        final String ip = (s != null) ? s.getLocalIpAddress() : getLocalIpAddress();
        boolean isLocalLoopback = (ip == null || ip.trim().isEmpty() || "127.0.0.1".equals(ip.trim()));

        if (isLocalLoopback) {
            if (tvCaFingerprint != null) {
                tvCaFingerprint.setText("ATTENZIONE: Wi-Fi TV non connesso. Connetti la TV alla rete LAN per abilitare l'onboarding smartphone.");
            }
            if (tvCaUrl != null) tvCaUrl.setText("In attesa di connessione LAN...");
            if (tvHttpsUrl != null) tvHttpsUrl.setText("In attesa di connessione LAN...");
            if (ivQrCa != null) ivQrCa.setImageBitmap(null);
            if (ivQrHttps != null) ivQrHttps.setImageBitmap(null);
            return;
        }

        final String caDownloadUrl = "http://" + ip + ":" + RemoteServerService.HTTP_PORT + "/api/auth/ca.crt";
        final String httpsUrl = "https://" + ip + ":" + RemoteServerService.HTTPS_PORT + "/";

        if (tvServerUrl != null) tvServerUrl.setText(httpsUrl);
        if (tvCaUrl != null) tvCaUrl.setText(caDownloadUrl);
        if (tvHttpsUrl != null) tvHttpsUrl.setText(httpsUrl);

        if (tvCaFingerprint != null) {
            tvCaFingerprint.setText("Generazione / verifica certificati TLS e QR code in corso...");
        }

        // Calcolo asincrono su thread dedicato per non bloccare il rendering UI su architettura TV ARMv7
        bgExecutor.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    TlsCertificateManager tlsMgr = TlsCertificateManager.getInstance();
                    TlsCertificateManager.TlsInfo tlsInfo = tlsMgr.getOrGenerateTlsInfo(MainActivity.this, ip);
                    final String caFp = (tlsInfo != null && tlsInfo.caFingerprintSha256 != null) ? tlsInfo.caFingerprintSha256 : "NON_CONFIGURATA";

                    final Bitmap caBmp = QrBitmapUtil.createQrBitmap(caDownloadUrl, 4, 1);
                    final Bitmap httpsBmp = QrBitmapUtil.createQrBitmap(httpsUrl, 4, 1);

                    runOnUiThread(new Runnable() {
                        @Override
                        public void run() {
                            if (isFinishing() || (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1 && isDestroyed())) {
                                return;
                            }
                            if (tvCaFingerprint != null) {
                                tvCaFingerprint.setText(caFp);
                            }
                            if (ivQrCa != null && caBmp != null) {
                                ivQrCa.setImageBitmap(caBmp);
                            }
                            if (ivQrHttps != null && httpsBmp != null) {
                                ivQrHttps.setImageBitmap(httpsBmp);
                            }
                        }
                    });
                } catch (final Exception e) {
                    Log.e(TAG, "Errore elaborazione asincrona TLS / QR", e);
                    runOnUiThread(new Runnable() {
                        @Override
                        public void run() {
                            if (tvCaFingerprint != null) {
                                tvCaFingerprint.setText("ERRORE_INIZIALIZZAZIONE_TLS: " + e.getMessage());
                            }
                        }
                    });
                }
            }
        });
    }

    private String getLocalIpAddress() {
        RemoteServerService s = RemoteServerService.getInstance();
        if (s != null) {
            return s.getLocalIpAddress();
        }
        return "127.0.0.1";
    }
}
