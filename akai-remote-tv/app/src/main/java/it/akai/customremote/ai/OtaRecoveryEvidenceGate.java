package it.akai.customremote.ai;

import java.nio.charset.StandardCharsets;
import java.security.PublicKey;
import java.util.Locale;

/**
 * Pure-Java, fail-closed verification for local signed OTA backup & recovery
 * readiness receipts (jarvis-ota-evidence-v2).
 *
 * UI checkboxes alone prove owner acknowledgment, NEVER technical backup or
 * restore readiness. This gate enforces a detached RSA signature under the
 * bundled trust anchor plus strict binding to channel profile (staging/release),
 * device UID, installed version, backup digest, bounded validity window,
 * coherent in-place Android 9 version ordering:
 * - staging: installed < candidate < recoveryRescue
 * - release: installed <= priorRescueFloor < candidate < recoveryRescue
 * and non-destructive offline restore attestation.
 *
 * Note: verifying a signed receipt does NOT itself hash off-device backup files;
 * archive digest + restore integrity MUST be established before signing (e.g.
 * via scripts/16 + scripts/19) and/or locally via OtaRecoveryEvidenceStore.
 */
public final class OtaRecoveryEvidenceGate {
    public static final int MAX_RECEIPT_BYTES = 4096;
    public static final long MAX_FUTURE_SKEW_SEC = 300L;
    public static final long MAX_RECEIPT_LIFETIME_SEC = 90L * 86400L;

    private static final String[] FIELD_NAMES = {
            "format",
            "package",
            "channelProfile",
            "deviceUid",
            "installedVersionCode",
            "backupId",
            "backupCreatedEpochSec",
            "backupExpiresEpochSec",
            "backupArchiveSha256",
            "priorRescueFloorVersionCode",
            "recoveryRescueVersionCode",
            "rescueApkSha256",
            "offlineRestoreVerified",
            "nonDestructiveVerified"
    };

    private OtaRecoveryEvidenceGate() {}

    public static final class Verdict {
        public final boolean accepted;
        public final boolean backupVerified;
        public final boolean recoveryVerified;
        public final String code;
        public final String channelProfile;
        public final String backupId;
        public final String backupArchiveSha256;
        public final int priorRescueFloorVersionCode;
        public final int recoveryRescueVersionCode;
        public final String rescueApkSha256;

        private Verdict(boolean accepted, boolean backupVerified, boolean recoveryVerified,
                        String code, String channelProfile, String backupId,
                        String backupArchiveSha256, int priorRescueFloorVersionCode,
                        int recoveryRescueVersionCode, String rescueApkSha256) {
            this.accepted = accepted;
            this.backupVerified = backupVerified;
            this.recoveryVerified = recoveryVerified;
            this.code = code;
            this.channelProfile = channelProfile;
            this.backupId = backupId;
            this.backupArchiveSha256 = backupArchiveSha256;
            this.priorRescueFloorVersionCode = priorRescueFloorVersionCode;
            this.recoveryRescueVersionCode = recoveryRescueVersionCode;
            this.rescueApkSha256 = rescueApkSha256;
        }
    }

