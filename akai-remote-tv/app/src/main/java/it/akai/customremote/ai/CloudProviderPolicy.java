package it.akai.customremote.ai;

import java.net.URI;
import java.util.Locale;

/**
 * Non-negotiable JARVIS cloud inference policy: only DeepSeek or Kimi.
 * This gate has no model runtime, no network access and no local inference.
 *
 * LOCAL_ONLY is an operational fallback for deterministic commands when cloud
 * is disabled/unavailable; it is NOT an AI provider or on-device LLM.
 */
public final class CloudProviderPolicy {
    public static final String DEEPSEEK = "deepseek";
    public static final String KIMI = "kimi";

    private CloudProviderPolicy() {}

    public static boolean isSupportedCloudProvider(String provider) {
        return DEEPSEEK.equals(provider) || KIMI.equals(provider);
    }

    /**
     * Checks the exact host, canonical port, scheme and path for the declared
     * provider. Prevents accidentally sending a Kimi API key to DeepSeek or
     * vice versa. No redirect should be followed by the HTTP transport.
     */
    public static boolean isApprovedDestination(String provider, String endpoint) {
        if (!isSupportedCloudProvider(provider) || endpoint == null) return false;
        try {
            URI uri = new URI(endpoint);
            if (!"https".equalsIgnoreCase(uri.getScheme()) ||
                    uri.getUserInfo() != null || uri.getRawFragment() != null ||
                    uri.getRawQuery() != null || (uri.getPort() != -1 && uri.getPort() != 443) ||
                    uri.getHost() == null) return false;
            String host = uri.getHost().toLowerCase(Locale.ROOT);
            String path = uri.getPath();
            if (DEEPSEEK.equals(provider)) {
                return "api.deepseek.com".equals(host) &&
                        "/chat/completions".equals(path);
            }
            return ("api.moonshot.ai".equals(host) || "api.moonshot.cn".equals(host)) &&
                    "/v1/chat/completions".equals(path);
        } catch (Exception ignored) {
            return false;
        }
    }

    /**
     * Explicit mock-only loopback, enabled only through the injected test
     * endpoint. Production calls must pass isApprovedDestination.
     */
    public static boolean isLoopbackTestDestination(String endpoint) {
        if (endpoint == null) return false;
        try {
            URI uri = new URI(endpoint);
            if (!"http".equalsIgnoreCase(uri.getScheme()) ||
                    uri.getUserInfo() != null || uri.getRawFragment() != null ||
                    uri.getHost() == null) return false;
            String host = uri.getHost().toLowerCase(Locale.ROOT);
            return "127.0.0.1".equals(host) || "localhost".equals(host);
        } catch (Exception ignored) {
            return false;
        }
    }
}
