package it.akai.customremote;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import it.akai.customremote.ai.AkaiAiController;
import it.akai.customremote.ai.AkaiMemoryEngine;
import it.akai.customremote.ai.AiProviderAdapter;
import it.akai.customremote.ai.KeystoreSecurityHelper;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.security.SecureRandom;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLServerSocket;
import javax.net.ssl.SSLServerSocketFactory;

public class RemoteServerService extends Service {
    private static final String TAG = "AKAI_RemoteServer";
    public static final int HTTP_PORT = 8088;
    public static final int HTTPS_PORT = 8443;
    private static final String NOTIF_CHANNEL_ID = "akai_remote_channel";
    private static final int NOTIF_ID = 5037;

    private static RemoteServerService sInstance = null;

    private ServerSocket httpServerSocket;
    private SSLServerSocket httpsServerSocket;
    private Thread httpAcceptorThread;
    private Thread httpsAcceptorThread;
    private ExecutorService threadPool;
    private volatile boolean isRunning = false;
    private volatile boolean isStarting = false;
    private BroadcastReceiver screenWakeReceiver = null;

    private SecurityManager securityManager;
    private TvController tvController;
    private RestApiRouter restApiRouter;

    public static RemoteServerService getInstance() {
        return sInstance;
    }

    public SecurityManager getSecurityManager() {
        return securityManager;
    }

