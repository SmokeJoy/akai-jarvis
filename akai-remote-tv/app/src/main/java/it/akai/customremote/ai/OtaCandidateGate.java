package it.akai.customremote.ai;

import java.io.InputStream;
import java.net.URI;
import java.security.MessageDigest;
import java.security.PublicKey;
import java.security.Signature;
import java.security.interfaces.RSAPublicKey;
import java.util.Collections;
import java.util.Locale;
import java.util.Set;

/**
 * Pure-Java, fail-closed metadata gate for a future on-TV, owner-approved OTA updater.
 *
 * This class deliberately NEVER downloads or installs anything. Passing this gate
 * does NOT authenticate an APK or authorize installation: the downloader must verify
 * the APK bytes and Android PackageManager must verify its archive signer, package,
 * and versionCode before any owner-confirmed PackageInstaller session is created.
 */
public final class OtaCandidateGate {
    public static final String PACKAGE = "it.akai.customremote";
    // SHA-256 of the Android signing certificate already installed on the AKAI TV.
    public static final String EXPECTED_SIGNER_SHA256 =
            "21c2c41dc4c34576cca14ad5404e87d1c5a07ace961c0fab96d128c2164a51ed";
    public static final int TV_API_LEVEL = 28;
    public static final long MAX_APK_BYTES = 25L * 1024L * 1024L;
    public static final int MAX_MANIFEST_BYTES = 8 * 1024;

    private OtaCandidateGate() {}

    public static final class Candidate {
        public final String packageName;
        public final int versionCode;
        public final String signerCertificateSha256;
        public final String apkSha256;
        public final String downloadUrl;
        public final String abi;
        public final int minSdk;
        public final long sizeBytes;
        public final String channel;

        public Candidate(String packageName, int versionCode, String signerCertificateSha256,
                         String apkSha256, String downloadUrl, String abi, int minSdk,
                         long sizeBytes, String channel) {
            this.packageName = packageName;
            this.versionCode = versionCode;
            this.signerCertificateSha256 = signerCertificateSha256;
            this.apkSha256 = apkSha256;
            this.downloadUrl = downloadUrl;
            this.abi = abi;
            this.minSdk = minSdk;
            this.sizeBytes = sizeBytes;
            this.channel = channel;
        }
    }

    public static final class Verdict {
        public final boolean eligibleForDownload;
        public final String code;

        private Verdict(boolean eligibleForDownload, String code) {
            this.eligibleForDownload = eligibleForDownload;
            this.code = code;
        }
    }

    private static Verdict deny(String code) { return new Verdict(false, code); }

    private static boolean validSha256(String value) {
        return value != null && value.matches("[0-9a-fA-F]{64}");
    }

    private static boolean equalsHex(String a, String b) {
        return validSha256(a) && validSha256(b) && a.equalsIgnoreCase(b);
    }

    public static boolean isPublicDnsHost(String host) {
        if (host == null) return false;
        String h = host.trim().toLowerCase(Locale.ROOT);
        if (h.isEmpty() || h.length() > 253) return false;
        if ("localhost".equals(h) || h.endsWith(".localhost")
                || h.endsWith(".local") || h.endsWith(".lan")
                || h.endsWith(".internal") || h.endsWith(".home")) {
            return false;
        }
        if (h.indexOf('[') >= 0 || h.indexOf(':') >= 0 || h.startsWith(".") || h.endsWith(".")
                || h.contains("..") || !h.contains(".")) {
            return false;
        }
        if (h.matches("[0-9.]+")) {
            return false;
        }
        return true;
    }

    public static boolean hasUnsafeUrlPath(String rawPath) {
        if (rawPath == null || rawPath.isEmpty() || !rawPath.startsWith("/")) {
            return true;
        }
        if (rawPath.indexOf('\\') >= 0 || rawPath.contains("/../") || rawPath.endsWith("/..")) {
            return true;
        }
        String lower = rawPath.toLowerCase(Locale.ROOT);
        return lower.contains("%2e") || lower.contains("%2f") || lower.contains("%5c");
    }

    /**
     * Metadata validation only. trustedHosts MUST be a locally configured,
     * nonempty allowlist: never take it from untrusted release metadata.
     *
     * Public release channels and any manifest-signature verification must be
     * implemented separately. A private GitHub repo is not a public OTA endpoint.
     */
    public static Verdict inspect(Candidate candidate, int installedVersionCode,
                                  String installedSignerSha256, Set<String> trustedHosts) {
        return inspect(candidate, installedVersionCode, installedSignerSha256,
                trustedHosts, EXPECTED_SIGNER_SHA256);
    }

