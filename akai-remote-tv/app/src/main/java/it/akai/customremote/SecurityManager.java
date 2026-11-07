package it.akai.customremote;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.Log;
import java.security.SecureRandom;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

public class SecurityManager {
    private static final String TAG = "AKAI_SecurityManager";
    private static final String PREF_NAME = "akai_remote_sessions";
    private static final int PIN_VALIDITY_SECONDS = 120;
    private static final int MAX_FAILED_ATTEMPTS = 3;
    private static final long LOCKOUT_DURATION_MS = 5 * 60 * 1000; // 5 minuti
    public static final long SESSION_LIFETIME_MS = 30L * 24 * 60 * 60 * 1000; // 30 giorni

    private final SecureRandom random = new SecureRandom();
    private String currentPin = null;
    private long pinExpiryTimestamp = 0;
    private SharedPreferences sharedPreferences = null;

    // Track active bearer tokens: Token -> SessionInfo
    private final Map<String, SessionInfo> activeSessions = new ConcurrentHashMap<>();

    // Track failed attempts per IP for brute-force prevention
    private final Map<String, BruteForceTracker> failedAttempts = new ConcurrentHashMap<>();

    // Replay Protection: nonces visti negli ultimi 60 secondi
    private final Map<String, Long> seenNonces = new ConcurrentHashMap<>();

    public static class SessionInfo {
        public final String clientIp;
        public final String deviceName;
        public final long createdAt;
        public long expiresAt;

        public SessionInfo(String clientIp, String deviceName, long createdAt, long expiresAt) {
            this.clientIp = clientIp;
            this.deviceName = (deviceName != null && !deviceName.isEmpty()) ? deviceName : "Dispositivo sconosciuto";
            this.createdAt = createdAt;
            this.expiresAt = expiresAt;
        }

        public boolean isExpired() {
            return System.currentTimeMillis() > expiresAt;
        }
    }

    private static class BruteForceTracker {
        int count = 0;
        long lockedUntil = 0;
    }

    public SecurityManager() {
        // Purely in-memory mode (for JUnit and host-side tests)
    }

