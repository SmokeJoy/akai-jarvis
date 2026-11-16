package it.akai.customremote.ai;

/**
 * One-shot off-device visual inference. The TV does NOT run an AI model.
 * A screenshot can be sent ONLY to DeepSeek Flash or Kimi K2.6, with a
 * separate explicit owner action after Android's MediaProjection consent.
 * This class only validates prerequisites; it neither captures nor uploads.
 */
public final class CloudVisionRequestPolicy {
    public static final int MAX_IMAGE_BYTES = 256 * 1024;
    public static final int MAX_FRAME_WIDTH = 960;
    public static final int MAX_FRAME_HEIGHT = 540;

    private CloudVisionRequestPolicy() {}

    public static final class Verdict {
        public final boolean allowed;
        public final String reason;
        private Verdict(boolean allowed, String reason) {
            this.allowed = allowed;
            this.reason = reason;
        }
    }

    private static Verdict deny(String code) { return new Verdict(false, code); }

    public static String selectVisionModel(String provider) {
        if (CloudProviderPolicy.DEEPSEEK.equals(provider)) return "deepseek-flash";
        if (CloudProviderPolicy.KIMI.equals(provider)) return "kimi-k2.6";
        return null;
    }

    public static Verdict inspect(String provider, String model, boolean androidCaptureGranted,
                                  boolean separateCloudImageConsent, boolean cloudContextConsent,
                                  boolean sensitiveScreen, int width, int height, byte[] jpegBytes) {
        if (!CloudProviderPolicy.isSupportedCloudProvider(provider)) return deny("PROVIDER_NOT_ALLOWED");
        if (!selectVisionModel(provider).equals(model)) return deny("MODEL_NOT_VISION_APPROVED");
        if (!androidCaptureGranted) return deny("ANDROID_CAPTURE_NOT_CONSENTED");
        if (!separateCloudImageConsent) return deny("CLOUD_IMAGE_NOT_CONSENTED");
        if (!cloudContextConsent) return deny("CLOUD_CONTEXT_NOT_CONSENTED");
        if (sensitiveScreen) return deny("SENSITIVE_UI_BLOCKED");
        if (width < 1 || height < 1 || width > MAX_FRAME_WIDTH || height > MAX_FRAME_HEIGHT ||
                (long) width * (long) height > 960L * 540L) {
            return deny("FRAME_SIZE_INVALID");
        }
        if (jpegBytes == null || jpegBytes.length < 128 || jpegBytes.length > MAX_IMAGE_BYTES) {
            return deny("JPEG_SIZE_INVALID");
        }
        if ((jpegBytes[0] & 0xff) != 0xff || (jpegBytes[1] & 0xff) != 0xd8 ||
                (jpegBytes[jpegBytes.length - 2] & 0xff) != 0xff ||
                (jpegBytes[jpegBytes.length - 1] & 0xff) != 0xd9) {
            return deny("JPEG_MAGIC_INVALID");
        }
        return new Verdict(true, "CONSENTED_ONE_SHOT_IMAGE_ALLOWED");
    }
}
