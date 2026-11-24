package it.akai.customremote.ai;

import java.nio.charset.StandardCharsets;
import java.security.PublicKey;

/**
 * Pure-Java, fail-closed verification for local signed OTA backup & recovery
 * readiness receipts (jarvis-ota-evidence-v1).
 *
 * UI checkboxes alone prove owner acknowledgment, NEVER technical backup or
 * restore readiness. This gate enforces a detached RSA signature under the
 * bundled trust anchor plus strict binding to device UID, installed package/
 * version, backup digest, bounded validity window, A2 Rescue > candidate, and
 * non-destructive offline restore attestation.
 *
 * Host fixtures using ephemeral test keys remain NON_AUTHORITATIVE for TV.
 */
public final class OtaRecoveryEvidenceGate {
    public static final int MAX_RECEIPT_BYTES = 4096;
    public static final long MAX_FUTURE_SKEW_SEC = 300L;
    public static final long MAX_RECEIPT_LIFETIME_SEC = 90L * 86400L;

    private static final String[] FIELD_NAMES = {
            "format",
            "package",
            "deviceUid",
            "installedVersionCode",
            "backupId",
            "backupCreatedEpochSec",
            "backupExpiresEpochSec",
            "backupArchiveSha256",
            "rescueVersionCode",
            "offlineRestoreVerified",
            "nonDestructiveVerified"
    };

    private OtaRecoveryEvidenceGate() {}

    public static final class Verdict {
        public final boolean accepted;
        public final boolean backupVerified;
        public final boolean recoveryVerified;
        public final String code;
        public final String backupId;
        public final int rescueVersionCode;

        private Verdict(boolean accepted, boolean backupVerified, boolean recoveryVerified,
                        String code, String backupId, int rescueVersionCode) {
            this.accepted = accepted;
            this.backupVerified = backupVerified;
            this.recoveryVerified = recoveryVerified;
            this.code = code;
            this.backupId = backupId;
            this.rescueVersionCode = rescueVersionCode;
        }
    }

    private static Verdict deny(String code) {
        return new Verdict(false, false, false, code, null, 0);
    }

    static Verdict externalDeny(String code) {
        String safeCode = (code == null || code.isEmpty()) ? "EVIDENCE_UNAVAILABLE" : code;
        return deny(safeCode);
    }

    private static int parsePositiveInt(String raw) {
        if (raw == null || !raw.matches("[1-9][0-9]{0,9}"))
            throw new IllegalArgumentException("INVALID_POSITIVE_INT");
        return Integer.parseInt(raw);
    }

    private static long parsePositiveLong(String raw) {
        if (raw == null || !raw.matches("[1-9][0-9]{0,15}"))
            throw new IllegalArgumentException("INVALID_POSITIVE_LONG");
        return Long.parseLong(raw);
    }

    private static Boolean parseStrictBoolean(String raw) {
        if ("true".equals(raw)) return Boolean.TRUE;
        if ("false".equals(raw)) return Boolean.FALSE;
        return null;
    }

