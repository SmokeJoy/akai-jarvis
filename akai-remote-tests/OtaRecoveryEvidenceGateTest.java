package it.akai.customremote;

import it.akai.customremote.ai.OtaCandidateGate;
import it.akai.customremote.ai.OtaRecoveryEvidenceGate;

import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.Signature;

/**
 * Host-only policy and signature tests for OtaRecoveryEvidenceGate (v2).
 * Exercises both staging and release channel profiles under coherent in-place
 * Android 9 ordering without adb install -d or uninstall.
 * Uses ONLY ephemeral RSA keys; positive verdicts exercise synthetic
 * NON_AUTHORITATIVE fixtures and NEVER attest real AKAI TV backups.
 */
public final class OtaRecoveryEvidenceGateTest {
    private static final String DEVICE_UID = "akai-tv-fixture-uid-001";
    private static final String OTHER_UID = "akai-tv-other-uid-999";
    private static final String BACKUP_SHA =
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    private static final String RESCUE_SHA =
            "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210";
    private static final long NOW = 1_795_000_000L;
    private static int checks;

    private OtaRecoveryEvidenceGateTest() {}

    private static byte[] buildReceipt(String format, String pkg, String channelProfile,
                                       String uid, int installed, String backupId,
                                       long created, long expires, String backupSha,
                                       int priorRescueFloor, int recoveryRescueVersion,
                                       String rescueSha, String offlineOk,
                                       String nonDestructiveOk) {
        String text = "format=" + format + "\n"
                + "package=" + pkg + "\n"
                + "channelProfile=" + channelProfile + "\n"
                + "deviceUid=" + uid + "\n"
                + "installedVersionCode=" + installed + "\n"
                + "backupId=" + backupId + "\n"
                + "backupCreatedEpochSec=" + created + "\n"
                + "backupExpiresEpochSec=" + expires + "\n"
                + "backupArchiveSha256=" + backupSha + "\n"
                + "priorRescueFloorVersionCode=" + priorRescueFloor + "\n"
                + "recoveryRescueVersionCode=" + recoveryRescueVersion + "\n"
                + "rescueApkSha256=" + rescueSha + "\n"
                + "offlineRestoreVerified=" + offlineOk + "\n"
                + "nonDestructiveVerified=" + nonDestructiveOk + "\n";
        return text.getBytes(StandardCharsets.US_ASCII);
    }

    private static byte[] sign(byte[] data, KeyPair pair) throws Exception {
        Signature s = Signature.getInstance("SHA256withRSA");
        s.initSign(pair.getPrivate());
        s.update(data);
        return s.sign();
    }

    private static void expect(boolean accepted, String expectedCode,
                               OtaRecoveryEvidenceGate.Verdict actual, String label) {
        if (actual.accepted != accepted
                || actual.backupVerified != accepted
                || actual.recoveryVerified != accepted
                || !expectedCode.equals(actual.code)) {
            throw new AssertionError(label + ": expected (" + accepted + ", "
                    + expectedCode + ") got (" + actual.accepted + ", " + actual.code + ")");
        }
        checks++;
    }

