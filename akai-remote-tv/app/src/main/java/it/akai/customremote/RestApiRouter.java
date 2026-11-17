package it.akai.customremote;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import org.json.JSONArray;
import org.json.JSONObject;

public class RestApiRouter {

    public interface CommandHandler {
        CommandResult executeCommand(String action);
        CommandResult injectText(String text);
        boolean isUInputReady();
    }

    public interface MemoryHandler {
        JSONArray getAllProcedures();
        JSONObject getAllPreferences();
        JSONObject getAllStats();
        JSONArray getRecentConversations(int limit);
        long getDatabaseSizeBytes();
        boolean isGuestMode();
        void setGuestMode(boolean enabled);
        void resetProcedures();
        void clearPersonalPreferencesOnly();
    }

    public interface PinHandler {
        void showPin(String pin, int remainingSeconds, String serverUrl);
        default void showPin(String pin, int remainingSeconds, String serverUrl, String caFingerprint) {
            showPin(pin, remainingSeconds, serverUrl);
        }
        void dismissPin();
    }

    public interface AiHandler {
        JSONObject processQuery(String query, boolean speak);
        boolean isStrictLocalOnly();
        JSONArray getSupportedCatalog();
        default boolean speak(String text, boolean interrupt) { return false; }
        default boolean previewVoice(String voice, String text) { return false; }
        default JSONObject testConnection(String requestBody) {
            JSONObject res = new JSONObject();
            try {
                res.put("success", false);
                res.put("message", "Test connessione non implementato su questo handler");
            } catch (Exception ignored) {}
            return res;
        }
        default JSONObject getSpeechStatus() {
            JSONObject s = new JSONObject();
            try {
                s.put("speaking", false);
                s.put("speech_state", "IDLE");
                s.put("speech_id", "");
                s.put("voice", "offline_local");
            } catch (Exception ignored) {}
            return s;
        }
        default JSONObject cancelCurrentTask() {
            JSONObject res = new JSONObject();
            try {
                res.put("success", false);
                res.put("status", "NOT_IMPLEMENTED");
                res.put("error", "Cancel non implementato su questo handler");
            } catch (Exception ignored) {}
            return res;
        }
    }

    private final SecurityManager securityManager;
    private final CommandHandler commandHandler;
    private final MemoryHandler memoryHandler;
    private final PinHandler pinHandler;
    private final AiHandler aiHandler;
    private final String localIpAddress;
    private final int httpPort;
    private TlsCertificateManager tlsCertificateManager = null;

    public void setTlsCertificateManager(TlsCertificateManager tlsCertificateManager) {
        this.tlsCertificateManager = tlsCertificateManager;
    }

    public TlsCertificateManager getTlsCertificateManager() {
        return tlsCertificateManager;
    }

    public RestApiRouter(SecurityManager securityManager,
                         CommandHandler commandHandler,
                         MemoryHandler memoryHandler,
                         PinHandler pinHandler,
                         AiHandler aiHandler,
                         String localIpAddress,
                         int httpPort) {
        this.securityManager = securityManager;
        this.commandHandler = commandHandler;
        this.memoryHandler = memoryHandler;
        this.pinHandler = pinHandler;
        this.aiHandler = aiHandler;
        this.localIpAddress = (localIpAddress != null && !localIpAddress.isEmpty()) ? localIpAddress : "127.0.0.1";
        this.httpPort = httpPort > 0 ? httpPort : 8088;
    }

    public RestApiRouter(SecurityManager securityManager,
                         CommandHandler commandHandler,
                         MemoryHandler memoryHandler,
                         PinHandler pinHandler,
                         String localIpAddress,
                         int httpPort) {
        this(securityManager, commandHandler, memoryHandler, pinHandler, null, localIpAddress, httpPort);
    }

    /**
     * Serve only public bundled web remote assets on legacy HTTP. No traversal
     * or API endpoint may be matched here. The caller still enforces LAN scope.
     */
    public static boolean isPublicRemoteAssetRequest(String method, String path) {
        if (!"GET".equals(method) || path == null) return false;
        if ("/".equals(path)) return true;
        if (!path.matches("/[A-Za-z0-9_./-]+") || path.contains("..") || path.contains("//")) return false;
        String lower = path.toLowerCase(java.util.Locale.US);
        return lower.endsWith(".html") || lower.endsWith(".css") || lower.endsWith(".js")
                || lower.endsWith(".json") || lower.endsWith(".svg") || lower.endsWith(".png")
                || lower.endsWith(".ico") || lower.endsWith(".webmanifest") || lower.endsWith(".webp");
    }

