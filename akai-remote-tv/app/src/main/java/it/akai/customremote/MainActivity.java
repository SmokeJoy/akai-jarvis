package it.akai.customremote;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.DialogInterface;
import android.content.Intent;
import android.graphics.Bitmap;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.util.Log;
import android.view.View;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.CompoundButton;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import it.akai.customremote.qr.QrBitmapUtil;
import it.akai.customremote.ai.OtaAndroidInstallPreflight;
import it.akai.customremote.ai.OtaOwnerPackageInstaller;
import it.akai.customremote.ai.OtaReleaseTrust;
import it.akai.customremote.ai.OtaAndroidArchiveInspector;
import it.akai.customremote.ai.OtaReleaseChannel;
import it.akai.customremote.ai.OtaUpdatePreparation;
import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.os.Handler;
import android.os.Looper;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;

public class MainActivity extends Activity {
    private static final String TAG = "AKAI_MainActivity";
    private final ExecutorService bgExecutor = Executors.newSingleThreadExecutor();
    private final Handler retryHandler = new Handler(Looper.getMainLooper());
    private final java.util.concurrent.atomic.AtomicLong uiGenToken = new java.util.concurrent.atomic.AtomicLong(0);
    private volatile boolean activityDestroyed = false;
    private int retryCount = 0;
    private static final int MAX_RETRIES = 15;
    private ServiceStateListener stateListener = null;
    private ConnectivityManager.NetworkCallback networkCallback = null;

    private final Runnable retryRunnable = new Runnable() {
        @Override
        public void run() {
            if (activityDestroyed || isFinishing() || isDestroyed()) return;
            RemoteServerService s = RemoteServerService.getInstance();
            boolean ready = (s != null && s.isReady());
            String ip = (s != null) ? s.getLocalIpAddress() : getLocalIpAddress();
            boolean isLoopback = (ip == null || ip.trim().isEmpty() || "127.0.0.1".equals(ip.trim()));

            if (!ready || isLoopback) {
                if (retryCount < MAX_RETRIES && !isFinishing()) {
                    retryCount++;
                    updateUI();
                    retryHandler.postDelayed(this, 1000);
                } else {
                    updateUI();
                }
            } else {
                updateUI();
            }
        }
    };

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
    private Button btnVisionLocalTest;
    private Button btnOtaCheck;
    private Button btnOtaPermission;
    private Button btnOtaInstallConfirmed;
    private TextView tvOtaStatus;
    private volatile OtaUpdatePreparation.Result pendingOtaCandidate = null;
    private final java.util.concurrent.atomic.AtomicBoolean otaOperationInFlight = new java.util.concurrent.atomic.AtomicBoolean(false);
    private AlertDialog activeOtaConfirmDialog = null;

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
        btnVisionLocalTest = findViewById(R.id.btn_vision_local_test);
        btnOtaCheck = findViewById(R.id.btn_ota_check);
        btnOtaPermission = findViewById(R.id.btn_ota_permission);
        btnOtaInstallConfirmed = findViewById(R.id.btn_ota_install_confirmed);
        tvOtaStatus = findViewById(R.id.tv_ota_status);

