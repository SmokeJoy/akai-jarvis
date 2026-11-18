package it.akai.customremote.ai;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.net.URL;
import java.security.MessageDigest;
import java.util.Locale;
import java.util.Set;

import javax.net.ssl.HttpsURLConnection;

/**
 * Blocking, bounded HTTPS-only OTA transport. MUST execute on a short-lived
 * worker with explicit owner initiation, never on UI thread or at boot.
 *
 * Not an updater: does not parse/trust a manifest, inspect Android APK signers,
 * start PackageInstaller, or touch the installed app. Callers must first verify
 * the detached signature with OtaSignedReleaseManifest, then pass the verified
 * candidate URL/size/hash and a LOCAL host allowlist. No redirects are followed.
 */
public final class OtaHttpsTransport {
    private OtaHttpsTransport() {}

    private static final int CONNECT_TIMEOUT_MS = 8000;
    private static final int READ_TIMEOUT_MS = 12000;

    public static boolean safeHttpsEndpoint(String url, Set<String> locallyTrustedHosts,
                                            String requiredSuffix) {
        if (url == null || locallyTrustedHosts == null ||
                locallyTrustedHosts.isEmpty() || requiredSuffix == null)
            return false;
        try {
            URI uri = new URI(url);
            if (!"https".equalsIgnoreCase(uri.getScheme()) ||
                    uri.getRawUserInfo() != null || uri.getFragment() != null ||
                    uri.getHost() == null ||
                    (uri.getPort() != -1 && uri.getPort() != 443) ||
                    uri.getRawPath() == null || !uri.getRawPath().endsWith(requiredSuffix))
                return false;
            String host = uri.getHost().toLowerCase(Locale.ROOT);
            for (String allowed : locallyTrustedHosts) {
                if (allowed != null && host.equals(allowed.toLowerCase(Locale.ROOT)))
                    return true;
            }
        } catch (Exception invalid) {
            return false;
        }
        return false;
    }

    private static HttpsURLConnection open(String url) throws IOException {
        HttpsURLConnection connection = (HttpsURLConnection) new URL(url).openConnection();
        connection.setInstanceFollowRedirects(false);
        connection.setRequestMethod("GET");
        connection.setConnectTimeout(CONNECT_TIMEOUT_MS);
        connection.setReadTimeout(READ_TIMEOUT_MS);
        connection.setUseCaches(false);
        connection.setRequestProperty("Accept-Encoding", "identity");
        return connection;
    }

    /**
     * Bounded read, including streams that incorrectly return 0 multiple times.
     * Does NOT close the input stream: the caller owns it.
     */
    public static byte[] readBounded(InputStream source, int maxBytes) throws IOException {
        if (source == null || maxBytes < 1 || maxBytes > OtaCandidateGate.MAX_MANIFEST_BYTES)
            throw new IOException("INVALID_BOUNDED_INPUT");
        ByteArrayOutputStream output = new ByteArrayOutputStream(Math.min(1024, maxBytes));
        byte[] buffer = new byte[1024];
        int emptyReads = 0;
        int read;
        while ((read = source.read(buffer)) != -1) {
            if (read == 0) {
                if (++emptyReads >= 3) throw new IOException("REPEATED_EMPTY_READ");
                continue;
            }
            emptyReads = 0;
            if (read > maxBytes - output.size()) throw new IOException("RESPONSE_TOO_LARGE");
            output.write(buffer, 0, read);
        }
        if (output.size() == 0) throw new IOException("EMPTY_RESPONSE");
        return output.toByteArray();
    }

    /** Fetch a signed protocol .manifest or detached .sig. Never accepts HTTP redirects. */
    public static byte[] fetchSmall(String url, Set<String> trustedHosts,
                                    String expectedSuffix, int maxBytes) throws IOException {
        if (!safeHttpsEndpoint(url, trustedHosts, expectedSuffix))
            throw new IOException("URL_NOT_TRUSTED");
        HttpsURLConnection conn = open(url);
        try {
            if (conn.getResponseCode() != 200) throw new IOException("HTTP_STATUS_NOT_200");
            if (conn.getContentLengthLong() > maxBytes)
                throw new IOException("DECLARED_RESPONSE_TOO_LARGE");
            try (InputStream input = conn.getInputStream()) {
                return readBounded(input, maxBytes);
            }
        } finally {
            conn.disconnect();
        }
    }