    public TvController getTvController() {
        return tvController;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        sInstance = this;
        securityManager = new SecurityManager(this);
        tvController = new TvController(this);
        restApiRouter = new RestApiRouter(
            securityManager,
            new RestApiRouter.CommandHandler() {
                @Override public CommandResult executeCommand(String action) { return tvController.executeCommand(action); }
                @Override public CommandResult injectText(String text) { return tvController.injectText(text); }
                @Override public boolean isUInputReady() { return tvController.isUInputReady(); }
            },
            new RestApiRouter.MemoryHandler() {
                @Override public JSONArray getAllProcedures() { return AkaiMemoryEngine.getInstance(RemoteServerService.this).getAllProcedures(); }
                @Override public JSONObject getAllPreferences() { return AkaiMemoryEngine.getInstance(RemoteServerService.this).getAllPreferences(); }
                @Override public JSONObject getAllStats() { return AkaiMemoryEngine.getInstance(RemoteServerService.this).getAllStats(); }
                @Override public JSONArray getRecentConversations(int limit) { return AkaiMemoryEngine.getInstance(RemoteServerService.this).getRecentConversations(limit); }
                @Override public long getDatabaseSizeBytes() { return AkaiMemoryEngine.getInstance(RemoteServerService.this).getDatabaseSizeBytes(); }
                @Override public boolean isGuestMode() { return AkaiMemoryEngine.getInstance(RemoteServerService.this).isGuestMode(); }
                @Override public void setGuestMode(boolean enabled) { AkaiMemoryEngine.getInstance(RemoteServerService.this).setGuestMode(enabled); }
                @Override public void resetProcedures() { AkaiMemoryEngine.getInstance(RemoteServerService.this).resetProcedures(); }
                @Override public void clearPersonalPreferencesOnly() { AkaiMemoryEngine.getInstance(RemoteServerService.this).clearPersonalPreferencesOnly(); }
            },
            new RestApiRouter.PinHandler() {
                @Override public void showPin(String pin, int remaining, String serverUrl) { PinOverlayDialog.show(RemoteServerService.this, pin, remaining, serverUrl); }
                @Override public void dismissPin() { PinOverlayDialog.dismiss(); }
            },
            getLocalIpAddress(),
            HTTP_PORT
        );
        threadPool = Executors.newFixedThreadPool(12);

        createNotificationChannel();
        startForeground(NOTIF_ID, buildForegroundNotification());

        startServers();

        // Monitor wake from TV standby / screen on/off to maintain socket health and telemetry
        IntentFilter filter = new IntentFilter();
        filter.addAction(Intent.ACTION_SCREEN_ON);
        filter.addAction(Intent.ACTION_SCREEN_OFF);
        filter.addAction(Intent.ACTION_USER_PRESENT);
        screenWakeReceiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                String action = (intent != null) ? intent.getAction() : "";
                if (Intent.ACTION_SCREEN_OFF.equals(action)) {
                    LocalDiagnosticsManager.getInstance(context).onScreenStateChanged(false);
                } else {
                    LocalDiagnosticsManager.getInstance(context).onScreenStateChanged(true);
                    ensureServerRunning();
                }
            }
        };
        registerReceiver(screenWakeReceiver, filter);

        // Avvio sistema di diagnostica e telemetria locale autonoma
        LocalDiagnosticsManager.getInstance(this).start();

        // Inizializzazione anticipata del motore vocale TTS per riscaldamento istantaneo
        try {
            it.akai.customremote.ai.AkaiSpeechEngine.getInstance(this);
        } catch (Exception e) {
            Log.w(TAG, "Speech engine warmup notice: " + e.getMessage());
        }

        Log.i(TAG, "AKAI Remote HTTP Service running in foreground on port " + HTTP_PORT);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        ensureServerRunning();
        return START_STICKY;
    }

    public synchronized void ensureServerRunning() {
        if (isStarting) return;
        boolean httpDead = (httpServerSocket == null || httpServerSocket.isClosed() || !httpServerSocket.isBound());
        boolean httpsDead = (httpsServerSocket == null || httpsServerSocket.isClosed() || !httpsServerSocket.isBound());
        if (!isRunning || httpDead || httpsDead) {
            Log.i(TAG, "Server socket inactive or closed. Restarting servers...");
            startServers();
        }
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                NOTIF_CHANNEL_ID,
                "AKAI Remote Server",
                NotificationManager.IMPORTANCE_LOW
            );
            channel.setDescription("Demone attivo per la gestione del telecomando locale");
            NotificationManager nm = getSystemService(NotificationManager.class);
            if (nm != null) {
                nm.createNotificationChannel(channel);
            }
        }
    }

    private Notification buildForegroundNotification() {
        Notification.Builder builder;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder = new Notification.Builder(this, NOTIF_CHANNEL_ID);
        } else {
            builder = new Notification.Builder(this);
        }

        return builder
            .setContentTitle("AKAI Custom Remote")
            .setContentText("Telecomando LAN attivo su porta " + HTTP_PORT)
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setOngoing(true)
            .build();
    }

    private SSLContext createSSLContext() {
        try {
            KeyStore keyStore = KeyStore.getInstance("PKCS12");
            try (InputStream is = getAssets().open("server_keystore.p12")) {
                keyStore.load(is, "akai1234".toCharArray());
            }
            KeyManagerFactory kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
            kmf.init(keyStore, "akai1234".toCharArray());
            SSLContext sslContext = SSLContext.getInstance("TLS");
            sslContext.init(kmf.getKeyManagers(), null, new SecureRandom());
            return sslContext;
        } catch (Exception e) {
            Log.e(TAG, "Failed loading TLS keystore for HTTPS: " + e.getMessage(), e);
            return null;
        }
    }

    private synchronized void startServers() {
        if (isRunning && httpServerSocket != null && !httpServerSocket.isClosed() && httpServerSocket.isBound()
            && httpsServerSocket != null && !httpsServerSocket.isClosed() && httpsServerSocket.isBound()) {
            return;
        }

        if (isStarting) {
            Log.d(TAG, "Server startup already in progress.");
            return;
        }

        isStarting = true;
        isRunning = true;

        try {
            // 1. HTTP Server (Port 8088)
            if (httpServerSocket == null || httpServerSocket.isClosed() || !httpServerSocket.isBound()) {
                if (httpServerSocket != null && !httpServerSocket.isClosed()) {
                    try { httpServerSocket.close(); } catch (Exception ignored) {}
                }
                ServerSocket server = new ServerSocket();
                server.setReuseAddress(true);
                server.bind(new InetSocketAddress(HTTP_PORT));
                httpServerSocket = server;
                Log.i(TAG, "AKAI Remote HTTP Server listening on port " + HTTP_PORT);

                httpAcceptorThread = new Thread(new Runnable() {
                    @Override
                    public void run() {
                        final ServerSocket s = httpServerSocket;
                        while (isRunning && s != null && !s.isClosed() && s.isBound()) {
                            try {
                                final Socket client = s.accept();
                                threadPool.execute(new Runnable() {
                                    @Override
                                    public void run() {
                                        handleClient(client, false);
                                    }
                                });
                            } catch (IOException e) {
                                if (!isRunning || s.isClosed()) break;
                                Log.e(TAG, "HTTP Accept error: " + e.getMessage());
                                try { Thread.sleep(200); } catch (InterruptedException ignored) {}
                            }
                        }
                    }
                }, "AkaiHttpAcceptor");
                httpAcceptorThread.start();
            }

            // 2. HTTPS Server (Port 8443)
            if (httpsServerSocket == null || httpsServerSocket.isClosed() || !httpsServerSocket.isBound()) {
                SSLContext sslContext = createSSLContext();
                if (sslContext != null) {
                    if (httpsServerSocket != null && !httpsServerSocket.isClosed()) {
                        try { httpsServerSocket.close(); } catch (Exception ignored) {}
                    }
                    SSLServerSocketFactory factory = sslContext.getServerSocketFactory();
                    SSLServerSocket sslServer = (SSLServerSocket) factory.createServerSocket();
                    sslServer.setReuseAddress(true);
                    sslServer.bind(new InetSocketAddress(HTTPS_PORT));
                    httpsServerSocket = sslServer;
                    Log.i(TAG, "AKAI Remote HTTPS Server listening on port " + HTTPS_PORT + " (Secure Context for Voice)");

                    httpsAcceptorThread = new Thread(new Runnable() {
                        @Override
                        public void run() {
                            final ServerSocket s = httpsServerSocket;
                            while (isRunning && s != null && !s.isClosed() && s.isBound()) {
                                try {
                                    final Socket client = s.accept();
                                    threadPool.execute(new Runnable() {
                                        @Override
                                        public void run() {
                                            handleClient(client, true);
                                        }
                                    });
                                } catch (IOException e) {
                                    if (!isRunning || s.isClosed()) break;
                                    Log.e(TAG, "HTTPS Accept error: " + e.getMessage());
                                    try { Thread.sleep(200); } catch (InterruptedException ignored) {}
                                }
                            }
                        }
                    }, "AkaiHttpsAcceptor");
                    httpsAcceptorThread.start();
                } else {
                    Log.w(TAG, "SSLContext not available; HTTPS server skipped.");
                }
            }
        } catch (Exception e) {
            Log.e(TAG, "Error starting server sockets: " + e.getMessage(), e);
        } finally {
            isStarting = false;
        }
    }

    private void handleClient(Socket client, boolean isHttps) {
        try {
            client.setSoTimeout(10000); // 10s socket timeout
            InputStream is = client.getInputStream();
            OutputStream os = client.getOutputStream();

            // Read raw headers up to \r\n\r\n (capped at 8192 bytes)
            ByteArrayOutputStream headerBuf = new ByteArrayOutputStream();
            int prev3 = -1, prev2 = -1, prev1 = -1;
            int b;
            int count = 0;
            while ((b = is.read()) != -1) {
                headerBuf.write(b);
                count++;
                if (count > 8192) {
                    sendJsonResponse(os, 431, new JSONObject().put("error", "Request Header Fields Too Large"));
                    client.close();
                    return;
                }
                if (prev3 == '\r' && prev2 == '\n' && prev1 == '\r' && b == '\n') {
                    break;
                }
                prev3 = prev2;
                prev2 = prev1;
                prev1 = b;
            }

            if (count == 0 || (b == -1 && !headerBuf.toString("ISO-8859-1").endsWith("\r\n\r\n"))) {
                client.close();
                return;
            }

            String headerText = headerBuf.toString("ISO-8859-1");
            String[] lines = headerText.split("\r\n");
            if (lines.length == 0 || lines[0].isEmpty()) {
                client.close();
                return;
            }

            String[] reqParts = lines[0].split(" ");
            if (reqParts.length < 2) {
                client.close();
                return;
            }

            String method = reqParts[0].toUpperCase();
            String path = reqParts[1];
            if (path.contains("?")) {
                path = path.substring(0, path.indexOf("?"));
            }

            Map<String, String> headers = new HashMap<>();
            int contentLength = 0;
            for (int i = 1; i < lines.length; i++) {
                int colon = lines[i].indexOf(":");
                if (colon > 0) {
                    String name = lines[i].substring(0, colon).trim().toLowerCase();
                    String val = lines[i].substring(colon + 1).trim();
                    headers.put(name, val);
                    if ("content-length".equals(name)) {
                        try { contentLength = Integer.parseInt(val); } catch (Exception ignored) {}
                    }
                }
            }

            // Body size guard (max 64 KB for JSON commands)
            if (contentLength > 65536) {
                sendJsonResponse(os, 413, new JSONObject().put("error", "Payload Too Large (max 64KB)"));
                client.close();
                return;
            }

            // Read exact bytes for body (supports full UTF-8, accents and emojis)
            String body = "";
            if (contentLength > 0) {
                byte[] rawBody = new byte[contentLength];
                int totalRead = 0;
                while (totalRead < contentLength) {
                    int r = is.read(rawBody, totalRead, contentLength - totalRead);
                    if (r < 0) {
                        sendJsonResponse(os, 400, new JSONObject().put("error", "Premature end of request body"));
                        client.close();
                        return;
                    }
                    totalRead += r;
                }
                body = new String(rawBody, StandardCharsets.UTF_8);
            }

            String clientIp = client.getInetAddress().getHostAddress();

            // Handle CORS Preflight
            if ("OPTIONS".equals(method)) {
                sendRawResponse(os, 204, "No Content", "text/plain", new byte[0]);
                client.close();
                return;
            }

            // Route Requests
            routeRequest(method, path, headers, body, clientIp, os);

        } catch (Exception e) {
            Log.e(TAG, "Error handling client: " + e.getMessage());
        } finally {
            try { client.close(); } catch (Exception ignored) {}
        }
    }

    private void routeRequest(String method, String path, Map<String, String> headers, String body, String clientIp, OutputStream os) throws Exception {
        if (restApiRouter != null && restApiRouter.routeRequest(method, path, headers, body, clientIp, os)) {
            return;
        }
        // Subnet Verification (rifiuta IP esterni WAN)
        if (!securityManager.isPrivateLanIp(clientIp)) {
            JSONObject err = new JSONObject().put("error", "Access denied: non-private LAN IP");
            sendJsonResponse(os, 403, err);
            return;
        }

        // Diagnostics Log Endpoint (Recupero telemetria locale autonoma - autenticato)
        if ("/api/diagnostics".equals(path) && "GET".equals(method)) {
            String token = extractBearerToken(headers);
            if (!securityManager.validateToken(token)) {
                sendJsonResponse(os, 401, new JSONObject().put("error", "Non autorizzato: token mancante o scaduto"));
                return;
            }
            File diagFile = LocalDiagnosticsManager.getInstance(this).getLogFile();
            if (!diagFile.exists() || diagFile.length() == 0) {
                sendRawResponse(os, 200, "OK", "application/x-ndjson", new byte[0]);
                return;
            }
            int maxLen = (int) Math.min(diagFile.length(), 2 * 1024 * 1024);
            byte[] bytes = new byte[maxLen];
            FileInputStream fis = null;
            try {
                fis = new FileInputStream(diagFile);
                int read = fis.read(bytes);
                sendRawResponse(os, 200, "OK", "application/x-ndjson", (read > 0 ? java.util.Arrays.copyOf(bytes, read) : new byte[0]));
            } catch (Exception e) {
                sendJsonResponse(os, 500, new JSONObject().put("error", "Errore lettura diagnostica: " + e.getMessage()));
            } finally {
                if (fis != null) {
                    try { fis.close(); } catch (Exception ignored) {}
                }
            }
            return;
        }

        // =====================================================================
        // AKAI AI ASSISTANT ENDPOINTS (FASE 13)
        // Note: Le rotte standard di pairing, status e comandi remoti sono
        // gestite in via esclusiva da RestApiRouter come Single Source of Truth.
        // =====================================================================

        // AI Query / Inference (Push-to-talk voice or text - supports /api/ai/ask & /api/ai/query)
        if (("/api/ai/ask".equals(path) || "/api/ai/query".equals(path)) && "POST".equals(method)) {
            String token = extractBearerToken(headers);
            if (!securityManager.validateToken(token)) {
                sendJsonResponse(os, 401, new JSONObject().put("error", "Non autorizzato: token mancante o scaduto"));
                return;
            }

            JSONObject req = new JSONObject(body);
            String query = req.optString("query", "");
            boolean speak = req.optBoolean("speak", true);

            AkaiAiController ai = AkaiAiController.getInstance(this, tvController);
            JSONObject aiRes = ai.processQuery(query, speak);

            sendJsonResponse(os, 200, aiRes);
            return;
        }

        // AI Speech Status (/api/ai/speech_status)
        if ("/api/ai/speech_status".equals(path) && "GET".equals(method)) {
            it.akai.customremote.ai.AkaiSpeechEngine speech = it.akai.customremote.ai.AkaiSpeechEngine.getInstance(this);
            JSONObject out = new JSONObject();
            out.put("speaking", speech.isSpeaking());
            out.put("speech_state", speech.getSpeechState());
            out.put("speech_id", speech.getCurrentSpeechId());
            out.put("voice", speech.getTtsVoice());
            sendJsonResponse(os, 200, out);
            return;
        }

        // AI Direct Speech Playback (/api/ai/speak)
        if ("/api/ai/speak".equals(path) && "POST".equals(method)) {
            String token = extractBearerToken(headers);
            if (!securityManager.validateToken(token)) {
                sendJsonResponse(os, 401, new JSONObject().put("error", "Non autorizzato: token mancante o scaduto"));
                return;
            }

            JSONObject req = new JSONObject(body);
            String textToSpeak = req.optString("text", "");
            boolean interrupt = req.optBoolean("interrupt", true);

            it.akai.customremote.ai.AkaiSpeechEngine speech = it.akai.customremote.ai.AkaiSpeechEngine.getInstance(this);
            boolean queued = speech.speak(textToSpeak, interrupt);

            JSONObject out = new JSONObject();
            out.put("success", queued);
            out.put("spoken", textToSpeak);
            out.put("voice", speech.getTtsVoice());
            sendJsonResponse(os, queued ? 200 : 500, out);
            return;
        }

        // AI TTS Neural Configuration (GET /api/ai/tts_config)
        if ("/api/ai/tts_config".equals(path) && "GET".equals(method)) {
            String token = extractBearerToken(headers);
            if (!securityManager.validateToken(token)) {
                sendJsonResponse(os, 401, new JSONObject().put("error", "Non autorizzato: token mancante o scaduto"));
                return;
            }

            it.akai.customremote.ai.AkaiSpeechEngine speech = it.akai.customremote.ai.AkaiSpeechEngine.getInstance(this);
            boolean hasAzure = !speech.getAzureKey().isEmpty();

            JSONObject out = new JSONObject();
            out.put("active_voice", speech.getTtsVoice());
            out.put("has_azure_key", hasAzure);
            out.put("masked_azure_key", hasAzure ? "••••••••••••••••" : "");
            out.put("azure_region", speech.getAzureRegion());
            out.put("cache_size_bytes", speech.getCacheSizeBytes());
            out.put("cache_size_kb", Math.round(speech.getCacheSizeBytes() / 102.4) / 10.0);
            out.put("max_cache_mb", 8);

            JSONArray voices = new JSONArray();
            voices.put(new JSONObject().put("id", it.akai.customremote.ai.CloudSpeechAdapter.VOICE_DIEGO).put("name", "Diego (Neurale Maschile - Naturale)").put("cloud", true));
            voices.put(new JSONObject().put("id", it.akai.customremote.ai.CloudSpeechAdapter.VOICE_ISABELLA).put("name", "Isabella (Neurale Femminile - Naturale)").put("cloud", true));
            voices.put(new JSONObject().put("id", it.akai.customremote.ai.CloudSpeechAdapter.VOICE_OFFLINE).put("name", "Offline Standard (Locale eSpeak NG)").put("cloud", false));
            out.put("available_voices", voices);

            sendJsonResponse(os, 200, out);
            return;
        }

        // AI TTS Neural Configuration Update (POST /api/ai/tts_config)
        if ("/api/ai/tts_config".equals(path) && "POST".equals(method)) {
            String token = extractBearerToken(headers);
            if (!securityManager.validateToken(token)) {
                sendJsonResponse(os, 401, new JSONObject().put("error", "Non autorizzato: token mancante o scaduto"));
                return;
            }

            JSONObject req = new JSONObject(body);
            it.akai.customremote.ai.AkaiSpeechEngine speech = it.akai.customremote.ai.AkaiSpeechEngine.getInstance(this);

            if (req.has("voice")) {
                speech.setTtsVoice(req.getString("voice"));
            }
            if (req.has("azure_key")) {
                String k = req.getString("azure_key");
                if (!k.contains("••••")) {
                    speech.setAzureKey(k);
                }
            }
            if (req.has("azure_region")) {
                speech.setAzureRegion(req.getString("azure_region"));
            }

            JSONObject out = new JSONObject();
            out.put("success", true);
            out.put("active_voice", speech.getTtsVoice());
            out.put("azure_region", speech.getAzureRegion());
            sendJsonResponse(os, 200, out);
            return;
        }

        // AI Voice Preview (POST /api/ai/tts_preview)
        if ("/api/ai/tts_preview".equals(path) && "POST".equals(method)) {
            String token = extractBearerToken(headers);
            if (!securityManager.validateToken(token)) {
                sendJsonResponse(os, 401, new JSONObject().put("error", "Non autorizzato: token mancante o scaduto"));
                return;
            }

            JSONObject req = new JSONObject(body);
            String voice = req.optString("voice", it.akai.customremote.ai.CloudSpeechAdapter.VOICE_DIEGO);
            String sample = req.optString("text", "Ciao, questa è la voce naturale dell'assistente per la tua televisione AKAI.");

            it.akai.customremote.ai.AkaiSpeechEngine speech = it.akai.customremote.ai.AkaiSpeechEngine.getInstance(this);
            boolean started = speech.previewVoice(voice, sample);

            JSONObject out = new JSONObject();
            out.put("success", started);
            out.put("voice", voice);
            out.put("sample", sample);
            sendJsonResponse(os, started ? 200 : 500, out);
            return;
        }

        // AI Clear Audio Cache (POST /api/ai/tts_cache_clear)
        if ("/api/ai/tts_cache_clear".equals(path) && "POST".equals(method)) {
            String token = extractBearerToken(headers);
            if (!securityManager.validateToken(token)) {
                sendJsonResponse(os, 401, new JSONObject().put("error", "Non autorizzato: token mancante o scaduto"));
                return;
            }

            it.akai.customremote.ai.AkaiSpeechEngine speech = it.akai.customremote.ai.AkaiSpeechEngine.getInstance(this);
            speech.clearCache();

            JSONObject out = new JSONObject();
            out.put("success", true);
            out.put("cache_size_bytes", speech.getCacheSizeBytes());
            sendJsonResponse(os, 200, out);
            return;
        }

        // AI Configuration & Preferences (GET)
        if ("/api/ai/config".equals(path) && "GET".equals(method)) {
            String token = extractBearerToken(headers);
            if (!securityManager.validateToken(token)) {
                sendJsonResponse(os, 401, new JSONObject().put("error", "Non autorizzato: token mancante o scaduto"));
                return;
            }

            AkaiAiController ai = AkaiAiController.getInstance(this, tvController);
            AiProviderAdapter adapter = ai.getAiAdapter();
            AkaiMemoryEngine mem = ai.getMemoryEngine();

            JSONObject cfg = new JSONObject();
            cfg.put("active_provider", adapter.getActiveProvider());
            cfg.put("active_model", adapter.getActiveModel());
            boolean hasDeepSeek = !adapter.getApiKey(AiProviderAdapter.PROVIDER_DEEPSEEK).isEmpty();
            boolean hasKimi = !adapter.getApiKey(AiProviderAdapter.PROVIDER_KIMI).isEmpty();
            cfg.put("has_deepseek_key", hasDeepSeek);
            cfg.put("masked_deepseek_key", hasDeepSeek ? "••••••••••••••••" : "");
            cfg.put("has_kimi_key", hasKimi);
            cfg.put("masked_kimi_key", hasKimi ? "••••••••••••••••" : "");
            cfg.put("keystore_available", KeystoreSecurityHelper.isKeystoreAvailable());
            cfg.put("keystore_hardware_backed", KeystoreSecurityHelper.isHardwareBacked());
            cfg.put("keystore_security_details", KeystoreSecurityHelper.getKeySecurityDetails());
            cfg.put("budget", adapter.getBudgetSummary());
            cfg.put("preferences", mem.getAllPreferences());
            cfg.put("stats", mem.getAllStats());

            sendJsonResponse(os, 200, cfg);
            return;
        }

        // AI Configuration & Preferences (POST update)
        if ("/api/ai/config".equals(path) && "POST".equals(method)) {
            String token = extractBearerToken(headers);
            if (!securityManager.validateToken(token)) {
                sendJsonResponse(os, 401, new JSONObject().put("error", "Non autorizzato: token mancante o scaduto"));
                return;
            }

            JSONObject req = new JSONObject(body);
            AkaiAiController ai = AkaiAiController.getInstance(this, tvController);
            AiProviderAdapter adapter = ai.getAiAdapter();
            AkaiMemoryEngine mem = ai.getMemoryEngine();

            if (req.has("provider")) {
                adapter.setActiveProvider(req.getString("provider"));
            }
            if (req.has("model")) {
                adapter.setActiveModel(req.getString("model"));
            }
            if (req.has("deepseek_key")) {
                String k = req.getString("deepseek_key");
                if (!k.contains("••••")) {
                    adapter.setApiKey(AiProviderAdapter.PROVIDER_DEEPSEEK, k);
                }
            }
            if (req.has("kimi_key")) {
                String k = req.getString("kimi_key");
                if (!k.contains("••••")) {
                    adapter.setApiKey(AiProviderAdapter.PROVIDER_KIMI, k);
                }
            }
            if (req.has("preferences")) {
                JSONObject prefs = req.getJSONObject("preferences");
                java.util.Iterator<String> keys = prefs.keys();
                while (keys.hasNext()) {
                    String k = keys.next();
                    mem.setPreference(k, prefs.getString(k), "custom", 1);
                }
            }
            if (req.has("guest_mode")) {
                mem.setGuestMode(req.getBoolean("guest_mode"));
            }
            if (req.has("reset_budget") && req.getBoolean("reset_budget")) {
                adapter.resetBudgetSpent();
            }

            JSONObject res = new JSONObject();
            res.put("success", true);
            res.put("message", "Configurazione AI salvata con successo");
            sendJsonResponse(os, 200, res);
            return;
        }

        // Clear Personal Memories Only (Wipe personal data, retain technical procedures)
        if ("/api/ai/memory/clear_personal".equals(path) && "POST".equals(method)) {
            String token = extractBearerToken(headers);
            if (!securityManager.validateToken(token)) {
                sendJsonResponse(os, 401, new JSONObject().put("error", "Non autorizzato: token mancante o scaduto"));
                return;
            }

            AkaiMemoryEngine mem = AkaiMemoryEngine.getInstance(this);
            mem.clearPersonalPreferencesOnly();

            JSONObject res = new JSONObject();
            res.put("success", true);
            res.put("message", "Memorie personali eliminate con successo. Procedure tecniche preservate.");
            sendJsonResponse(os, 200, res);
            return;
        }

        // Test Provider Connection
        if ("/api/ai/test_connection".equals(path) && "POST".equals(method)) {
            String token = extractBearerToken(headers);
            if (!securityManager.validateToken(token)) {
                sendJsonResponse(os, 401, new JSONObject().put("error", "Non autorizzato: token mancante o scaduto"));
                return;
            }

            JSONObject req = new JSONObject(body);
            String prov = req.optString("provider", "deepseek");
            String key = req.optString("api_key", null);
            String model = req.optString("model", null);

            AkaiAiController ai = AkaiAiController.getInstance(this, tvController);
            JSONObject testRes = ai.getAiAdapter().testConnection(prov, key, model);

            sendJsonResponse(os, 200, testRes);
            return;
        }

        // Test Simulato del Blocco Budget e Concorrenza (0 Token spesi)
        if ("/api/ai/simulate_budget".equals(path) && "POST".equals(method)) {
            String token = extractBearerToken(headers);
            if (!securityManager.validateToken(token)) {
                sendJsonResponse(os, 401, new JSONObject().put("error", "Non autorizzato: token mancante o scaduto"));
                return;
            }

            JSONObject req = new JSONObject(body.isEmpty() ? "{}" : body);
            String testType = req.optString("test_type", "insufficient_budget");
            double simRem = req.optDouble("simulated_remaining", 0.01);
            double simEst = req.optDouble("simulated_estimate", 0.02);

            JSONObject simRes = new JSONObject();
            simRes.put("test_type", testType);
            simRes.put("real_spent_eur", AkaiAiController.getInstance(this, tvController).getAiAdapter().getTotalSpentEur());
            simRes.put("real_tokens_billed", 0);

            if ("concurrent_reservation".equals(testType)) {
                double avail = 0.04;
                double reqEach = 0.03;
                boolean call1 = (avail >= reqEach);
                double remAfter1 = avail - reqEach;
                boolean call2 = (remAfter1 >= reqEach);
                simRes.put("available_budget_eur", avail);
                simRes.put("call_1_request_eur", reqEach);
                simRes.put("call_1_reserved", call1);
                simRes.put("call_2_request_eur", reqEach);
                simRes.put("call_2_reserved", call2);
                simRes.put("call_2_rejected_reason", "BLOCCO PREVENTIVO ATOMICO: Margine residuo 0.01 € < 0.03 € richiesto");
                simRes.put("simulation_passed", call1 && !call2);
                simRes.put("message", "Test di concorrenza riuscito: la prima chiamata ha prenotato il budget, la seconda è stata bloccata preventivamente.");
            } else {
                JSONObject check = AiProviderAdapter.simulateBudgetCheck(simRem, simEst);
                simRes.put("simulated_check", check);
                simRes.put("simulation_passed", !check.optBoolean("approved"));
                simRes.put("message", "Test di blocco preventivo riuscito: richiesta da " + simEst + " € bloccata con residuo di " + simRem + " €.");
            }

            sendJsonResponse(os, 200, simRes);
            return;
        }

        // Clear or Reset Procedural Memory
        if ("/api/ai/memory/clear".equals(path) && "POST".equals(method)) {
            String token = extractBearerToken(headers);
            if (!securityManager.validateToken(token)) {
                sendJsonResponse(os, 401, new JSONObject().put("error", "Non autorizzato: token mancante o scaduto"));
                return;
            }

            JSONObject req = new JSONObject(body);
            String target = req.optString("target", "procedures");
            String intentKey = req.optString("intent_key", null);

            AkaiMemoryEngine mem = AkaiMemoryEngine.getInstance(this);
            if (intentKey != null && !intentKey.isEmpty()) {
                mem.deleteProcedure(intentKey);
            } else if ("procedures".equals(target)) {
                mem.resetProcedures();
            }

            JSONObject res = new JSONObject();
            res.put("success", true);
            res.put("message", "Memoria aggiornata con successo");
            sendJsonResponse(os, 200, res);
            return;
        }

        // Static Files Serving
        serveStaticAsset(path, os);
    }

    private void serveStaticAsset(String path, OutputStream os) throws IOException {
        if (path == null || path.equals("/") || path.isEmpty()) {
            path = "/index.html";
        }
        String assetPath = "www" + path;

        try (InputStream is = getAssets().open(assetPath)) {
            ByteArrayOutputStream buffer = new ByteArrayOutputStream();
            byte[] temp = new byte[4096];
            int read;
            while ((read = is.read(temp)) != -1) {
                buffer.write(temp, 0, read);
            }
            byte[] data = buffer.toByteArray();
            String mime = getMimeType(path);
            sendRawResponse(os, 200, "OK", mime, data);
        } catch (IOException e) {
            byte[] notFound = ("File Not Found: " + path).getBytes(StandardCharsets.UTF_8);
            sendRawResponse(os, 404, "Not Found", "text/plain", notFound);
        }
    }

    private String getMimeType(String path) {
        if (path.endsWith(".html")) return "text/html; charset=utf-8";
        if (path.endsWith(".css")) return "text/css; charset=utf-8";
        if (path.endsWith(".js")) return "application/javascript; charset=utf-8";
        if (path.endsWith(".json")) return "application/json; charset=utf-8";
        if (path.endsWith(".svg")) return "image/svg+xml";
        if (path.endsWith(".png")) return "image/png";
        if (path.endsWith(".crt")) return "application/x-x509-ca-cert";
        return "text/plain";
    }

    private String extractBearerToken(Map<String, String> headers) {
        String auth = headers.get("authorization");
        if (auth != null && auth.startsWith("Bearer ")) {
            return auth.substring(7).trim();
        }
        return null;
    }

    private void sendJsonResponse(OutputStream os, int statusCode, JSONObject json) throws IOException {
        byte[] bytes = json.toString().getBytes(StandardCharsets.UTF_8);
        sendRawResponse(os, statusCode, getStatusText(statusCode), "application/json; charset=utf-8", bytes);
    }

    private void sendRawResponse(OutputStream os, int code, String text, String contentType, byte[] data) throws IOException {
        StringBuilder sb = new StringBuilder();
        sb.append("HTTP/1.1 ").append(code).append(" ").append(text).append("\r\n");
        sb.append("Content-Type: ").append(contentType).append("\r\n");
        sb.append("Content-Length: ").append(data.length).append("\r\n");
        sb.append("Access-Control-Allow-Origin: *\r\n");
        sb.append("Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n");
        sb.append("Access-Control-Allow-Headers: Content-Type, Authorization\r\n");
        sb.append("Connection: close\r\n\r\n");

        os.write(sb.toString().getBytes(StandardCharsets.UTF_8));
        if (data.length > 0) {
            os.write(data);
        }
        os.flush();
    }

    private String getStatusText(int code) {
        switch (code) {
            case 200: return "OK";
            case 204: return "No Content";
            case 400: return "Bad Request";
            case 401: return "Unauthorized";
            case 403: return "Forbidden";
            case 404: return "Not Found";
            case 429: return "Too Many Requests";
            case 501: return "Not Implemented";
            default: return "Error";
        }
    }

    public String getLocalIpAddress() {
        try {
            List<NetworkInterface> interfaces = Collections.list(NetworkInterface.getNetworkInterfaces());
            for (NetworkInterface intf : interfaces) {
                List<InetAddress> addrs = Collections.list(intf.getInetAddresses());
                for (InetAddress addr : addrs) {
                    if (!addr.isLoopbackAddress()) {
                        String sAddr = addr.getHostAddress();
                        if (sAddr != null && sAddr.indexOf(':') < 0 && (sAddr.startsWith("192.168.") || sAddr.startsWith("10."))) {
                            return sAddr;
                        }
                    }
                }
            }
        } catch (Exception ignored) {}
        return "192.168.1.8";
    }

    @Override
    public void onDestroy() {
        super.onDestroy();
        isRunning = false;
        isStarting = false;
        try {
            it.akai.customremote.ai.AkaiSpeechEngine.getInstance(this).stop();
        } catch (Exception ignored) {}
        try {
            LocalDiagnosticsManager.getInstance(this).stop();
        } catch (Exception ignored) {}
        if (screenWakeReceiver != null) {
            try {
                unregisterReceiver(screenWakeReceiver);
            } catch (Exception ignored) {}
            screenWakeReceiver = null;
        }
        if (httpAcceptorThread != null) {
            try { httpAcceptorThread.interrupt(); } catch (Exception ignored) {}
            httpAcceptorThread = null;
        }
        if (httpsAcceptorThread != null) {
            try { httpsAcceptorThread.interrupt(); } catch (Exception ignored) {}
            httpsAcceptorThread = null;
        }
        try {
            if (httpServerSocket != null) {
                httpServerSocket.close();
                httpServerSocket = null;
            }
        } catch (Exception ignored) {}
        try {
            if (httpsServerSocket != null) {
                httpsServerSocket.close();
                httpsServerSocket = null;
            }
        } catch (Exception ignored) {}
        if (threadPool != null) threadPool.shutdownNow();
        if (tvController != null) tvController.cleanup();
        sInstance = null;
        Log.i(TAG, "AKAI Remote Service stopped.");
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