    public static Verdict verify(byte[] receiptBytes,
                                 byte[] detachedSignature,
                                 PublicKey pinnedReleaseKey,
                                 String localDeviceUid,
                                 int actualInstalledVersionCode,
                                 int candidateVersionCode,
                                 long nowEpochSec) {
        if (receiptBytes == null || receiptBytes.length == 0 ||
                receiptBytes.length > MAX_RECEIPT_BYTES ||
                !OtaCandidateGate.verifyManifestSignature(
                        receiptBytes, detachedSignature, pinnedReleaseKey)) {
            return deny("EVIDENCE_SIGNATURE_INVALID");
        }

        try {
            for (byte value : receiptBytes) {
                int c = value & 0xff;
                if (c != 10 && (c < 33 || c > 126)) {
                    return deny("EVIDENCE_NONCANONICAL_BYTES");
                }
            }
            String raw = new String(receiptBytes, StandardCharsets.US_ASCII);
            if (!raw.endsWith("\n")) return deny("EVIDENCE_MISSING_TERMINATOR");
            String[] lines = raw.split("\n", -1);
            if (lines.length != FIELD_NAMES.length + 1 || !lines[FIELD_NAMES.length].isEmpty()) {
                return deny("EVIDENCE_LINE_COUNT_INVALID");
            }

            String[] fields = new String[FIELD_NAMES.length];
            for (int i = 0; i < FIELD_NAMES.length; i++) {
                String prefix = FIELD_NAMES[i] + "=";
                if (!lines[i].startsWith(prefix) || lines[i].length() <= prefix.length()) {
                    return deny("EVIDENCE_FIELD_INVALID_" + FIELD_NAMES[i]);
                }
                fields[i] = lines[i].substring(prefix.length());
            }

            if (!"jarvis-ota-evidence-v1".equals(fields[0])) {
                return deny("EVIDENCE_FORMAT_UNSUPPORTED");
            }
            if (!OtaCandidateGate.PACKAGE.equals(fields[1])) {
                return deny("EVIDENCE_PACKAGE_MISMATCH");
            }
            if (localDeviceUid == null || !localDeviceUid.matches("[A-Za-z0-9._:-]{8,128}")) {
                return deny("EVIDENCE_DEVICE_UID_UNAVAILABLE");
            }
            if (!fields[2].matches("[A-Za-z0-9._:-]{8,128}") || !localDeviceUid.equals(fields[2])) {
                return deny("EVIDENCE_DEVICE_UID_MISMATCH");
            }

            int receiptInstalledVersion = parsePositiveInt(fields[3]);
            if (actualInstalledVersionCode < 1 ||
                    receiptInstalledVersion != actualInstalledVersionCode) {
                return deny("EVIDENCE_INSTALLED_VERSION_MISMATCH");
            }

            String backupId = fields[4];
            if (!backupId.matches("[A-Za-z0-9._:-]{4,64}")) {
                return deny("EVIDENCE_BACKUP_ID_INVALID");
            }

            long createdEpochSec = parsePositiveLong(fields[5]);
            long expiresEpochSec = parsePositiveLong(fields[6]);
            if (nowEpochSec <= 0L) {
                return deny("EVIDENCE_CLOCK_INVALID");
            }
            if (createdEpochSec > nowEpochSec + MAX_FUTURE_SKEW_SEC) {
                return deny("EVIDENCE_CREATED_IN_FUTURE");
            }
            if (expiresEpochSec <= createdEpochSec) {
                return deny("EVIDENCE_WINDOW_INVALID");
            }
            if ((expiresEpochSec - createdEpochSec) > MAX_RECEIPT_LIFETIME_SEC) {
                return deny("EVIDENCE_LIFETIME_EXCESSIVE");
            }
            if (nowEpochSec >= expiresEpochSec) {
                return deny("EVIDENCE_EXPIRED");
            }

            if (!fields[7].matches("[0-9a-fA-F]{64}")) {
                return deny("EVIDENCE_BACKUP_DIGEST_INVALID");
            }

            int rescueVersionCode = parsePositiveInt(fields[8]);
            if (rescueVersionCode < 5 ||
                    candidateVersionCode <= actualInstalledVersionCode ||
                    rescueVersionCode <= candidateVersionCode) {
                return deny("EVIDENCE_RESCUE_NOT_ABOVE_CANDIDATE");
            }

            Boolean offlineRestore = parseStrictBoolean(fields[9]);
            Boolean nonDestructive = parseStrictBoolean(fields[10]);
            if (offlineRestore == null || nonDestructive == null) {
                return deny("EVIDENCE_FORMAT_INVALID");
            }
            if (!offlineRestore.booleanValue()) {
                return deny("EVIDENCE_OFFLINE_RESTORE_NOT_VERIFIED");
            }
            if (!nonDestructive.booleanValue()) {
                return deny("EVIDENCE_NONDESTRUCTIVE_RESTORE_NOT_VERIFIED");
            }

            return new Verdict(true, true, true,
                    "LOCAL_RECOVERY_EVIDENCE_VERIFIED_NOT_AUTHORIZED_ALONE",
                    backupId, rescueVersionCode);
        } catch (RuntimeException invalid) {
            return deny("EVIDENCE_FORMAT_INVALID");
        }
    }
}
