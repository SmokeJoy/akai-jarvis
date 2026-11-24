package it.akai.customremote.ai;

import java.nio.charset.StandardCharsets;
import java.security.PublicKey;
import java.util.Set;

/**
 * Strict, signed, ASCII release manifest protocol (jarvis-ota-v1).
 *
 * A locally pinned RSA verification key is REQUIRED; the release server may
 * supply a manifest and detached signature, never the trust anchor itself.
 * Syntax is fixed/order-sensitive to avoid duplicate-key and parser ambiguity.
 * The same exact bytes are checked by the signature and this parser.
 *
 * Successful parsing authorizes metadata inspection, NOT APK installation.
 */
public final class OtaSignedReleaseManifest {
    private OtaSignedReleaseManifest() {}

    private static final String[] FIELD_NAMES = {
            "format", "package", "versionCode", "signerSha256", "apkSha256",
            "url", "abi", "minSdk", "sizeBytes", "channel"
    };

    public static final class Result {
        public final OtaCandidateGate.Candidate candidate;
        public final String code;

        private Result(OtaCandidateGate.Candidate candidate, String code) {
            this.candidate = candidate;
            this.code = code;
        }

        public boolean verified() {
            return candidate != null;
        }
    }

    private static Result deny(String code) { return new Result(null, code); }

    private static int parsePositiveInt(String raw) {
        if (raw == null || !raw.matches("[1-9][0-9]{0,9}"))
            throw new IllegalArgumentException("INVALID_INTEGER");
        return Integer.parseInt(raw);
    }

    private static long parsePositiveLong(String raw) {
        if (raw == null || !raw.matches("[1-9][0-9]{0,15}"))
            throw new IllegalArgumentException("INVALID_LONG");
        return Long.parseLong(raw);
    }

    public static Result verify(byte[] signedBytes, byte[] signature,
                                PublicKey pinnedReleaseKey,
                                int installedVersionCode,
                                String installedSignerSha256,
                                Set<String> locallyTrustedHosts) {
        return verify(signedBytes, signature, pinnedReleaseKey, installedVersionCode,
                installedSignerSha256, locallyTrustedHosts,
                OtaCandidateGate.EXPECTED_SIGNER_SHA256);
    }

    static Result verify(byte[] signedBytes, byte[] signature,
                         PublicKey pinnedReleaseKey,
                         int installedVersionCode,
                         String installedSignerSha256,
                         Set<String> locallyTrustedHosts,
                         String expectedSignerSha256) {
        if (!OtaCandidateGate.verifyManifestSignature(signedBytes, signature, pinnedReleaseKey))
            return deny("MANIFEST_SIGNATURE_INVALID");
        try {
            // Forbid Unicode normalisation, CRLF, hidden controls, NUL and BOM.
            for (byte value : signedBytes) {
                int c = value & 0xff;
                if (c != 10 && (c < 33 || c > 126))
                    return deny("MANIFEST_NONCANONICAL_BYTES");
            }
            String raw = new String(signedBytes, StandardCharsets.US_ASCII);
            if (!raw.endsWith("\n")) return deny("MANIFEST_MISSING_TERMINATOR");
            String[] lines = raw.split("\n", -1);
            if (lines.length != FIELD_NAMES.length + 1 || !lines[FIELD_NAMES.length].isEmpty())
                return deny("MANIFEST_LINE_COUNT_INVALID");

            String[] fields = new String[FIELD_NAMES.length];
            for (int i = 0; i < FIELD_NAMES.length; i++) {
                String prefix = FIELD_NAMES[i] + "=";
                if (!lines[i].startsWith(prefix) || lines[i].length() <= prefix.length())
                    return deny("MANIFEST_FIELD_INVALID_" + FIELD_NAMES[i]);
                fields[i] = lines[i].substring(prefix.length());
            }
            if (!"jarvis-ota-v1".equals(fields[0])) return deny("MANIFEST_FORMAT_UNSUPPORTED");

            OtaCandidateGate.Candidate candidate = new OtaCandidateGate.Candidate(
                    fields[1], parsePositiveInt(fields[2]), fields[3], fields[4],
                    fields[5], fields[6], parsePositiveInt(fields[7]),
                    parsePositiveLong(fields[8]), fields[9]);

            OtaCandidateGate.Verdict verdict = OtaCandidateGate.inspect(
                    candidate, installedVersionCode, installedSignerSha256,
                    locallyTrustedHosts, expectedSignerSha256);
            if (!verdict.eligibleForDownload) return deny("CANDIDATE_" + verdict.code);
            return new Result(candidate, "SIGNED_MANIFEST_VERIFIED_NOT_INSTALLED");
        } catch (RuntimeException invalid) {
            return deny("MANIFEST_FORMAT_INVALID");
        }
    }
}
