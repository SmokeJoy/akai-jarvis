package it.akai.customremote.ai;

/**
 * Fail-closed local screen-projection privacy gate.
 * Explicit OS consent is mandatory, protected screens are blocked, and
 * JARVIS' own pairing/PIN UI is never eligible for capture.
 */
public final class VisionCapturePolicy {
    private VisionCapturePolicy() {}

    public static boolean mayCapture(boolean osConsent,
                                     ScreenPerceptionEngine.PerceptionSnapshot snapshot) {
        if (!osConsent || snapshot == null || snapshot.hasSensitiveFields) return false;
        String foreground = snapshot.foregroundPackage;
        return foreground != null && !foreground.trim().isEmpty()
                && !"it.akai.customremote".equals(foreground);
    }

    public static boolean withinBudget(int width, int height, long elapsedMs) {
        return width > 0 && height > 0 && width <= 960 && height <= 540
                && ((long) width * height) <= (960L * 540L)
                && elapsedMs >= 0 && elapsedMs <= 4500;
    }
}