    /**
     * Package-private overload allowing host staging fixtures to bind an
     * ephemeral APK signer digest while keeping the public production gate
     * pinned strictly to EXPECTED_SIGNER_SHA256.
     */
    static Verdict inspect(Candidate candidate, int installedVersionCode,
                           String installedSignerSha256, Set<String> trustedHosts,
                           String expectedSignerSha256) {
        if (candidate == null) return deny("MISSING_CANDIDATE");
        if (installedVersionCode < 1) return deny("UNKNOWN_INSTALLED_VERSION");
        if (!equalsHex(installedSignerSha256, expectedSignerSha256)) {
            return deny("INSTALLED_SIGNER_MISMATCH");
        }
        if (!PACKAGE.equals(candidate.packageName)) return deny("PACKAGE_MISMATCH");
        if (candidate.versionCode <= installedVersionCode) return deny("NOT_AN_UPGRADE");
        if (!equalsHex(candidate.signerCertificateSha256, expectedSignerSha256)) {
            return deny("CANDIDATE_SIGNER_MISMATCH");
        }
        if (!validSha256(candidate.apkSha256)) return deny("MISSING_APK_DIGEST");
        if (!"stable".equals(candidate.channel)) return deny("NON_STABLE_CHANNEL");
        if (candidate.minSdk < 21 || candidate.minSdk > TV_API_LEVEL) {
            return deny("ANDROID_SDK_INCOMPATIBLE");
        }
        if (!"armeabi-v7a".equals(candidate.abi)) return deny("ABI_INCOMPATIBLE");
        if (candidate.sizeBytes < 1024L || candidate.sizeBytes > MAX_APK_BYTES) {
            return deny("APK_SIZE_INVALID");
        }
        if (trustedHosts == null || trustedHosts.isEmpty()) return deny("NO_TRUSTED_HOST");

        final URI uri;
        try {
            uri = new URI(candidate.downloadUrl);
        } catch (Exception e) {
            return deny("INVALID_DOWNLOAD_URL");
        }
        if (!"https".equalsIgnoreCase(uri.getScheme()) ||
                uri.getRawUserInfo() != null || uri.getFragment() != null ||
                uri.getHost() == null || uri.getPort() != -1 && uri.getPort() != 443 ||
                !isPublicDnsHost(uri.getHost()) ||
                hasUnsafeUrlPath(uri.getRawPath()) ||
                !uri.getRawPath().toLowerCase(Locale.ROOT).endsWith(".apk")) {
            return deny("UNSAFE_DOWNLOAD_URL");
        }
        // Exact DNS host comparison, not a suffix match (evil.example.com is not example.com).
        String host = uri.getHost().toLowerCase(Locale.ROOT);
        boolean trusted = false;
        for (String allowed : trustedHosts) {
            if (allowed != null && host.equals(allowed.toLowerCase(Locale.ROOT))) {
                trusted = true;
                break;
            }
        }
        if (!trusted) return deny("UNTRUSTED_DOWNLOAD_HOST");
        return new Verdict(true, "METADATA_ACCEPTED_ARCHIVE_UNVERIFIED");
    }

    /**
     * Verify detached SHA256withRSA signature over the exact, bounded manifest bytes.
     * The key MUST be pinned locally by JARVIS; never supplied by the server or by
     * the manifest. A test-generated key is not a production trust anchor.
     *
     * This is one required OTA check; it does not parse the manifest, fetch an
     * APK, prove archive signer identity or authorize Android installation.
     * Missing production trust provisioning must disable the OTA feature.
     */
    public static boolean verifyManifestSignature(byte[] rawManifest,
                                                   byte[] detachedSignature,
                                                   PublicKey pinnedPublicKey) {
        if (rawManifest == null || rawManifest.length == 0 ||
                rawManifest.length > MAX_MANIFEST_BYTES ||
                detachedSignature == null ||
                pinnedPublicKey == null ||
                !(pinnedPublicKey instanceof RSAPublicKey)) {
            return false;
        }
        int keyBits = ((RSAPublicKey) pinnedPublicKey).getModulus().bitLength();
        if (keyBits < 2048 || keyBits > 4096) return false;
        if (detachedSignature.length != (keyBits + 7) / 8) return false;
        try {
            Signature verifier = Signature.getInstance("SHA256withRSA");
            verifier.initVerify(pinnedPublicKey);
            verifier.update(rawManifest);
            return verifier.verify(detachedSignature);
        } catch (Exception error) {
            return false;
        }
    }

    /**
     * Independently re-read a previously downloaded private APK file stream
     * and verify the exact declared length and SHA-256 of its bytes.
     * Callers own/close this stream and must enforce I/O timeouts externally.
     * Bytes from this check must be the *same file* later inspected by Android
     * PackageManager; the method does NOT authenticate the APK signer.
     *
     * Returns false on truncation, extra data, hash mismatch or read failure.
     */
    public static boolean verifyApkStream(InputStream apkBytes, long declaredBytes,
                                          String declaredSha256) {
        if (apkBytes == null || declaredBytes < 1024L ||
                declaredBytes > MAX_APK_BYTES || !validSha256(declaredSha256)) {
            return false;
        }
        try {
            MessageDigest sha256 = MessageDigest.getInstance("SHA-256");
            byte[] buffer = new byte[16 * 1024];
            long total = 0;
            int consecutiveEmptyReads = 0;
            int n;
            while ((n = apkBytes.read(buffer)) != -1) {
                if (n == 0) {
                    if (++consecutiveEmptyReads >= 3) return false;
                    continue;
                }
                consecutiveEmptyReads = 0;
                total += n;
                if (total > declaredBytes) return false;
                sha256.update(buffer, 0, n);
            }
            return total == declaredBytes && digestMatches(sha256.digest(), declaredSha256);
        } catch (Exception readFailure) {
            return false;
        }
    }

    /** Fixed expected digest; consumed by a future streaming downloader. */
    public static boolean digestMatches(byte[] digestBytes, String expectedHex) {
        if (digestBytes == null || digestBytes.length != 32 || !validSha256(expectedHex)) {
            return false;
        }
        byte[] expected = new byte[32];
        for (int i = 0; i < expected.length; i++) {
            int hi = Character.digit(expectedHex.charAt(i * 2), 16);
            int lo = Character.digit(expectedHex.charAt(i * 2 + 1), 16);
            expected[i] = (byte) ((hi << 4) | lo);
        }
        return MessageDigest.isEqual(digestBytes, expected);
    }
}
