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
        void dismissPin();
    }

    private final SecurityManager securityManager;
    private final CommandHandler commandHandler;
    private final MemoryHandler memoryHandler;
    private final PinHandler pinHandler;
    private final String localIpAddress;
    private final int httpPort;

    public RestApiRouter(SecurityManager securityManager,
                         CommandHandler commandHandler,
                         MemoryHandler memoryHandler,
                         PinHandler pinHandler,
                         String localIpAddress,
                         int httpPort) {
        this.securityManager = securityManager;
        this.commandHandler = commandHandler;
        this.memoryHandler = memoryHandler;
        this.pinHandler = pinHandler;
        this.localIpAddress = (localIpAddress != null && !localIpAddress.isEmpty()) ? localIpAddress : "192.168.1.8";
        this.httpPort = httpPort > 0 ? httpPort : 8088;
    }

    public boolean routeRequest(String method, String path, Map<String, String> headers, String body, String clientIp, OutputStream os) throws Exception {
        // Subnet Verification (rifiuta IP esterni WAN non conformi a RFC 1918)
        if (!securityManager.isPrivateLanIp(clientIp)) {
            JSONObject err = new JSONObject().put("error", "Access denied: non-private LAN IP");
            sendJsonResponse(os, 403, err);
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
            String serverUrl = "http://" + localIpAddress + ":" + httpPort;
            if (pinHandler != null) {
                pinHandler.showPin(pin, remaining, serverUrl);
            }

            JSONObject res = new JSONObject();
            res.put("success", true);
            res.put("expires_in", remaining);
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
