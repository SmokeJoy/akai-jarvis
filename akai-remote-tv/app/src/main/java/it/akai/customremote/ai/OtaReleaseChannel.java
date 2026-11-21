package it.akai.customremote.ai;

import android.content.Context;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.Locale;
import java.util.Set;

/**
 * Owner-bundled immutable OTA channel; no downloaded configuration, secrets,
 * auto-discovery or GitHub token. The original-signed Android APK is the trust
 * boundary for this exact HTTPS URL and allowed DNS host.
 *
 * Offline provisioning must embed two PUBLIC assets into owner's private v4
 * build: ota-release-channel.txt and ota-release-public.der. Without either,
 * OTA is disabled; no fabricated production endpoint or trust key is used.
 */
public final class OtaReleaseChannel {
    private static final String ASSET = "ota-release-channel.txt";
    private OtaReleaseChannel() {}

    public static final class Channel {
        public final String manifestUrl;
        public final Set<String> trustedHosts;

        private Channel(String manifestUrl, Set<String> trustedHosts) {
            this.manifestUrl = manifestUrl;
            this.trustedHosts = trustedHosts;
        }
    }

    public static Channel loadBundled(Context context) {
        if (context == null) return null;
        try (InputStream in = context.getAssets().open(ASSET);
             ByteArrayOutputStream bytes = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[256];
            int length = 0;
            int empty = 0;
            int count;
            while ((count = in.read(buffer)) != -1) {
                if (count == 0) {
                    if (++empty >= 3) return null;
                    continue;
                }
                empty = 0;
                length += count;
                if (length > 512) return null;
                bytes.write(buffer, 0, count);
            }
            byte[] raw = bytes.toByteArray();
            if (raw.length < 20 || raw[raw.length - 1] != 10) return null;
            for (byte b : raw) {
                int n = b & 0xff;
                if (n != 10 && (n < 33 || n > 126)) return null;
            }
            String text = new String(raw, StandardCharsets.US_ASCII);
            if (text.indexOf('\n') != text.length() - 1) return null;
            String url = text.substring(0, text.length() - 1);
            URI parsed = new URI(url);
            if (parsed.getHost() == null || parsed.getHost().length() > 253)
                return null;
            Set<String> hosts = Collections.singleton(
                    parsed.getHost().toLowerCase(Locale.ROOT));
            if (!OtaHttpsTransport.safeHttpsEndpoint(url, hosts, ".manifest"))
                return null;
            return new Channel(url, hosts);
        } catch (Exception invalidOrUnprovisioned) {
            return null;
        }
    }
}