        // Avvio del servizio autonomo in foreground
        Intent serviceIntent = new Intent(this, RemoteServerService.class);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent);
        } else {
            startService(serviceIntent);
        }

        stateListener = new ServiceStateListener() {
            @Override
            public void onServerReady(String localIpAddress, int httpPort, int httpsPort) {
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        retryHandler.removeCallbacks(retryRunnable);
                        updateUI();
                    }
                });
            }

            @Override
            public void onServerDegraded(final String reason) {
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        if (activityDestroyed) return;
                        if (tvCaFingerprint != null) {
                            tvCaFingerprint.setText("ATTENZIONE: Servizio HTTPS non pronto (" + reason + "). Nuovo tentativo in corso...");
                        }
                        if (ivQrCa != null) ivQrCa.setImageBitmap(null);
                        if (ivQrHttps != null) ivQrHttps.setImageBitmap(null);
                        retryHandler.removeCallbacks(retryRunnable);
                        retryHandler.postDelayed(retryRunnable, 1500);
                    }
                });
            }
        };
        RemoteServerService.registerStateListener(stateListener);

        // Monitoraggio dinamico connettività di rete (Wi-Fi / Ethernet DHCP)
        try {
            ConnectivityManager cm = (ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
            if (cm != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                networkCallback = new ConnectivityManager.NetworkCallback() {
                    @Override
                    public void onAvailable(Network network) {
                        runOnUiThread(new Runnable() {
                            @Override
                            public void run() {
                                retryCount = 0;
                                retryHandler.removeCallbacks(retryRunnable);
                                RemoteServerService s = RemoteServerService.getInstance();
                                if (s != null) {
                                    s.notifyIpAddressChanged(s.getLocalIpAddress());
                                }
                                updateUI();
                            }
                        });
                    }

                    @Override
                    public void onLost(Network network) {
                        runOnUiThread(new Runnable() {
                            @Override
                            public void run() {
                                updateUI();
                            }
                        });
                    }

                    @Override
                    public void onLinkPropertiesChanged(Network network, LinkProperties linkProperties) {
                        runOnUiThread(new Runnable() {
                            @Override
                            public void run() {
                                RemoteServerService s = RemoteServerService.getInstance();
                                if (s != null) {
                                    s.notifyIpAddressChanged(s.getLocalIpAddress());
                                }
                                updateUI();
                            }
                        });
                    }
                };
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    cm.registerDefaultNetworkCallback(networkCallback);
                } else {
                    NetworkRequest request = new NetworkRequest.Builder()
                            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                            .build();
                    cm.registerNetworkCallback(request, networkCallback);
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "Impossibile registrare NetworkCallback: " + e.getMessage());
        }

        retryHandler.postDelayed(retryRunnable, 1000);

        updateUI();

        btnShowPin.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                final RemoteServerService s = RemoteServerService.getInstance();
                if (s == null || !s.isReady() || s.getSecurityManager() == null) {
                    Toast.makeText(MainActivity.this, "Inizializzazione server sicuro in corso... Riprova tra pochi secondi.", Toast.LENGTH_SHORT).show();
                    return;
                }
                final String ip = s.getLocalIpAddress();
                final String httpsUrl = "https://" + ip + ":" + RemoteServerService.HTTPS_PORT + "/";

                // Disabilita temporaneamente il bottone durante il retrieval asincrono su worker thread
                btnShowPin.setEnabled(false);
                if (!submitBackgroundTask(new Runnable() {
                    @Override
                    public void run() {
                        try {
                            TlsCertificateManager.TlsInfo info = TlsCertificateManager.getInstance().getOrGenerateTlsInfo(MainActivity.this, ip);
                            final String caFp = (info != null) ? info.caFingerprintSha256 : null;
                            final String pin = s.getSecurityManager().generateNewPin();
                            final int remaining = s.getSecurityManager().getPinRemainingSeconds();

                            runOnUiThread(new Runnable() {
                                @Override
                                public void run() {
                                    btnShowPin.setEnabled(true);
                                    if (isFinishing() || (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1 && isDestroyed())) {
                                        return;
                                    }
                                    PinOverlayDialog.show(MainActivity.this, pin, remaining, httpsUrl, caFp);
                                    Toast.makeText(MainActivity.this, "Schermata PIN aperta a schermo (valida 120s)", Toast.LENGTH_SHORT).show();
                                }
                            });
                        } catch (Exception e) {
                            Log.e(TAG, "Errore recupero credenziali TLS / PIN per dialog", e);
                            runOnUiThread(new Runnable() {
                                @Override
                                public void run() {
                                    btnShowPin.setEnabled(true);
                                    Toast.makeText(MainActivity.this, "Errore generazione PIN sicuro.", Toast.LENGTH_SHORT).show();
                                }
                            });
                        }
                    }
                })) {
                    btnShowPin.setEnabled(true);
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

        // Owner-only D-pad action: if an offline-pinned release key+channel
        // are provisioned, verify and stage a real HTTPS APK on a worker.
        // Never install or start PackageInstaller from this button.
        // No Web API, at-boot polling, silent updates or paid AI calls.
        btnOtaCheck.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                if (!otaOperationInFlight.compareAndSet(false, true)) return;
                pendingOtaCandidate = null;
                setOtaActionVisibility(false, false, null);
                btnOtaCheck.setEnabled(false);
                tvOtaStatus.setText("Verifica locale OTA in corso...");
                if (!submitBackgroundTask(new Runnable() {
                    @Override
                    public void run() {
                        String message = null;
                        OtaUpdatePreparation.Result stagedCandidate = null;
                        OtaAndroidInstallPreflight.Verdict stagedPreflight = null;
                        try {
                            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
                                message = "OTA non supportata: richiede Android 9.";
                            } else if (OtaReleaseTrust.readBundledPublicKey(MainActivity.this) == null) {
                                message = "OTA non configurata: chiave pubblica di rilascio mancante.";
                            } else if (OtaAndroidArchiveInspector.readInstalledIdentity(
                                    MainActivity.this) == null) {
                                message = "OTA bloccata: firma/versione installata non verificabili.";
                            } else {
                                OtaReleaseChannel.Channel channel =
                                        OtaReleaseChannel.loadBundled(MainActivity.this);
                                if (channel == null) {
                                    message = "OTA non configurata: manca il canale HTTPS ufficiale.";
                                } else {
                                    OtaUpdatePreparation.Result candidate =
                                            OtaUpdatePreparation.prepare(MainActivity.this,
                                                    channel.manifestUrl, channel.trustedHosts);
                                    if (candidate.staged) {
                                        stagedCandidate = candidate;
                                        stagedPreflight = OtaAndroidInstallPreflight.inspect(
                                                MainActivity.this, candidate);
                                    } else {
                                        message = "OTA: " + candidate.code +
                                                " (nessuna installazione)";
                                    }
                                }
                            }
                        } finally {
                            otaOperationInFlight.set(false);
                        }
                        final String finalMessage = message;
                        final OtaUpdatePreparation.Result finalCandidate = stagedCandidate;
                        final OtaAndroidInstallPreflight.Verdict finalPreflight = stagedPreflight;
                        runOnUiThread(new Runnable() {
                            @Override public void run() {
                                if (activityDestroyed || isFinishing() || isDestroyed()) return;
                                btnOtaCheck.setEnabled(true);
                                if (finalCandidate != null && finalPreflight != null) {
                                    pendingOtaCandidate = finalCandidate;
                                    applyOtaPreflightUi(finalCandidate, finalPreflight);
                                } else {
                                    pendingOtaCandidate = null;
                                    setOtaActionVisibility(false, false, null);
                                    tvOtaStatus.setText(finalMessage != null ? finalMessage : "Verifica OTA non disponibile.");
                                }
                            }
                        });
                    }
                })) {
                    otaOperationInFlight.set(false);
                    if (!activityDestroyed) {
                        tvOtaStatus.setText("Verifica OTA non disponibile.");
                        btnOtaCheck.setEnabled(true);
                    }
                }
            }
        });

        btnOtaPermission.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                    tvOtaStatus.setText("Permesso Origini sconosciute per app non supportato prima di Android 8.");
                    return;
                }
                Intent permIntent = new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:" + getPackageName()));
                try {
                    startActivity(permIntent);
                    tvOtaStatus.setText("Abilita \"Consenti da questa origine\" e poi torna in JARVIS.");
                } catch (ActivityNotFoundException | SecurityException e) {
                    Log.w(TAG, "Impossibile aprire Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES: " + e.getClass().getSimpleName());
                    tvOtaStatus.setText("Impossibile aprire le Impostazioni Android su questo firmware TV: abilita manualmente Origini sconosciute per JARVIS.");
                }
            }
        });

        btnOtaInstallConfirmed.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                final OtaUpdatePreparation.Result stagedCandidate = pendingOtaCandidate;
                if (stagedCandidate == null || otaOperationInFlight.get()) {
                    tvOtaStatus.setText("Nessun pacchetto OTA verificato pronto per la conferma.");
                    return;
                }
                openOtaOwnerConfirmDialog(stagedCandidate);
            }
        });

        // A2 local vision diagnostic is launched exclusively by a physical
        // TV UI click. It cannot be triggered by the LAN remote.
        btnVisionLocalTest.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                startActivity(new Intent(MainActivity.this, LocalVisualCaptureActivity.class));
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
        final OtaUpdatePreparation.Result staged = pendingOtaCandidate;
        if (staged != null && !otaOperationInFlight.get()) {
            submitBackgroundTask(new Runnable() {
                @Override
                public void run() {
                    final OtaAndroidInstallPreflight.Verdict preflight =
                            OtaAndroidInstallPreflight.inspect(MainActivity.this, staged);
                    runOnUiThread(new Runnable() {
                        @Override
                        public void run() {
                            if (activityDestroyed || isFinishing() || isDestroyed()) return;
                            if (pendingOtaCandidate == staged && !otaOperationInFlight.get()) {
                                applyOtaPreflightUi(staged, preflight);
                            }
                        }
                    });
                }
            });
        } else if (staged == null && !otaOperationInFlight.get() && tvOtaStatus != null) {
            String lastResult = OtaInstallResultReceiver.lastResult(this);
            if (lastResult != null
                    && !"NOT_INSTALLED".equals(lastResult)
                    && !"OTA_STATUS_UNKNOWN".equals(lastResult)) {
                tvOtaStatus.setText("Ultimo esito OTA PackageInstaller: " + lastResult);
            }
        }
    }

    @Override
    protected void onDestroy() {
        // Invalidate queued UI callbacks and QR work before shutting down the executor.
        activityDestroyed = true;
        pendingOtaCandidate = null;
        if (activeOtaConfirmDialog != null) {
            try {
                if (activeOtaConfirmDialog.isShowing()) {
                    activeOtaConfirmDialog.dismiss();
                }
            } catch (Exception ignored) {}
            activeOtaConfirmDialog = null;
        }
        uiGenToken.incrementAndGet();
        retryHandler.removeCallbacksAndMessages(null);
        super.onDestroy();
        if (stateListener != null) {
            RemoteServerService.unregisterStateListener(stateListener);
        }
        if (networkCallback != null) {
            try {
                ConnectivityManager cm = (ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
                if (cm != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                    cm.unregisterNetworkCallback(networkCallback);
                }
            } catch (Exception ignored) {}
        }
        retryHandler.removeCallbacks(retryRunnable);
        try {
            bgExecutor.shutdownNow();
        } catch (Exception ignored) {}
    }

    // Late network/service callbacks must not submit to the executor after teardown.
    private boolean submitBackgroundTask(Runnable task) {
        if (activityDestroyed || bgExecutor.isShutdown()) return false;
        try {
            bgExecutor.execute(task);
            return true;
        } catch (RejectedExecutionException e) {
            Log.i(TAG, "Skipping background UI task: Activity executor has stopped.");
            return false;
        }
    }

    private void updateUI() {
        if (activityDestroyed || isFinishing() || isDestroyed()) return;
        RemoteServerService s = RemoteServerService.getInstance();
        boolean serviceReady = (s != null && s.isReady());

        if (tvServiceStatus != null) {
            tvServiceStatus.setText(serviceReady ? "Stato Server: IN ASCOLTO (Porte " + RemoteServerService.HTTP_PORT + " HTTP / " + RemoteServerService.HTTPS_PORT + " HTTPS)" : "Stato Server: In avvio... (attesa listener HTTP/HTTPS)");
            tvServiceStatus.setTextColor(serviceReady ? 0xFF10B981 : 0xFFF59E0B);
        }

        boolean uinputOk = (s != null && s.getTvController() != null && s.getTvController().isUInputReady());
        boolean accOk = (AkaiAccessibilityService.getInstance() != null);
        if (tvUinputStatus != null) {
            tvUinputStatus.setText("Driver /dev/uinput: " + (uinputOk ? "ATTIVO" : "In attesa...")
                    + " · Accessibilità: " + (accOk ? "ATTIVA" : "DISATTIVA (riattiva in Impostazioni TV)"));
            tvUinputStatus.setTextColor((uinputOk && accOk) ? 0xFF34D399 : 0xFFF59E0B);
        }

        int activeSessions = (s != null && s.getSecurityManager() != null) ? s.getSecurityManager().getActiveSessionCount() : 0;
        if (tvPairedCount != null) {
            tvPairedCount.setText("Sessioni attive: " + activeSessions);
        }

        if (btnShowPin != null) {
            btnShowPin.setEnabled(serviceReady);
            btnShowPin.setAlpha(serviceReady ? 1.0f : 0.6f);
        }

        if (!serviceReady) {
            if (tvCaFingerprint != null) {
                tvCaFingerprint.setText("In attesa dell'avvio completo del server (listener HTTP " + RemoteServerService.HTTP_PORT + " / HTTPS " + RemoteServerService.HTTPS_PORT + ")...");
            }
            if (tvCaUrl != null) tvCaUrl.setText("Server in avvio...");
            if (tvHttpsUrl != null) tvHttpsUrl.setText("Server in avvio...");
            if (ivQrCa != null) ivQrCa.setImageBitmap(null);
            if (ivQrHttps != null) ivQrHttps.setImageBitmap(null);
            return;
        }

        final String ip = s.getLocalIpAddress();
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

        // Verifica allineamento IP del server: se l'IP non corrisponde o il server non è ready, notifica/accoda retry
        String srvIp = s.getCurrentServerIp();
        if (srvIp == null || !srvIp.equals(ip) || !s.isReady()) {
            s.notifyIpAddressChanged(ip);
        }

        final String caDownloadUrl = "http://" + ip + ":" + RemoteServerService.HTTP_PORT + "/api/auth/ca.crt";
        final String httpsUrl = "https://" + ip + ":" + RemoteServerService.HTTPS_PORT + "/";

        if (tvServerUrl != null) tvServerUrl.setText(httpsUrl);
        if (tvCaUrl != null) tvCaUrl.setText(caDownloadUrl);
        if (tvHttpsUrl != null) tvHttpsUrl.setText(httpsUrl);

        if (tvCaFingerprint != null) {
            tvCaFingerprint.setText("Generazione / verifica certificati TLS e QR code in corso...");
        }

        final long token = uiGenToken.incrementAndGet();

        // Calcolo asincrono serializzato su worker thread per non bloccare il rendering UI su architettura TV ARMv7
        submitBackgroundTask(new Runnable() {
            @Override
            public void run() {
                if (activityDestroyed || token != uiGenToken.get()) {
                    return; // Richiesta obsoleta: token generazionale superato
                }
                try {
                    TlsCertificateManager tlsMgr = TlsCertificateManager.getInstance();
                    TlsCertificateManager.TlsInfo tlsInfo = tlsMgr.getOrGenerateTlsInfo(MainActivity.this, ip);
                    final String caFp = (tlsInfo != null && tlsInfo.caFingerprintSha256 != null) ? tlsInfo.caFingerprintSha256 : "NON_CONFIGURATA";

                    final Bitmap caBmp = QrBitmapUtil.createQrBitmap(caDownloadUrl, 4, 1);
                    final Bitmap httpsBmp = QrBitmapUtil.createQrBitmap(httpsUrl, 4, 1);

                    runOnUiThread(new Runnable() {
                        @Override
                        public void run() {
                            if (token != uiGenToken.get()) {
                                return; // Risultato scartato per prevenire visualizzazione dati disallineati rispetto all'IP corrente
                            }
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
                            if (token != uiGenToken.get()) return;
                            if (tvCaFingerprint != null) {
                                tvCaFingerprint.setText("ERRORE_INIZIALIZZAZIONE_TLS: " + e.getMessage());
                            }
                        }
                    });
                }
            }
        });
    }

    private void setOtaActionVisibility(boolean showPermission, boolean showInstall, String installButtonLabel) {
        if (btnOtaPermission != null) {
            btnOtaPermission.setVisibility(showPermission ? View.VISIBLE : View.GONE);
            btnOtaPermission.setEnabled(showPermission);
        }
        if (btnOtaInstallConfirmed != null) {
            btnOtaInstallConfirmed.setVisibility(showInstall ? View.VISIBLE : View.GONE);
            btnOtaInstallConfirmed.setEnabled(showInstall);
            if (installButtonLabel != null) {
                btnOtaInstallConfirmed.setText(installButtonLabel);
            }
        }
    }

    private static String abbreviateSha256(String sha256) {
        if (sha256 == null || sha256.isEmpty()) return "n/d";
        if (sha256.length() >= 24) {
            return sha256.substring(0, 12) + "..." + sha256.substring(sha256.length() - 12);
        }
        return sha256;
    }

    private void applyOtaPreflightUi(OtaUpdatePreparation.Result candidate, OtaAndroidInstallPreflight.Verdict preflight) {
        if (tvOtaStatus == null || candidate == null || preflight == null) return;
        String shortSha = abbreviateSha256(candidate.expectedSha256);
        if (preflight.readyForOwnerRecoveryReview) {
            setOtaActionVisibility(false, true,
                    "Installa versione v" + candidate.candidateVersionCode + " (richiede conferma)");
            tvOtaStatus.setText("Versione " + candidate.candidateVersionCode +
                    " verificata e pronta (SHA-256 " + shortSha +
                    "). Conferma in TV dopo backup e ripristino verificati.");
        } else if ("ANDROID_UNKNOWN_SOURCE_PERMISSION_REQUIRED".equals(preflight.code)) {
            setOtaActionVisibility(true, false, null);
            tvOtaStatus.setText("Versione " + candidate.candidateVersionCode +
                    " verificata (SHA-256 " + shortSha +
                    "). Android 9 richiede l'abilitazione manuale \"Origini sconosciute\" per JARVIS.");
        } else {
            setOtaActionVisibility(false, false, null);
            tvOtaStatus.setText("OTA preflight bloccato: " + preflight.code);
        }
    }

    private void openOtaOwnerConfirmDialog(final OtaUpdatePreparation.Result stagedCandidate) {
        if (activityDestroyed || isFinishing() || isDestroyed() || stagedCandidate == null) return;
        if (activeOtaConfirmDialog != null && activeOtaConfirmDialog.isShowing()) {
            activeOtaConfirmDialog.dismiss();
        }
        AlertDialog.Builder builder = new AlertDialog.Builder(this);
        Context dialogCtx = builder.getContext();
        final int paddingPx = Math.round(18f * getResources().getDisplayMetrics().density);
        LinearLayout container = new LinearLayout(dialogCtx);
        container.setOrientation(LinearLayout.VERTICAL);
        container.setPadding(paddingPx, paddingPx / 2, paddingPx, paddingPx / 2);

        TextView summary = new TextView(dialogCtx);
        summary.setText("Versione candidata: v" + stagedCandidate.candidateVersionCode +
                "\nSHA-256: " + abbreviateSha256(stagedCandidate.expectedSha256) +
                "\nFirma certificato originale Android verificata.\n" +
                "L'installazione avvierà PackageInstaller di Android 9 con tua conferma OS esplicita.");
        container.addView(summary);

        final CheckBox chkBackup = new CheckBox(dialogCtx);
        chkBackup.setText("Confermo di avere un backup verificato (APK + SQLite/WAL + TLS).");
        chkBackup.setChecked(false);
        chkBackup.setFocusable(true);
        container.addView(chkBackup);

        final CheckBox chkRecovery = new CheckBox(dialogCtx);
        chkRecovery.setText("Confermo che il recupero conservativo (A2 Rescue / restore) è verificato.");
        chkRecovery.setChecked(false);
        chkRecovery.setFocusable(true);
        container.addView(chkRecovery);

        builder.setTitle("Conferma installazione OTA v" + stagedCandidate.candidateVersionCode)
                .setView(container)
                .setNegativeButton("Annulla", null)
                .setPositiveButton("Avvia PackageInstaller Android 9", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialog, int which) {
                        if (!chkBackup.isChecked() || !chkRecovery.isChecked()) return;
                        if (pendingOtaCandidate != stagedCandidate) return;
                        if (!otaOperationInFlight.compareAndSet(false, true)) return;
                        btnOtaCheck.setEnabled(false);
                        setOtaActionVisibility(false, false, null);
                        tvOtaStatus.setText("Invio pacchetto verificato a PackageInstaller Android...");
                        if (!submitBackgroundTask(new Runnable() {
                            @Override
                            public void run() {
                                final OtaOwnerPackageInstaller.Outcome outcome;
                                try {
                                    outcome = OtaOwnerPackageInstaller.submitAfterPhysicalOwnerApproval(
                                            MainActivity.this, stagedCandidate, true, true, true);
                                } finally {
                                    otaOperationInFlight.set(false);
                                }
                                runOnUiThread(new Runnable() {
                                    @Override
                                    public void run() {
                                        if (activityDestroyed || isFinishing() || isDestroyed()) return;
                                        btnOtaCheck.setEnabled(true);
                                        pendingOtaCandidate = null;
                                        setOtaActionVisibility(false, false, null);
                                        tvOtaStatus.setText("OTA PackageInstaller: " + outcome.code);
                                    }
                                });
                            }
                        })) {
                            otaOperationInFlight.set(false);
                            btnOtaCheck.setEnabled(true);
                            pendingOtaCandidate = null;
                            tvOtaStatus.setText("Impossibile avviare PackageInstaller in background.");
                        }
                    }
                });

        final AlertDialog dialog = builder.create();
        dialog.setOnShowListener(new DialogInterface.OnShowListener() {
            @Override
            public void onShow(DialogInterface d) {
                chkBackup.requestFocus();
                final Button positive = dialog.getButton(DialogInterface.BUTTON_POSITIVE);
                if (positive == null) return;
                positive.setEnabled(false);
                CompoundButton.OnCheckedChangeListener listener = new CompoundButton.OnCheckedChangeListener() {
                    @Override
                    public void onCheckedChanged(CompoundButton buttonView, boolean isChecked) {
                        positive.setEnabled(chkBackup.isChecked() && chkRecovery.isChecked());
                    }
                };
                chkBackup.setOnCheckedChangeListener(listener);
                chkRecovery.setOnCheckedChangeListener(listener);
            }
        });
        dialog.setOnDismissListener(new DialogInterface.OnDismissListener() {
            @Override
            public void onDismiss(DialogInterface d) {
                if (activeOtaConfirmDialog == dialog) {
                    activeOtaConfirmDialog = null;
                }
            }
        });
        activeOtaConfirmDialog = dialog;
        dialog.show();
    }

    private String getLocalIpAddress() {
        RemoteServerService s = RemoteServerService.getInstance();
        if (s != null) {
            return s.getLocalIpAddress();
        }
        return "127.0.0.1";
    }
}