    public SecurityManager(Context context) {
        if (context != null) {
            try {
                this.sharedPreferences = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE);
                loadPersistedSessions();
            } catch (Throwable t) {
                Log.w(TAG, "SharedPreferences unavailable: " + t.getMessage());
            }
        }
    }

    private synchronized void loadPersistedSessions() {
        if (sharedPreferences == null) return;
        try {
            Map<String, ?> all = sharedPreferences.getAll();
            if (all == null) return;
            long now = System.currentTimeMillis();
            int loaded = 0;
            SharedPreferences.Editor editor = null;

            for (Map.Entry<String, ?> entry : all.entrySet()) {
                String token = entry.getKey();
                Object val = entry.getValue();
                if (val instanceof String) {
                    String[] parts = ((String) val).split("\\|", 4);
                    if (parts.length == 4) {
                        try {
                            String clientIp = parts[0];
                            String deviceName = parts[1];
                            long createdAt = Long.parseLong(parts[2]);
                            long expiresAt = Long.parseLong(parts[3]);
                            if (now < expiresAt) {
                                activeSessions.put(token, new SessionInfo(clientIp, deviceName, createdAt, expiresAt));
                                loaded++;
                            } else {
                                if (editor == null) editor = sharedPreferences.edit();
                                editor.remove(token);
                            }
                        } catch (Exception ignored) {}
                    }
                }
            }
            if (editor != null) editor.apply();
            Log.i(TAG, "Loaded " + loaded + " active persistent remote sessions from storage.");
        } catch (Throwable t) {
            Log.e(TAG, "Error loading persisted sessions: " + t.getMessage());
        }
    }

    public synchronized String generateNewPin() {
        int code = 100000 + random.nextInt(900000);
        currentPin = String.valueOf(code);
        pinExpiryTimestamp = System.currentTimeMillis() + (PIN_VALIDITY_SECONDS * 1000);
        Log.i(TAG, "Generated new 6-digit PIN (valid for " + PIN_VALIDITY_SECONDS + "s)");
        return currentPin;
    }

    public synchronized String getCurrentPin() {
        if (currentPin != null && System.currentTimeMillis() <= pinExpiryTimestamp) {
            return currentPin;
        }
        return null;
    }

    public synchronized int getPinRemainingSeconds() {
        long remaining = (pinExpiryTimestamp - System.currentTimeMillis()) / 1000;
        return (int) Math.max(0, remaining);
    }

    public synchronized boolean isClientLockedOut(String clientIp) {
        BruteForceTracker tracker = failedAttempts.get(clientIp);
        if (tracker != null && System.currentTimeMillis() < tracker.lockedUntil) {
            return true;
        }
        return false;
    }

    public synchronized long getLockoutRemainingSeconds(String clientIp) {
        BruteForceTracker tracker = failedAttempts.get(clientIp);
        if (tracker != null && tracker.lockedUntil > System.currentTimeMillis()) {
            return (tracker.lockedUntil - System.currentTimeMillis()) / 1000;
        }
        return 0;
    }

    public synchronized String verifyPinAndCreateToken(String clientIp, String submittedPin) {
        return verifyPinAndCreateToken(clientIp, submittedPin, "Dispositivo mobile");
    }

    public synchronized String verifyPinAndCreateToken(String clientIp, String submittedPin, String deviceName) {
        if (isClientLockedOut(clientIp)) {
            Log.w(TAG, "Client " + clientIp + " attempted pairing while locked out!");
            return null;
        }

        if (currentPin == null || System.currentTimeMillis() > pinExpiryTimestamp) {
            Log.w(TAG, "Pairing attempt with expired/uninitialized PIN from " + clientIp);
            recordFailedAttempt(clientIp);
            return null;
        }

        if (!currentPin.equals(submittedPin)) {
            Log.w(TAG, "Invalid PIN submitted from " + clientIp);
            recordFailedAttempt(clientIp);
            return null;
        }

        // Correct PIN! Reset brute-force counter and expire PIN
        failedAttempts.remove(clientIp);
        currentPin = null;
        pinExpiryTimestamp = 0;

        // Generate 256-bit cryptographically secure Bearer token
        byte[] tokenBytes = new byte[32];
        random.nextBytes(tokenBytes);
        StringBuilder sb = new StringBuilder();
        for (byte b : tokenBytes) {
            sb.append(String.format("%02x", b));
        }
        String token = sb.toString();

        // 30 days session validity
        long now = System.currentTimeMillis();
        long expiresAt = now + SESSION_LIFETIME_MS;
        String safeDeviceName = (deviceName != null) ? deviceName.replace("|", "_") : "Dispositivo sconosciuto";
        SessionInfo session = new SessionInfo(clientIp, safeDeviceName, now, expiresAt);
        activeSessions.put(token, session);

        // Persist to SharedPreferences synchronously
        if (sharedPreferences != null) {
            String record = clientIp + "|" + safeDeviceName + "|" + now + "|" + expiresAt;
            sharedPreferences.edit().putString(token, record).commit();
        }

        Log.i(TAG, "Successfully paired client " + clientIp + " (" + safeDeviceName + "). Issued persistent bearer token.");
        return token;
    }

    public synchronized void touchSession(String token) {
        if (token == null) return;
        SessionInfo session = activeSessions.get(token);
        if (session != null && !session.isExpired()) {
            long newExpiry = System.currentTimeMillis() + SESSION_LIFETIME_MS;
            session.expiresAt = newExpiry;
            if (sharedPreferences != null) {
                String record = session.clientIp + "|" + session.deviceName + "|" + session.createdAt + "|" + newExpiry;
                sharedPreferences.edit().putString(token, record).apply();
            }
        }
    }

    public synchronized boolean validateReplayProtection(long clientTimestamp, String nonce) {
        long now = System.currentTimeMillis();
        // Finestra temporale di tolleranza di 30 secondi (per compensare clock drift tra telefono e TV)
        if (Math.abs(now - clientTimestamp) > 30000) {
            Log.w(TAG, "Replay check fallito: timestamp fuori finestra (" + Math.abs(now - clientTimestamp) + "ms diff)");
            return false;
        }
        if (nonce == null || nonce.trim().length() < 6) {
            Log.w(TAG, "Replay check fallito: nonce assente o troppo corto");
            return false;
        }
        if (seenNonces.containsKey(nonce)) {
            Log.w(TAG, "Replay check fallito: nonce duplicato '" + nonce + "' rilevato! Possibile attacco replay.");
            return false;
        }
        seenNonces.put(nonce, now);

        // Pulizia periodica dei nonce più vecchi di 60 secondi
        if (seenNonces.size() > 150) {
            for (Map.Entry<String, Long> entry : seenNonces.entrySet()) {
                if (now - entry.getValue() > 60000) {
                    seenNonces.remove(entry.getKey());
                }
            }
        }
        return true;
    }

    private void recordFailedAttempt(String clientIp) {
        BruteForceTracker tracker = failedAttempts.get(clientIp);
        if (tracker == null) {
            tracker = new BruteForceTracker();
            failedAttempts.put(clientIp, tracker);
        }
        tracker.count++;
        if (tracker.count >= MAX_FAILED_ATTEMPTS) {
            tracker.lockedUntil = System.currentTimeMillis() + LOCKOUT_DURATION_MS;
            Log.w(TAG, "Client " + clientIp + " locked out for 5 minutes after " + tracker.count + " failed attempts.");
        }
    }

    public boolean validateToken(String token) {
        if (token == null || token.isEmpty()) return false;
        SessionInfo session = activeSessions.get(token);
        if (session == null) return false;
        if (session.isExpired()) {
            activeSessions.remove(token);
            if (sharedPreferences != null) {
                sharedPreferences.edit().remove(token).apply();
            }
            return false;
        }
        // Auto-refresh sliding window session
        touchSession(token);
        return true;
    }

    public void revokeToken(String token) {
        if (token != null) {
            activeSessions.remove(token);
            if (sharedPreferences != null) {
                sharedPreferences.edit().remove(token).commit();
            }
            Log.i(TAG, "Revoked token: " + token.substring(0, Math.min(8, token.length())) + "...");
        }
    }

    public void revokeAll() {
        activeSessions.clear();
        currentPin = null;
        if (sharedPreferences != null) {
            sharedPreferences.edit().clear().commit();
        }
        Log.i(TAG, "Revoked all active sessions and cleared persistent storage.");
    }

    public int getActiveSessionCount() {
        return activeSessions.size();
    }

    public boolean isPrivateLanIp(String ip) {
        if (ip == null) return false;
        if (ip.equals("127.0.0.1") || ip.equals("::1")) return true;
        return ip.startsWith("192.168.") || ip.startsWith("10.") || ip.matches("^172\\.(1[6-9]|2[0-9]|3[0-1])\\..*");
    }
}