    public boolean routeRequest(String method, String path, Map<String, String> headers, String body, String clientIp, OutputStream os) throws Exception {
        return routeRequest(method, path, headers, body, clientIp, os, true);
    }

    public boolean routeRequest(String method, String path, Map<String, String> headers, String body, String clientIp, OutputStream os, boolean isTls) throws Exception {
        // Subnet Verification (rifiuta IP esterni WAN non conformi a RFC 1918)
        if (!securityManager.isPrivateLanIp(clientIp)) {
            JSONObject err = new JSONObject().put("error", "Access denied: non-private LAN IP");
            sendJsonResponse(os, 403, err);
            return true;
        }

        // Enforcement Sicurezza Canale Cifrato (P0):
        // Se la richiesta transita su HTTP in chiaro (porta 8088 / !isTls),
        // sono consentiti UNICAMENTE gli endpoint non-sensibili di bootstrap e trust onboarding:
        // 1. GET /api/status (handshake iniziale di raggiungibilità)
        // 2. GET /api/auth/ca.crt, /ca.crt, /ca.pem (download del certificato Root CA per installazione trust su smartphone)
        // 3. GET /api/auth/tls_info, /tls_info (metadati porta HTTPS 8443 e impronta anti-MITM)
        // 4. GET /setup, /bootstrap (guida HTML statica minima senza token per download CA)
        // Qualsiasi richiesta a endpoint sensibili (PIN pairing, token, comandi TV, modulo AI, memoria)
        // via HTTP in chiaro viene categoricamente RIFIUTATA con HTTP 426 Upgrade Required.
        boolean isBootstrapEndpoint = ("/api/status".equals(path) && "GET".equals(method)) ||
                                      (("/api/auth/ca.crt".equals(path) || "/ca.crt".equals(path) || "/ca.pem".equals(path)) && "GET".equals(method)) ||
                                      (("/api/auth/tls_info".equals(path) || "/tls_info".equals(path)) && "GET".equals(method)) ||
                                      (("/setup".equals(path) || "/bootstrap".equals(path)) && "GET".equals(method));

        // P0 Legacy Remote compatibility: exact old PIN/remote endpoints ONLY on private LAN.
        // Token/PIN on HTTP can be intercepted on an untrusted LAN; prefer TLS when available.
        // AI, cloud configuration, memory and diagnostics MUST remain HTTPS-only.
        boolean legacyRemoteHttp = "POST".equals(method) && (
                "/api/auth/pair/request".equals(path) ||
                "/api/auth/pair/verify".equals(path) ||
                "/api/auth/pair".equals(path) ||
                "/api/auth/revoke".equals(path) ||
                "/api/command".equals(path) ||
                "/api/control/command".equals(path) ||
                "/api/control/text".equals(path));

        if (!isTls && !isBootstrapEndpoint && !legacyRemoteHttp
                && !isPublicRemoteAssetRequest(method, path)) {
            JSONObject err = new JSONObject();
            err.put("success", false);
            err.put("error", "HTTPS_REQUIRED");
            err.put("status", "UPGRADE_REQUIRED");
            err.put("message", "Questo endpoint scambia credenziali, token o comandi TV ed è accessibile esclusivamente tramite HTTPS sicuro sulla porta 8443. Scarica la CA da /api/auth/ca.crt e utilizza HTTPS.");
            err.put("https_port", 8443);
            err.put("ca_download_url", "http://" + localIpAddress + ":" + httpPort + "/api/auth/ca.crt");
            err.put("bootstrap_url", "http://" + localIpAddress + ":" + httpPort + "/setup");
            sendJsonResponse(os, 426, err); // HTTP 426 Upgrade Required
            return true;
        }

        // Bootstrap Guide HTML (accesso in chiaro consentito senza token né credenziali)
        if (("/setup".equals(path) || "/bootstrap".equals(path)) && "GET".equals(method)) {
            String caFp = null;
            if (tlsCertificateManager != null) {
                TlsCertificateManager.TlsInfo info = tlsCertificateManager.getOrGenerateTlsInfo(null, localIpAddress);
                if (info != null) caFp = info.caFingerprintSha256;
            }
            if (caFp == null) caFp = "NON_CONFIGURATA";
            String html = "<!DOCTYPE html><html lang=\"it\"><head><meta charset=\"UTF-8\">" +
                "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1.0\">" +
                "<title>AKAI JARVIS TV - Bootstrap Sicurezza</title>" +
                "<style>body{font-family:sans-serif;background:#0a0d14;color:#e2e8f0;padding:20px;text-align:center;}" +
                ".card{background:#141824;border:1px solid #334155;border-radius:12px;max-width:540px;margin:16px auto;padding:20px;text-align:left;}" +
                ".card-warn{border-color:#ef4444;background:#1a0f14;}" +
                ".btn{display:block;background:#38bdf8;color:#0a0d14;text-decoration:none;font-weight:bold;padding:12px;border-radius:8px;text-align:center;margin:10px 0;}" +
                ".btn-sec{background:#1e293b;color:#38bdf8;border:1px solid #38bdf8;}" +
                "code{background:#040711;color:#34d399;padding:8px;border-radius:4px;word-break:break-all;font-size:12px;display:block;margin:8px 0;font-family:monospace;border:1px solid #1e293b;}" +
                "ul{padding-left:20px;font-size:12.5px;color:#cbd5e1;line-height:1.5;}" +
                "</style></head><body>" +
                "<h2>AKAI JARVIS · Onboarding Fuori Banda</h2>" +
                "<div class=\"card card-warn\">" +
                "<h3 style=\"color:#f87171;margin-top:0;\">&#9888;&#65039; Verifica Obbligatoria Fuori Banda (Anti-MITM)</h3>" +
                "<p style=\"font-size:13px;line-height:1.4;\">Il download iniziale della Root CA avviene via HTTP in chiaro locale non autenticato. " +
                "Prima di installare o considerare attendibile il certificato sullo smartphone, <strong>è tassativo confrontare l'impronta calcolata dal telefono con quella mostrata sullo schermo TV fisico</strong>. Se differiscono, non installare il certificato.</p>" +
                "<p style=\"font-size:12px;color:#94a3b8;\">Impronta SHA-256 ufficiale della TV:</p>" +
                "<code>" + caFp + "</code>" +
                "</div>" +
                "<div class=\"card\">" +
                "<h3>1. Scarica e Installa Certificato Root CA</h3>" +
                "<p>Scarica il file pubblico per abilitare HTTPS e Secure Context (necessario per microfono e Web Speech API):</p>" +
                "<a class=\"btn\" href=\"/api/auth/ca.crt\" download=\"akai_root_ca.crt\">📥 Scarica Certificato CA (ca.crt)</a>" +
                "<ul>" +
                "<li><strong>iOS:</strong> Scarica in Safari &gt; Impostazioni &gt; Profilo scaricato &gt; Installa. Poi vai in <em>Generali &gt; Info &gt; Attendibilità certificati</em> e abilita attendibilità totale.</li>" +
                "<li><strong>Android:</strong> Impostazioni &gt; Sicurezza &gt; Crittografia e credenziali &gt; Installa certificato &gt; Certificato CA &gt; Seleziona <code>ca.crt</code>.</li>" +
                "<li><strong>Revoca / Rotazione:</strong> Per dismettere la CA, rimuovi il certificato 'AKAI TV Local Root CA' dalle impostazioni di sistema del telefono.</li>" +
                "</ul>" +
                "</div>" +
                "<div class=\"card\">" +
                "<h3>2. Accedi al Telecomando Cifrato HTTPS</h3>" +
                "<p>Dopo aver verificato l'impronta e attivato l'attendibilità, apri il Web Remote sicuro:</p>" +
                "<a class=\"btn btn-sec\" href=\"https://" + localIpAddress + ":8443/\">🚀 Apri JARVIS Web Remote (HTTPS:8443)</a>" +
                "</div></body></html>";
            sendRawResponse(os, 200, "OK", "text/html; charset=UTF-8", html.getBytes(StandardCharsets.UTF_8));
            return true;
        }

        // Status
        if ("/api/status".equals(path) && "GET".equals(method)) {
            String token = extractBearerToken(headers);
            boolean authenticated = false;
            if (token != null) {
                if (securityManager.validateToken(token)) {
                    authenticated = true;
                } else {
                    sendJsonResponse(os, 401, new JSONObject().put("error", "Sessione scaduta o non valida"));
                    return true;
                }
            }
            JSONObject json = new JSONObject();
            json.put("status", "ok");
            json.put("authenticated", authenticated);
            json.put("service", "AKAI Custom Remote");
            json.put("version", "1.1.0");
            json.put("model", "AKTV5037N");
            json.put("active_sessions", securityManager.getActiveSessionCount());
            json.put("uinput_ready", commandHandler != null && commandHandler.isUInputReady());
            sendJsonResponse(os, 200, json);
            return true;
        }

        // TLS Info & CA Download (Milestone M2: Secure Context for Mobile Voice)
        if (("/api/auth/ca.crt".equals(path) || "/ca.pem".equals(path) || "/ca.crt".equals(path)) && "GET".equals(method)) {
            String caPem = null;
            if (tlsCertificateManager != null) {
                TlsCertificateManager.TlsInfo info = tlsCertificateManager.getOrGenerateTlsInfo(null, localIpAddress);
                if (info != null) caPem = info.caPem;
            }
            if (caPem != null && !caPem.isEmpty()) {
                byte[] raw = caPem.getBytes(StandardCharsets.UTF_8);
                sendRawResponse(os, 200, "OK", "application/x-x509-ca-cert", raw);
            } else {
                sendJsonResponse(os, 404, new JSONObject().put("error", "Certificato Root CA non ancora inizializzato"));
            }
            return true;
        }

        if ("/api/auth/tls_info".equals(path) && "GET".equals(method)) {
            TlsCertificateManager.TlsInfo info = (tlsCertificateManager != null) ?
                tlsCertificateManager.getOrGenerateTlsInfo(null, localIpAddress) : null;
            JSONObject out = new JSONObject();
            out.put("https_enabled", info != null);
            out.put("https_port", TlsCertificateManager.HTTPS_PORT);
            out.put("ca_fingerprint_sha256", info != null ? info.caFingerprintSha256 : "NON_CONFIGURATO");
            out.put("ca_sha256", info != null ? info.caFingerprintSha256 : "NON_CONFIGURATO");
            out.put("ca_download_url", "/api/auth/ca.crt");
            JSONArray sans = new JSONArray();
            if (info != null && info.serverSanList != null) {
                for (String san : info.serverSanList) sans.put(san);
            }
            out.put("san_list", sans);
            JSONObject guide = new JSONObject();
            guide.put("ios", "Scarica /api/auth/ca.crt in Safari, installa profilo in Impostazioni, abilita attendibilita totale in Generali > Info > Attendibilita certificati verificando l'impronta a schermo.");
            guide.put("android", "Installa /api/auth/ca.crt da Impostazioni > Sicurezza > Crittografia e credenziali > Installa certificato CA verificando l'impronta a schermo.");
            out.put("onboarding_guide", guide);
            sendJsonResponse(os, 200, out);
            return true;
        }

        // Pair Request
        if ("/api/auth/pair/request".equals(path) && "POST".equals(method)) {
            if (securityManager.isClientLockedOut(clientIp)) {
                long waitSec = securityManager.getLockoutRemainingSeconds(clientIp);
                JSONObject err = new JSONObject();
                err.put("error", "Troppi tentativi falliti. Riprova più tardi.");
                err.put("retry_after", waitSec);
                sendJsonResponse(os, 429, err);
                return true;
            }

            String pin = securityManager.generateNewPin();
            int remaining = securityManager.getPinRemainingSeconds();
            int targetPort = (tlsCertificateManager != null) ? TlsCertificateManager.HTTPS_PORT : httpPort;
            String scheme = (tlsCertificateManager != null) ? "https://" : "http://";
            String serverUrl = scheme + localIpAddress + ":" + targetPort;
            String caFp = null;
            if (tlsCertificateManager != null) {
                TlsCertificateManager.TlsInfo info = tlsCertificateManager.getOrGenerateTlsInfo(null, localIpAddress);
                if (info != null) caFp = info.caFingerprintSha256;
            }
            if (pinHandler != null) {
                pinHandler.showPin(pin, remaining, serverUrl, caFp);
            }

            JSONObject res = new JSONObject();
            res.put("success", true);
            res.put("expires_in", remaining);
            res.put("server_url", serverUrl);
            res.put("ca_download_url", "http://" + localIpAddress + ":" + httpPort + "/api/auth/ca.crt");
            if (caFp != null) {
                res.put("ca_fingerprint_sha256", caFp);
                res.put("ca_sha256", caFp);
            }
            sendJsonResponse(os, 200, res);
            return true;
        }

        // Pair Verify (Supports both /api/auth/pair/verify and /api/auth/pair)
        if (("/api/auth/pair/verify".equals(path) || "/api/auth/pair".equals(path)) && "POST".equals(method)) {
            if (securityManager.isClientLockedOut(clientIp)) {
                long waitSec = securityManager.getLockoutRemainingSeconds(clientIp);
                JSONObject err = new JSONObject();
                err.put("error", "Troppi tentativi falliti. Riprova più tardi.");
                err.put("retry_after", waitSec);
                sendJsonResponse(os, 429, err);
                return true;
            }

            JSONObject req = new JSONObject(body != null && !body.isEmpty() ? body : "{}");
            String pin = req.optString("pin", "").trim();
            String deviceName = req.optString("device_name", "Smartphone");
            String token = securityManager.verifyPinAndCreateToken(clientIp, pin, deviceName);
            if (token != null) {
                if (pinHandler != null) {
                    pinHandler.dismissPin();
                }
                JSONObject res = new JSONObject();
                res.put("success", true);
                res.put("token", token);
                sendJsonResponse(os, 200, res);
            } else {
                JSONObject err = new JSONObject();
                err.put("error", "Codice PIN non corretto o scaduto");
                sendJsonResponse(os, 401, err);
            }
            return true;
        }

        // Revoke Session
        if ("/api/auth/revoke".equals(path) && "POST".equals(method)) {
            String token = extractBearerToken(headers);
            if (token != null) {
                securityManager.revokeToken(token);
            }
            sendJsonResponse(os, 200, new JSONObject().put("success", true));
            return true;
        }

        // Control Command (Supports both /api/control/command and /api/command)
        if (("/api/control/command".equals(path) || "/api/command".equals(path)) && "POST".equals(method)) {
            String token = extractBearerToken(headers);
            if (!securityManager.validateToken(token)) {
                sendJsonResponse(os, 401, new JSONObject().put("error", "Non autorizzato: token non valido o scaduto"));
                return true;
            }

            JSONObject req = new JSONObject(body != null && !body.isEmpty() ? body : "{}");
            long timestamp = req.optLong("timestamp", 0);
            String nonce = req.optString("nonce", null);
            if (timestamp > 0 && nonce != null) {
                if (!securityManager.validateReplayProtection(timestamp, nonce)) {
                    sendJsonResponse(os, 403, new JSONObject().put("error", "Richiesta respinta: replay check fallito (timestamp o nonce non validi)"));
                    return true;
                }
            }

            String action = req.optString("action", "");
            CommandResult res;
            if ("type_text".equals(action) || "text".equals(action)) {
                String text = req.optString("text", "");
                res = commandHandler != null ? commandHandler.injectText(text) : new CommandResult(false, "Handler comandi non disponibile");
            } else {
                res = commandHandler != null ? commandHandler.executeCommand(action) : new CommandResult(false, "Handler comandi non disponibile");
            }

            JSONObject out = new JSONObject();
            out.put("success", res.success);
            out.put("message", res.message);
            out.put("unsupported", res.unsupported);

            int code = res.unsupported ? 501 : (res.success ? 200 : 400);
            sendJsonResponse(os, code, out);
            return true;
        }

        // Control Text (/api/control/text)
        if ("/api/control/text".equals(path) && "POST".equals(method)) {
            String token = extractBearerToken(headers);
            if (!securityManager.validateToken(token)) {
                sendJsonResponse(os, 401, new JSONObject().put("error", "Non autorizzato: token mancante o scaduto"));
                return true;
            }

            JSONObject req = new JSONObject(body != null && !body.isEmpty() ? body : "{}");
            long timestamp = req.optLong("timestamp", 0);
            String nonce = req.optString("nonce", null);
            if (timestamp > 0 && nonce != null) {
                if (!securityManager.validateReplayProtection(timestamp, nonce)) {
                    sendJsonResponse(os, 403, new JSONObject().put("error", "Richiesta respinta: replay check fallito"));
                    return true;
                }
            }

            String text = req.optString("text", "");
            CommandResult res = commandHandler != null ? commandHandler.injectText(text) : new CommandResult(false, "Handler non disponibile");
            JSONObject out = new JSONObject();
            out.put("success", res.success);
            out.put("message", res.message);
            sendJsonResponse(os, res.success ? 200 : 400, out);
            return true;
        }

        // AI Memory, Procedures & Conversations History (/api/ai/memory)
        if ("/api/ai/memory".equals(path) && "GET".equals(method)) {
            String token = extractBearerToken(headers);
            if (!securityManager.validateToken(token)) {
                sendJsonResponse(os, 401, new JSONObject().put("error", "Non autorizzato: token mancante o scaduto"));
                return true;
            }

            if (memoryHandler == null) {
                sendJsonResponse(os, 500, new JSONObject().put("error", "Memory Engine non configurato"));
                return true;
            }

            boolean isGuest = memoryHandler.isGuestMode();
            JSONObject out = new JSONObject();
            JSONArray allProcs = memoryHandler.getAllProcedures();
            JSONArray safeProcs = new JSONArray();
            if (allProcs != null) {
                for (int i = 0; i < allProcs.length(); i++) {
                    JSONObject p = allProcs.optJSONObject(i);
                    if (p != null) {
                        if (isGuest && (p.optInt("is_personal", 0) == 1 || p.optBoolean("is_personal", false))) {
                            continue; // Escludi procedure personali in modalità Guest/Ospite
                        }
                        safeProcs.put(p);
                    }
                }
            }
            out.put("procedures", safeProcs);
            out.put("preferences", isGuest ? new JSONObject() : memoryHandler.getAllPreferences());
            out.put("stats", memoryHandler.getAllStats());
            JSONArray recents = isGuest ? new JSONArray() : memoryHandler.getRecentConversations(20);
            out.put("conversations", recents);
            out.put("recent_conversations", recents);
            long dbBytes = memoryHandler.getDatabaseSizeBytes();
            out.put("db_size_bytes", dbBytes);
            out.put("db_size_kb", dbBytes / 1024.0);
            out.put("db_limit_bytes", 15 * 1024 * 1024L);
            out.put("guest_mode", isGuest);

            sendJsonResponse(os, 200, out);
            return true;
        }

        // AI Guest Mode Toggle
        if ("/api/ai/guest_mode".equals(path) && "POST".equals(method)) {
            String token = extractBearerToken(headers);
            if (!securityManager.validateToken(token)) {
                sendJsonResponse(os, 401, new JSONObject().put("error", "Non autorizzato: token mancante o scaduto"));
                return true;
            }
            if (memoryHandler == null) {
                sendJsonResponse(os, 500, new JSONObject().put("error", "Memory Engine non configurato"));
                return true;
            }

            JSONObject req = new JSONObject(body != null && !body.isEmpty() ? body : "{}");
            boolean enabled = req.optBoolean("enabled", false);
            memoryHandler.setGuestMode(enabled);

            JSONObject res = new JSONObject();
            res.put("success", true);
            res.put("guest_mode", memoryHandler.isGuestMode());
            sendJsonResponse(os, 200, res);
            return true;
        }

        // AI Query / Local Intent (/api/ai/ask & /api/control/ai & /api/ai/query)
        if (("/api/ai/ask".equals(path) || "/api/control/ai".equals(path) || "/api/ai/query".equals(path)) && "POST".equals(method)) {
            String token = extractBearerToken(headers);
            if (!securityManager.validateToken(token)) {
                sendJsonResponse(os, 401, new JSONObject().put("error", "Non autorizzato: token mancante o scaduto"));
                return true;
            }

            JSONObject req = new JSONObject(body != null && !body.isEmpty() ? body : "{}");
            String query = req.optString("query", "").trim();
            if (query.isEmpty()) {
                query = req.optString("text", "").trim();
            }
            boolean speak = req.optBoolean("speak", false);

            if (aiHandler == null) {
                // Fail-closed rigoroso: nessun fallback unmonitored se il controller AI non è registrato/pronto
                JSONObject err = new JSONObject();
                err.put("success", false);
                err.put("error", "Servizio AI/Intent non disponibile o in fase di avvio");
                err.put("status", "SERVICE_UNAVAILABLE");
                sendJsonResponse(os, 503, err);
                return true;
            }

            JSONObject res = aiHandler.processQuery(query, speak);
            int status = res.optBoolean("success", false) ? 200 : 400;
            sendJsonResponse(os, status, res);
            return true;
        }

        // AI Active Task Cancel / Stop (/api/ai/cancel, /api/ai/stop & /api/control/ai/cancel)
        if (("/api/ai/cancel".equals(path) || "/api/ai/stop".equals(path) || "/api/control/ai/cancel".equals(path)) && "POST".equals(method)) {
            String token = extractBearerToken(headers);
            if (!securityManager.validateToken(token)) {
                sendJsonResponse(os, 401, new JSONObject().put("error", "Non autorizzato: token mancante o scaduto"));
                return true;
            }
            if (aiHandler == null) {
                JSONObject err = new JSONObject();
                err.put("success", false);
                err.put("error", "Servizio AI/Intent non disponibile o in fase di avvio");
                err.put("status", "SERVICE_UNAVAILABLE");
                sendJsonResponse(os, 503, err);
                return true;
            }
            JSONObject res = aiHandler.cancelCurrentTask();
            sendJsonResponse(os, 200, res != null ? res : new JSONObject().put("success", true));
            return true;
        }

        // AI Catalog (/api/ai/catalog & /api/control/ai/catalog)
        if (("/api/ai/catalog".equals(path) || "/api/control/ai/catalog".equals(path)) && "GET".equals(method)) {
            String token = extractBearerToken(headers);
            if (!securityManager.validateToken(token)) {
                sendJsonResponse(os, 401, new JSONObject().put("error", "Non autorizzato: token mancante o scaduto"));
                return true;
            }

            boolean strictLocal = (aiHandler == null) || aiHandler.isStrictLocalOnly();
            JSONObject out = new JSONObject();
            out.put("strict_local_only", strictLocal);
            out.put("local_only_profile", strictLocal);
            out.put("cloud_disabled", strictLocal);
            out.put("execution_mode", strictLocal ? "LOCAL_ONLY" : "CLOUD_OPTIONAL");
            out.put("offline_guaranteed", false);
            out.put("offline_validation_pending", true);
            out.put("supported_commands", aiHandler != null ? aiHandler.getSupportedCatalog() : it.akai.customremote.ai.LocalIntentParser.getSupportedCatalog());
            sendJsonResponse(os, 200, out);
            return true;
        }

        // Test connessione provider AI (/api/ai/test_connection): bloccato in LOCAL_ONLY, delegato in CLOUD_OPTIONAL
        if ("/api/ai/test_connection".equals(path) && "POST".equals(method)) {
            String token = extractBearerToken(headers);
            if (!securityManager.validateToken(token)) {
                sendJsonResponse(os, 401, new JSONObject().put("error", "Non autorizzato: token mancante o scaduto"));
                return true;
            }

            if (aiHandler == null || aiHandler.isStrictLocalOnly()) {
                JSONObject err = new JSONObject();
                err.put("success", false);
                err.put("error", "Chiamate verso provider cloud disabilitate nel profilo STRICT_LOCAL_ONLY");
                err.put("strict_local_only", true);
                sendJsonResponse(os, 403, err);
                return true;
            }

            JSONObject testRes = aiHandler.testConnection(body != null ? body : "{}");
            sendJsonResponse(os, 200, testRes != null ? testRes : new JSONObject().put("success", false));
            return true;
        }

        // AI Direct Speech Playback (/api/ai/speak)
        if ("/api/ai/speak".equals(path) && "POST".equals(method)) {
            String token = extractBearerToken(headers);
            if (!securityManager.validateToken(token)) {
                sendJsonResponse(os, 401, new JSONObject().put("error", "Non autorizzato: token mancante o scaduto"));
                return true;
            }

            JSONObject req = new JSONObject(body != null && !body.isEmpty() ? body : "{}");
            String textToSpeak = req.optString("text", "");
            boolean interrupt = req.optBoolean("interrupt", true);

            boolean queued = false;
            if (aiHandler != null) {
                queued = aiHandler.speak(textToSpeak, interrupt);
            }

            JSONObject out = new JSONObject();
            out.put("success", queued);
            out.put("spoken", textToSpeak);
            out.put("strict_local_only", aiHandler != null ? aiHandler.isStrictLocalOnly() : true);
            sendJsonResponse(os, queued ? 200 : 500, out);
            return true;
        }

        // AI Speech Status Polling (/api/ai/speech_status)
        if ("/api/ai/speech_status".equals(path) && "GET".equals(method)) {
            String token = extractBearerToken(headers);
            if (!securityManager.validateToken(token)) {
                sendJsonResponse(os, 401, new JSONObject().put("error", "Non autorizzato: token mancante o scaduto"));
                return true;
            }
            if (aiHandler == null) {
                JSONObject err = new JSONObject();
                err.put("success", false);
                err.put("status", "SERVICE_UNAVAILABLE");
                err.put("error", "AI Speech Engine non inizializzato");
                sendJsonResponse(os, 503, err);
                return true;
            }
            JSONObject status = aiHandler.getSpeechStatus();
            sendJsonResponse(os, 200, status != null ? status : new JSONObject().put("speaking", false).put("speech_state", "IDLE"));
            return true;
        }

        // TTS configuration is always offline-only, independently of AI cloud mode.
        if ("/api/ai/tts_config".equals(path) && "GET".equals(method)) {
            String token = extractBearerToken(headers);
            if (!securityManager.validateToken(token)) {
                sendJsonResponse(os, 401, new JSONObject().put("error", "Non autorizzato"));
                return true;
            }
            JSONObject cfg = new JSONObject();
            cfg.put("active_voice", "offline_espeak");
            cfg.put("speech_provider_policy", "OFFLINE_ONLY");
            cfg.put("cloud_tts_enabled", false);
            cfg.put("cache_size_kb", 0);
            cfg.put("max_cache_mb", 0);
            sendJsonResponse(os, 200, cfg);
            return true;
        }

        // AI Voice Preview (/api/ai/tts_preview)
        if ("/api/ai/tts_preview".equals(path) && "POST".equals(method)) {
            String token = extractBearerToken(headers);
            if (!securityManager.validateToken(token)) {
                sendJsonResponse(os, 401, new JSONObject().put("error", "Non autorizzato: token mancante o scaduto"));
                return true;
            }

            JSONObject req = new JSONObject(body != null && !body.isEmpty() ? body : "{}");
            String voice = req.optString("voice", "it-IT-DiegoNeural");
            boolean localOnly = aiHandler != null ? aiHandler.isStrictLocalOnly() : true;

            if (!"offline_espeak".equals(voice)) {
                JSONObject err = new JSONObject();
                err.put("success", false);
                err.put("error", "Voci cloud vietate dalla policy OFFLINE_ONLY (STRICT_LOCAL_ONLY e CLOUD_OPTIONAL)");
                err.put("strict_local_only", true);
                sendJsonResponse(os, 403, err);
                return true;
            }

            boolean started = false;
            if (aiHandler != null) {
                started = aiHandler.previewVoice(voice, req.optString("text", ""));
            }

            JSONObject out = new JSONObject();
            out.put("success", started);
            out.put("voice", voice);
            out.put("strict_local_only", localOnly);
            sendJsonResponse(os, started ? 200 : 500, out);
            return true;
        }

        // Only the built-in eSpeak profile is configurable. Historical Azure
        // credentials, regions and voice names must never be accepted in cloud mode.
        if ("/api/ai/tts_config".equals(path) && "POST".equals(method)) {
            String token = extractBearerToken(headers);
            if (!securityManager.validateToken(token)) {
                sendJsonResponse(os, 401, new JSONObject().put("error", "Non autorizzato"));
                return true;
            }
            JSONObject req = new JSONObject(body != null && !body.isEmpty() ? body : "{}");
            String voice = req.optString("voice", "offline_espeak");
            if (!"offline_espeak".equals(voice) || req.has("azure_key") || req.has("azure_region")) {
                JSONObject err = new JSONObject();
                err.put("success", false);
                err.put("error", "TTS esterno vietato dalla policy OFFLINE_ONLY (anche in STRICT_LOCAL_ONLY e CLOUD_OPTIONAL)");
                err.put("strict_local_only", aiHandler == null || aiHandler.isStrictLocalOnly());
                err.put("speech_provider_policy", "OFFLINE_ONLY");
                sendJsonResponse(os, 403, err);
                return true;
            }
            JSONObject out = new JSONObject();
            out.put("success", true);
            out.put("active_voice", "offline_espeak");
            out.put("speech_provider_policy", "OFFLINE_ONLY");
            sendJsonResponse(os, 200, out);
            return true;
        }

        return false;
    }

    public static String extractBearerToken(Map<String, String> headers) {
        if (headers == null) return null;
        String auth = headers.get("authorization");
        if (auth == null || !auth.toLowerCase().startsWith("bearer ")) {
            return null;
        }
        return auth.substring(7).trim();
    }

    public static void sendJsonResponse(OutputStream os, int statusCode, JSONObject json) throws IOException {
        byte[] bytes = json.toString().getBytes(StandardCharsets.UTF_8);
        sendRawResponse(os, statusCode, getStatusText(statusCode), "application/json; charset=utf-8", bytes);
    }

    public static void sendRawResponse(OutputStream os, int code, String text, String contentType, byte[] data) throws IOException {
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

    public static String getStatusText(int code) {
        switch (code) {
            case 200: return "OK";
            case 204: return "No Content";
            case 400: return "Bad Request";
            case 401: return "Unauthorized";
            case 403: return "Forbidden";
            case 404: return "Not Found";
            case 413: return "Payload Too Large";
            case 429: return "Too Many Requests";
            case 431: return "Request Header Fields Too Large";
            case 501: return "Not Implemented";
            default:  return "Internal Server Error";
        }
    }
}