    /**
     * Download an already signed/validated candidate into a staging directory,
     * verify the ACTUAL file length and SHA-256, and move to a private .apk path.
     * Caller must ensure privateFilesDir is Context.getFilesDir() and must
     * perform OtaAndroidArchiveInspector against the returned file before any
     * separately approved PackageInstaller action.
     */
    public static File stageVerifiedApk(OtaCandidateGate.Candidate signedCandidate,
                                        Set<String> trustedHosts,
                                        File privateFilesDir) throws IOException {
        if (signedCandidate == null || privateFilesDir == null ||
                !safeHttpsEndpoint(signedCandidate.downloadUrl, trustedHosts, ".apk") ||
                signedCandidate.sizeBytes < 1024 ||
                signedCandidate.sizeBytes > OtaCandidateGate.MAX_APK_BYTES ||
                signedCandidate.apkSha256 == null ||
                !signedCandidate.apkSha256.matches("[0-9a-fA-F]{64}"))
            throw new IOException("INVALID_SIGNED_CANDIDATE");

        File root = privateFilesDir.getCanonicalFile();
        if (!root.isDirectory()) throw new IOException("PRIVATE_DIRECTORY_UNAVAILABLE");
        File staging = new File(root, "ota-staging");
        if (!staging.isDirectory() && !staging.mkdir())
            throw new IOException("STAGING_UNAVAILABLE");
        if (!staging.getCanonicalPath().equals(new File(root, "ota-staging").getAbsolutePath()))
            throw new IOException("STAGING_PATH_UNTRUSTED");

        File partial = File.createTempFile("jarvis-", ".part", staging);
        File target = new File(staging, "jarvis-" + signedCandidate.versionCode + ".apk");
        boolean approvedBytes = false;
        HttpsURLConnection connection = null;
        try {
            connection = open(signedCandidate.downloadUrl);
            if (connection.getResponseCode() != 200)
                throw new IOException("APK_HTTP_STATUS_NOT_200");
            long declaredLength = connection.getContentLengthLong();
            if (declaredLength > signedCandidate.sizeBytes)
                throw new IOException("APK_CONTENT_LENGTH_EXCEEDED");
            long total = 0;
            int emptyReads = 0;
            try (InputStream input = connection.getInputStream();
                 FileOutputStream output = new FileOutputStream(partial)) {
                byte[] buf = new byte[16 * 1024];
                int count;
                while ((count = input.read(buf)) != -1) {
                    if (count == 0) {
                        if (++emptyReads >= 3) throw new IOException("APK_REPEATED_EMPTY_READ");
                        continue;
                    }
                    emptyReads = 0;
                    total += count;
                    if (total > signedCandidate.sizeBytes)
                        throw new IOException("APK_EXCEEDS_DECLARED_LENGTH");
                    output.write(buf, 0, count);
                }
                output.getFD().sync();
            }
            if (total != signedCandidate.sizeBytes)
                throw new IOException("APK_LENGTH_MISMATCH");
            try (FileInputStream verify = new FileInputStream(partial)) {
                if (!OtaCandidateGate.verifyApkStream(
                        verify, signedCandidate.sizeBytes, signedCandidate.apkSha256))
                    throw new IOException("APK_SHA256_MISMATCH");
            }
            if (target.exists() && !target.delete())
                throw new IOException("OLD_STAGING_FILE_LOCKED");
            if (!partial.renameTo(target))
                throw new IOException("STAGING_MOVE_FAILED");
            approvedBytes = true;
            return target;
        } finally {
            if (connection != null) connection.disconnect();
            if (!approvedBytes) partial.delete();
        }
    }
}
