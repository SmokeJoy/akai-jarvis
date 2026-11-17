package it.akai.customremote.ai;

import android.content.Context;
import android.util.Log;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

import javax.net.ssl.HttpsURLConnection;

/**
 * One-shot, free-tier-only Italian speech MP3 fetcher.
 * No model, billing account, redirect, arbitrary host or long-lived cache.
 * Caller must verify explicit consent, encrypted free-plan key and local quota.
 * NEVER run on the Android UI thread.
 */
public final class FreeItalianTtsClient {
    private static final String TAG = "AKAI_FreeItalianTTS";
    private FreeItalianTtsClient() {}

    public interface Cancellation {
        boolean isCancelled();
    }

    public static File synthesize(Context context, String text, String voice, String freeApiKey,
                                  Cancellation cancel) {
        if (cancel == null || cancel.isCancelled()) return null;
        if (context == null || !FreeItalianTtsPolicy.textAllowed(text)
                || !FreeItalianTtsPolicy.voiceAllowed(voice)
                || freeApiKey == null || freeApiKey.length() < 10
                || freeApiKey.length() > 256) return null;

        HttpsURLConnection post = null;
        HttpsURLConnection audio = null;
        File tmp = null;
        try {
            if (cancel.isCancelled()) return null;
            URL endpoint = new URL(FreeItalianTtsPolicy.ENDPOINT);
            post = openTrusted(endpoint, "POST");
            post.setDoOutput(true);
            post.setRequestProperty("Content-Type", "application/json; charset=utf-8");
            post.setRequestProperty("x-api-key", freeApiKey);
            JSONObject payload = new JSONObject();
            payload.put("text", text);
            payload.put("voice", voice);
            payload.put("rate", "+0%");
            payload.put("pitch", "+0Hz");
            byte[] input = payload.toString().getBytes(StandardCharsets.UTF_8);
            post.setFixedLengthStreamingMode(input.length);
            if (cancel.isCancelled()) return null;
            try (OutputStream os = post.getOutputStream()) {
                os.write(input);
            }
            if (cancel.isCancelled() || post.getResponseCode() != 200) return null;
            if (cancel.isCancelled()) return null;

            byte[] metadata;
            try (InputStream is = post.getInputStream()) {
                metadata = readBounded(is, 8192);
            }
            JSONObject response = new JSONObject(new String(metadata, StandardCharsets.UTF_8));
            String id = response.optString("file_id", "");
            if (!FreeItalianTtsPolicy.fileIdAllowed(id)) return null;

            if (cancel.isCancelled()) return null;
            URL audioUrl = new URL(FreeItalianTtsPolicy.AUDIO_PREFIX + id);
            audio = openTrusted(audioUrl, "GET");
            if (audio.getResponseCode() != 200) return null;
            String type = audio.getContentType();
            String lowerType = type != null ? type.toLowerCase(java.util.Locale.US) : "";
            if (!(lowerType.startsWith("audio/mpeg") || lowerType.startsWith("audio/mp3")
                    || lowerType.startsWith("application/octet-stream"))) return null;
            long announced = audio.getContentLength();
            if (announced > FreeItalianTtsPolicy.MAX_AUDIO_BYTES) return null;

            tmp = File.createTempFile("jarvis_free_voice_", ".mp3", context.getCacheDir());
            long written = 0;
            try (InputStream is = audio.getInputStream();
                 FileOutputStream os = new FileOutputStream(tmp)) {
                byte[] buffer = new byte[4096];
                int n;
                while ((n = is.read(buffer)) != -1) {
                    if (cancel.isCancelled()) return null;
                    written += n;
                    if (written > FreeItalianTtsPolicy.MAX_AUDIO_BYTES) return null;
                    os.write(buffer, 0, n);
                }
            }
            if (written < 64) return null;
            // An audio file must not be an HTML/JSON error returned with HTTP 200.
            try (InputStream probe = new java.io.FileInputStream(tmp)) {
                int a = probe.read();
                int b = probe.read();
                int c = probe.read();
                boolean id3 = a == 'I' && b == 'D' && c == '3';
                boolean mp3 = a == 0xFF && (b & 0xE0) == 0xE0;
                if (!id3 && !mp3) return null;
            }
            if (cancel.isCancelled()) return null;
            File success = tmp;
            tmp = null;
            return success;
        } catch (Exception e) {
            // Never log the text, credentials, response body or private file id.
            Log.w(TAG, "Free speech unavailable: " + e.getClass().getSimpleName());
            return null;
        } finally {
            if (tmp != null) tmp.delete();
            if (post != null) post.disconnect();
            if (audio != null) audio.disconnect();
        }
    }

    private static HttpsURLConnection openTrusted(URL url, String method) throws Exception {
        if (!"https".equalsIgnoreCase(url.getProtocol())
                || !"freetts.org".equalsIgnoreCase(url.getHost())
                || url.getPort() != -1
                || url.getUserInfo() != null || url.getRef() != null) {
            throw new SecurityException("Unexpected TTS endpoint");
        }
        HttpsURLConnection conn = (HttpsURLConnection) url.openConnection();
        conn.setInstanceFollowRedirects(false);
        conn.setConnectTimeout(5000);
        conn.setReadTimeout(10000);
        conn.setUseCaches(false);
        conn.setRequestMethod(method);
        return conn;
    }

    private static byte[] readBounded(InputStream input, int limit) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buf = new byte[1024];
        int total = 0;
        int n;
        while ((n = input.read(buf)) != -1) {
            total += n;
            if (total > limit) throw new java.io.IOException("Oversized metadata");
            out.write(buf, 0, n);
        }
        return out.toByteArray();
    }
}