    private static Verdict deny(String code) {
        return new Verdict(false, false, false, code, null, null, null, 0, 0, null);
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

    private static int parseNonNegativeInt(String raw) {
        if ("0".equals(raw)) return 0;
        return parsePositiveInt(raw);
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
        return verifyCore(receiptBytes, detachedSignature, pinnedReleaseKey,
                localDeviceUid, actualInstalledVersionCode,
                candidateVersionCode, true, nowEpochSec);
    }

    /**
     * Validate a signed jarvis-ota-evidence-v2 receipt at ADB-free import time
     * before a concrete OTA candidate version is fetched. Still enforces signature,
     * device UID, installed version, backup digest, lifetime, restore flags, and
     * a coherent upgrade slot above installed (and above priorRescueFloor if release).
     * Exact candidate checks still run in loadAndVerify() before createSession().
     */
    public static Verdict verifyForInstalled(byte[] receiptBytes,
                                             byte[] detachedSignature,
                                             PublicKey pinnedReleaseKey,
                                             String localDeviceUid,
                                             int actualInstalledVersionCode,
                                             long nowEpochSec) {
        return verifyCore(receiptBytes, detachedSignature, pinnedReleaseKey,
                localDeviceUid, actualInstalledVersionCode,
                0, false, nowEpochSec);
    }

    private static Verdict verifyCore(byte[] receiptBytes,
                                      byte[] detachedSignature,
                                      PublicKey pinnedReleaseKey,
                                      String localDeviceUid,
                                      int actualInstalledVersionCode,
                                      int candidateVersionCode,
                                      boolean enforceCandidateVersion,
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

            if (!"jarvis-ota-evidence-v2".equals(fields[0])) {
                return deny("EVIDENCE_FORMAT_UNSUPPORTED");
            }
            if (!OtaCandidateGate.PACKAGE.equals(fields[1])) {
                return deny("EVIDENCE_PACKAGE_MISMATCH");
            }
            String channelProfile = fields[2];
            if (!"staging".equals(channelProfile) && !"release".equals(channelProfile)) {
                return deny("EVIDENCE_CHANNEL_PROFILE_INVALID");
            }

            if (localDeviceUid == null || !localDeviceUid.matches("[A-Za-z0-9._:-]{8,128}")) {
                return deny("EVIDENCE_DEVICE_UID_UNAVAILABLE");
            }
            if (!fields[3].matches("[A-Za-z0-9._:-]{8,128}") || !localDeviceUid.equals(fields[3])) {
                return deny("EVIDENCE_DEVICE_UID_MISMATCH");
            }

            int receiptInstalledVersion = parsePositiveInt(fields[4]);
            if (actualInstalledVersionCode < 1 ||
                    receiptInstalledVersion != actualInstalledVersionCode) {
                return deny("EVIDENCE_INSTALLED_VERSION_MISMATCH");
            }

            String backupId = fields[5];
            if (!backupId.matches("[A-Za-z0-9._:-]{4,64}")) {
                return deny("EVIDENCE_BACKUP_ID_INVALID");
            }

            long createdEpochSec = parsePositiveLong(fields[6]);
            long expiresEpochSec = parsePositiveLong(fields[7]);
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

            if (!fields[8].matches("[0-9a-fA-F]{64}")) {
                return deny("EVIDENCE_BACKUP_DIGEST_INVALID");
            }
            String backupSha256 = fields[8].toLowerCase(Locale.ROOT);

            int priorRescueFloor = parseNonNegativeInt(fields[9]);
            if (priorRescueFloor != 0 && priorRescueFloor < 5) {
                return deny("EVIDENCE_PRIOR_RESCUE_FLOOR_INVALID");
            }
            int recoveryRescueVersion = parsePositiveInt(fields[10]);

            if (!fields[11].matches("[0-9a-fA-F]{64}")) {
                return deny("EVIDENCE_RESCUE_DIGEST_INVALID");
            }
            String rescueApkSha256 = fields[11].toLowerCase(Locale.ROOT);

            if (enforceCandidateVersion) {
                if (candidateVersionCode <= actualInstalledVersionCode) {
                    return deny("EVIDENCE_CANDIDATE_NOT_ABOVE_INSTALLED");
                }
                if ("release".equals(channelProfile)) {
                    if (priorRescueFloor < 5 || candidateVersionCode <= priorRescueFloor) {
                        return deny("EVIDENCE_RELEASE_NOT_ABOVE_PRIOR_RESCUE");
                    }
                } else {
                    if (priorRescueFloor != 0 && candidateVersionCode <= priorRescueFloor) {
                        return deny("EVIDENCE_STAGING_NOT_ABOVE_PRIOR_RESCUE");
                    }
                }
                if (recoveryRescueVersion < 5 || recoveryRescueVersion <= candidateVersionCode) {
                    return deny("EVIDENCE_RECOVERY_RESCUE_NOT_ABOVE_CANDIDATE");
                }
            } else {
                if ("release".equals(channelProfile)) {
                    if (priorRescueFloor < 5 || recoveryRescueVersion <= priorRescueFloor + 1) {
                        return deny("EVIDENCE_RELEASE_NOT_ABOVE_PRIOR_RESCUE");
                    }
                } else if (priorRescueFloor != 0 && recoveryRescueVersion <= priorRescueFloor + 1) {
                    return deny("EVIDENCE_STAGING_NOT_ABOVE_PRIOR_RESCUE");
                }
                if (recoveryRescueVersion < 5 || recoveryRescueVersion <= actualInstalledVersionCode) {
                    return deny("EVIDENCE_RECOVERY_RESCUE_NOT_ABOVE_CANDIDATE");
                }
            }

            Boolean offlineRestore = parseStrictBoolean(fields[12]);
            Boolean nonDestructive = parseStrictBoolean(fields[13]);
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
                    channelProfile, backupId, backupSha256,
                    priorRescueFloor, recoveryRescueVersion, rescueApkSha256);
        } catch (RuntimeException invalid) {
            return deny("EVIDENCE_FORMAT_INVALID");
        }
    }
}
