package it.akai.customremote.ai;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Locale;
import java.util.concurrent.atomic.AtomicReference;
import java.util.regex.Pattern;

/**
 * Ephemeral, single-use bridge from an explicitly owner-approved remote visual
 * DESCRIPTION into the NEXT cloud planner request. No model executes on-TV.
 * Observations are untrusted hints, NOT click authorization or goal evidence.
 * They are never persisted, sent over LAN, or reused during replanning.
 */
public final class VisualObservationBridge {
    public static final long MAX_AGE_MS = 45_000L;
    public static final int MAX_DESCRIPTION_CHARS = 480;
    private static final Pattern PACKAGE = Pattern.compile(
            "^[A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)+$");
    private static final Pattern EMAIL = Pattern.compile(
            "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}");
    private static final Pattern SECRET = Pattern.compile(
            "(?i)(?:sk-[A-Za-z0-9_-]{8,}|bearer\\s+[A-Za-z0-9._-]{8,})");
    private static final Pattern PHONE_OR_PIN = Pattern.compile(
            "(?:\\+?\\d[\\d\\s-]{6,}\\d|\\b\\d{6,}\\b)");
    private static final Pattern PROMPT_INJECTION = Pattern.compile(
            "(?i)(?:ignore\\s+(?:all\\s+)?(?:previous|prior)\\s+instructions"
            + "|(?:system|developer|assistant)\\s*:"
            + "|\\{\\s*\\\"actions\\\"\\s*:|\\\"actions\\\"\\s*:\\s*\\[)");
    private static final AtomicReference<Pending> PENDING = new AtomicReference<>();

    private VisualObservationBridge() {}

    private static final class Pending {
        final String provider;
        final String packageName;
        final String fingerprint;
        final String sanitizedDescription;
        final long capturedAtMs;

        Pending(String provider, String packageName, String fingerprint,
                String sanitizedDescription, long capturedAtMs) {
            this.provider = provider;
            this.packageName = packageName;
            this.fingerprint = fingerprint;
            this.sanitizedDescription = sanitizedDescription;
            this.capturedAtMs = capturedAtMs;
        }
    }

    public static String fingerprint(String redactedUiContext) {
        if (redactedUiContext == null || redactedUiContext.isEmpty()) return "";
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                    .digest(redactedUiContext.getBytes(StandardCharsets.UTF_8));
            StringBuilder out = new StringBuilder(64);
            for (byte b : digest) out.append(String.format(Locale.ROOT, "%02x", b & 0xff));
            return out.toString();
        } catch (Exception ignored) {
            return "";
        }
    }

    /** Fail-closed on any unknown/unsafe provider, changed UI, invalid timestamp or injection. */
    public static boolean publish(String provider, String foregroundPackage,
                                  String redactedUiContext, String rawDescription,
                                  long capturedAtMs, long nowMs) {
        clear(); // A new attempt can never accidentally reuse an older observation.
        if (!CloudProviderPolicy.isSupportedCloudProvider(provider)
                || foregroundPackage == null || !PACKAGE.matcher(foregroundPackage).matches()
                || nowMs < capturedAtMs || capturedAtMs <= 0L
                || nowMs - capturedAtMs > MAX_AGE_MS
                || rawDescription == null || rawDescription.trim().isEmpty()
                || PROMPT_INJECTION.matcher(rawDescription).find()) return false;
        String fp = fingerprint(redactedUiContext);
        if (fp.isEmpty()) return false;
        String cleaned = rawDescription.replaceAll("[\\r\\n\\t\\p{Cntrl}]+", " ").trim();
        cleaned = SECRET.matcher(cleaned).replaceAll("[REDACTED_SECRET]");
        cleaned = EMAIL.matcher(cleaned).replaceAll("[REDACTED_EMAIL]");
        cleaned = PHONE_OR_PIN.matcher(cleaned).replaceAll("[REDACTED_NUMBER]");
        if (cleaned.length() > MAX_DESCRIPTION_CHARS) {
            cleaned = cleaned.substring(0, MAX_DESCRIPTION_CHARS);
        }
        if (cleaned.isEmpty()) return false;
        PENDING.set(new Pending(provider, foregroundPackage, fp, cleaned, capturedAtMs));
        return true;
    }

    /**
     * At-most-once read. A fresh Accessibility snapshot must match BOTH the
     * source package and its sanitized UI-state fingerprint; otherwise discard.
     * Never returns a hint for sensitive or unknown UI.
     */
    public static String consume(String provider, String foregroundPackage,
                                 String currentRedactedUiContext,
                                 boolean sensitiveScreen, long nowMs) {
        Pending prior = PENDING.getAndSet(null);
        if (prior == null || sensitiveScreen
                || !CloudProviderPolicy.isSupportedCloudProvider(provider)
                || !prior.provider.equals(provider)
                || foregroundPackage == null
                || !prior.packageName.equals(foregroundPackage)
                || nowMs < prior.capturedAtMs
                || nowMs - prior.capturedAtMs > MAX_AGE_MS) return "";
        String currentFp = fingerprint(currentRedactedUiContext);
        return prior.fingerprint.equals(currentFp) ? prior.sanitizedDescription : "";
    }

    public static void clear() {
        PENDING.set(null);
    }
}