    public static void main(String[] args) throws Exception {
        KeyPairGenerator kpg = KeyPairGenerator.getInstance("RSA");
        kpg.initialize(3072);
        KeyPair key = kpg.generateKeyPair();
        KeyPair wrongKey = kpg.generateKeyPair();

        long created = NOW - 3600L;
        long expires = NOW + 86400L * 7L;

        // 1. Positive Staging synthetic fixture: installed=6 < candidate=7 < recoveryRescue=8
        byte[] validStaging = buildReceipt(
                "jarvis-ota-evidence-v2", OtaCandidateGate.PACKAGE, "staging", DEVICE_UID,
                6, "bkp-staging-01", created, expires, BACKUP_SHA, 0, 8, RESCUE_SHA, "true", "true");
        byte[] validStagingSig = sign(validStaging, key);
        OtaRecoveryEvidenceGate.Verdict okStaging = OtaRecoveryEvidenceGate.verify(
                validStaging, validStagingSig, key.getPublic(), DEVICE_UID, 6, 7, NOW);
        expect(true, "LOCAL_RECOVERY_EVIDENCE_VERIFIED_NOT_AUTHORIZED_ALONE", okStaging, "valid staging");
        if (!"staging".equals(okStaging.channelProfile)
                || !BACKUP_SHA.equals(okStaging.backupArchiveSha256)
                || !RESCUE_SHA.equals(okStaging.rescueApkSha256)
                || okStaging.recoveryRescueVersionCode != 8) {
            throw new AssertionError("staging receipt metadata mismatch");
        }
        checks++;

        // 2. Positive Release synthetic fixture: installed=6 <= priorRescue=7 < candidate=8 < recoveryRescue=9
        byte[] validRelease = buildReceipt(
                "jarvis-ota-evidence-v2", OtaCandidateGate.PACKAGE, "release", DEVICE_UID,
                6, "bkp-release-01", created, expires, BACKUP_SHA, 7, 9, RESCUE_SHA, "true", "true");
        byte[] validReleaseSig = sign(validRelease, key);
        OtaRecoveryEvidenceGate.Verdict okRelease = OtaRecoveryEvidenceGate.verify(
                validRelease, validReleaseSig, key.getPublic(), DEVICE_UID, 6, 8, NOW);
        expect(true, "LOCAL_RECOVERY_EVIDENCE_VERIFIED_NOT_AUTHORIZED_ALONE", okRelease, "valid release");
        if (!"release".equals(okRelease.channelProfile)
                || okRelease.priorRescueFloorVersionCode != 7
                || okRelease.recoveryRescueVersionCode != 9) {
            throw new AssertionError("release receipt metadata mismatch");
        }
        checks++;

        // 3. Cross-policy Release ordering rejections
        // Release candidate <= priorRescueFloor (7 <= 7) -> EVIDENCE_RELEASE_NOT_ABOVE_PRIOR_RESCUE
        expect(false, "EVIDENCE_RELEASE_NOT_ABOVE_PRIOR_RESCUE",
                OtaRecoveryEvidenceGate.verify(validRelease, validReleaseSig, key.getPublic(), DEVICE_UID, 6, 7, NOW),
                "release candidate == priorRescueFloor");
        // Release missing priorRescueFloor (0) -> EVIDENCE_RELEASE_NOT_ABOVE_PRIOR_RESCUE
        byte[] releaseNoPrior = buildReceipt(
                "jarvis-ota-evidence-v2", OtaCandidateGate.PACKAGE, "release", DEVICE_UID,
                6, "bkp-rel-noprior", created, expires, BACKUP_SHA, 0, 9, RESCUE_SHA, "true", "true");
        expect(false, "EVIDENCE_RELEASE_NOT_ABOVE_PRIOR_RESCUE",
                OtaRecoveryEvidenceGate.verify(releaseNoPrior, sign(releaseNoPrior, key), key.getPublic(),
                        DEVICE_UID, 6, 8, NOW),
                "release without priorRescueFloor");
        // Release candidate == recoveryRescueVersionCode (9 <= 9) -> EVIDENCE_RECOVERY_RESCUE_NOT_ABOVE_CANDIDATE
        expect(false, "EVIDENCE_RECOVERY_RESCUE_NOT_ABOVE_CANDIDATE",
                OtaRecoveryEvidenceGate.verify(validRelease, validReleaseSig, key.getPublic(), DEVICE_UID, 6, 9, NOW),
                "release candidate == postReleaseRescue");
        // Staging candidate == recoveryRescueVersionCode (8 <= 8) -> EVIDENCE_RECOVERY_RESCUE_NOT_ABOVE_CANDIDATE
        expect(false, "EVIDENCE_RECOVERY_RESCUE_NOT_ABOVE_CANDIDATE",
                OtaRecoveryEvidenceGate.verify(validStaging, validStagingSig, key.getPublic(), DEVICE_UID, 6, 8, NOW),
                "staging candidate == recoveryRescue");
        // Candidate <= installed -> EVIDENCE_CANDIDATE_NOT_ABOVE_INSTALLED
        expect(false, "EVIDENCE_CANDIDATE_NOT_ABOVE_INSTALLED",
                OtaRecoveryEvidenceGate.verify(validStaging, validStagingSig, key.getPublic(), DEVICE_UID, 6, 6, NOW),
                "candidate <= installed");

        // 4. Signature / key failures
        byte[] badSig = validStagingSig.clone();
        badSig[0] ^= 0x55;
        expect(false, "EVIDENCE_SIGNATURE_INVALID",
                OtaRecoveryEvidenceGate.verify(validStaging, badSig, key.getPublic(), DEVICE_UID, 6, 7, NOW),
                "corrupted sig");
        expect(false, "EVIDENCE_SIGNATURE_INVALID",
                OtaRecoveryEvidenceGate.verify(validStaging, validStagingSig, wrongKey.getPublic(), DEVICE_UID, 6, 7, NOW),
                "wrong public key");
        expect(false, "EVIDENCE_SIGNATURE_INVALID",
                OtaRecoveryEvidenceGate.verify(null, validStagingSig, key.getPublic(), DEVICE_UID, 6, 7, NOW),
                "null receipt");

        // 5. Channel profile, UID, version, expiry
        byte[] badProfile = buildReceipt(
                "jarvis-ota-evidence-v2", OtaCandidateGate.PACKAGE, "canary", DEVICE_UID,
                6, "bkp-bad-prof", created, expires, BACKUP_SHA, 0, 8, RESCUE_SHA, "true", "true");
        expect(false, "EVIDENCE_CHANNEL_PROFILE_INVALID",
                OtaRecoveryEvidenceGate.verify(badProfile, sign(badProfile, key), key.getPublic(),
                        DEVICE_UID, 6, 7, NOW),
                "invalid channelProfile");

        expect(false, "EVIDENCE_DEVICE_UID_MISMATCH",
                OtaRecoveryEvidenceGate.verify(validStaging, validStagingSig, key.getPublic(), OTHER_UID, 6, 7, NOW),
                "device UID mismatch");
        expect(false, "EVIDENCE_DEVICE_UID_UNAVAILABLE",
                OtaRecoveryEvidenceGate.verify(validStaging, validStagingSig, key.getPublic(), null, 6, 7, NOW),
                "null local device UID");
        expect(false, "EVIDENCE_INSTALLED_VERSION_MISMATCH",
                OtaRecoveryEvidenceGate.verify(validStaging, validStagingSig, key.getPublic(), DEVICE_UID, 5, 7, NOW),
                "installed version mismatch");

        expect(false, "EVIDENCE_EXPIRED",
                OtaRecoveryEvidenceGate.verify(validStaging, validStagingSig, key.getPublic(), DEVICE_UID, 6, 7, expires),
                "expired at boundary");
        expect(false, "EVIDENCE_CREATED_IN_FUTURE",
                OtaRecoveryEvidenceGate.verify(validStaging, validStagingSig, key.getPublic(), DEVICE_UID, 6, 7,
                        created - 600L),
                "created too far in future");

        byte[] longLived = buildReceipt(
                "jarvis-ota-evidence-v2", OtaCandidateGate.PACKAGE, "staging", DEVICE_UID,
                6, "bkp-long", created, created + 91L * 86400L, BACKUP_SHA, 0, 8, RESCUE_SHA, "true", "true");
        expect(false, "EVIDENCE_LIFETIME_EXCESSIVE",
                OtaRecoveryEvidenceGate.verify(longLived, sign(longLived, key), key.getPublic(),
                        DEVICE_UID, 6, 7, NOW),
                "lifetime > 90d");

        // 6. Restore flags & digests & non-canonical CRLF
        byte[] noOffline = buildReceipt(
                "jarvis-ota-evidence-v2", OtaCandidateGate.PACKAGE, "staging", DEVICE_UID,
                6, "bkp-no-offline", created, expires, BACKUP_SHA, 0, 8, RESCUE_SHA, "false", "true");
        expect(false, "EVIDENCE_OFFLINE_RESTORE_NOT_VERIFIED",
                OtaRecoveryEvidenceGate.verify(noOffline, sign(noOffline, key), key.getPublic(),
                        DEVICE_UID, 6, 7, NOW),
                "offline restore false");

        byte[] destructive = buildReceipt(
                "jarvis-ota-evidence-v2", OtaCandidateGate.PACKAGE, "staging", DEVICE_UID,
                6, "bkp-destr", created, expires, BACKUP_SHA, 0, 8, RESCUE_SHA, "true", "false");
        expect(false, "EVIDENCE_NONDESTRUCTIVE_RESTORE_NOT_VERIFIED",
                OtaRecoveryEvidenceGate.verify(destructive, sign(destructive, key), key.getPublic(),
                        DEVICE_UID, 6, 7, NOW),
                "nonDestructive false");

        byte[] badBackupSha = buildReceipt(
                "jarvis-ota-evidence-v2", OtaCandidateGate.PACKAGE, "staging", DEVICE_UID,
                6, "bkp-badsha", created, expires, "not-sha256", 0, 8, RESCUE_SHA, "true", "true");
        expect(false, "EVIDENCE_BACKUP_DIGEST_INVALID",
                OtaRecoveryEvidenceGate.verify(badBackupSha, sign(badBackupSha, key), key.getPublic(),
                        DEVICE_UID, 6, 7, NOW),
                "bad backup digest");

        byte[] badRescueSha = buildReceipt(
                "jarvis-ota-evidence-v2", OtaCandidateGate.PACKAGE, "staging", DEVICE_UID,
                6, "bkp-badresc", created, expires, BACKUP_SHA, 0, 8, "bad-rescue-sha", "true", "true");
        expect(false, "EVIDENCE_RESCUE_DIGEST_INVALID",
                OtaRecoveryEvidenceGate.verify(badRescueSha, sign(badRescueSha, key), key.getPublic(),
                        DEVICE_UID, 6, 7, NOW),
                "bad rescue digest");

        byte[] crlf = new String(validStaging, StandardCharsets.US_ASCII)
                .replace("\n", "\r\n").getBytes(StandardCharsets.US_ASCII);
        expect(false, "EVIDENCE_NONCANONICAL_BYTES",
                OtaRecoveryEvidenceGate.verify(crlf, sign(crlf, key), key.getPublic(),
                        DEVICE_UID, 6, 7, NOW),
                "CRLF rejected");

        // 7. ADB-free pre-candidate UI import gate (verifyForInstalled)
        expect(true, "LOCAL_RECOVERY_EVIDENCE_VERIFIED_NOT_AUTHORIZED_ALONE",
                OtaRecoveryEvidenceGate.verifyForInstalled(
                        validStaging, validStagingSig, key.getPublic(), DEVICE_UID, 6, NOW),
                "verifyForInstalled valid staging");
        expect(true, "LOCAL_RECOVERY_EVIDENCE_VERIFIED_NOT_AUTHORIZED_ALONE",
                OtaRecoveryEvidenceGate.verifyForInstalled(
                        validRelease, sign(validRelease, key), key.getPublic(), DEVICE_UID, 6, NOW),
                "verifyForInstalled valid release");
        byte[] releaseNoCandidateSlot = buildReceipt(
                "jarvis-ota-evidence-v2", OtaCandidateGate.PACKAGE, "release", DEVICE_UID,
                6, "bkp-rel-noslot", created, expires, BACKUP_SHA, 7, 8, RESCUE_SHA, "true", "true");
        expect(false, "EVIDENCE_RELEASE_NOT_ABOVE_PRIOR_RESCUE",
                OtaRecoveryEvidenceGate.verifyForInstalled(
                        releaseNoCandidateSlot, sign(releaseNoCandidateSlot, key),
                        key.getPublic(), DEVICE_UID, 6, NOW),
                "verifyForInstalled release requires recoveryRescue > priorRescueFloor + 1");
        byte[] corruptImportSig = validStagingSig.clone();
        corruptImportSig[0] ^= 0x55;
        expect(false, "EVIDENCE_SIGNATURE_INVALID",
                OtaRecoveryEvidenceGate.verifyForInstalled(
                        validStaging, corruptImportSig, key.getPublic(), DEVICE_UID, 6, NOW),
                "verifyForInstalled rejects corrupted signature");

        System.out.println("OtaRecoveryEvidenceGateTest PASS: " + checks
                + " assertions across v2 staging & release cross-policy rules (SYNTHETIC HOST FIXTURE ONLY — NOT AUTHORITATIVE TV EVIDENCE)");
    }
}
