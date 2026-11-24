package it.akai.customremote;

import it.akai.customremote.ai.OtaCandidateGate;
import it.akai.customremote.ai.OtaRecoveryEvidenceGate;

import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.Signature;

/**
 * Host-only policy and signature tests for OtaRecoveryEvidenceGate.
 * Uses ONLY ephemeral RSA keys; positive verdicts here exercise synthetic
 * NON_AUTHORITATIVE fixtures and NEVER attest real AKAI TV backups.
 */
public final class OtaRecoveryEvidenceGateTest {
    private static final String DEVICE_UID = "akai-tv-fixture-uid-001";
    private static final String OTHER_UID = "akai-tv-other-uid-999";
    private static final String BACKUP_SHA =
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    private static final long NOW = 1_795_000_000L;
    private static int checks;

    private OtaRecoveryEvidenceGateTest() {}

    private static byte[] buildReceipt(String format, String pkg, String uid,
                                       int installed, String backupId,
                                       long created, long expires, String sha,
                                       int rescueVersion, String offlineOk,
                                       String nonDestructiveOk) {
        String text = "format=" + format + "\n"
                + "package=" + pkg + "\n"
                + "deviceUid=" + uid + "\n"
                + "installedVersionCode=" + installed + "\n"
                + "backupId=" + backupId + "\n"
                + "backupCreatedEpochSec=" + created + "\n"
                + "backupExpiresEpochSec=" + expires + "\n"
                + "backupArchiveSha256=" + sha + "\n"
                + "rescueVersionCode=" + rescueVersion + "\n"
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
        byte[] valid = buildReceipt(
                "jarvis-ota-evidence-v1", OtaCandidateGate.PACKAGE, DEVICE_UID,
                6, "bkp-20261124-01", created, expires, BACKUP_SHA, 9, "true", "true");
        byte[] validSig = sign(valid, key);

        // Positive synthetic fixture (NON_AUTHORITATIVE for physical TV)
        OtaRecoveryEvidenceGate.Verdict ok = OtaRecoveryEvidenceGate.verify(
                valid, validSig, key.getPublic(), DEVICE_UID, 6, 8, NOW);
        expect(true, "LOCAL_RECOVERY_EVIDENCE_VERIFIED_NOT_AUTHORIZED_ALONE", ok, "valid synthetic");
        if (!"bkp-20261124-01".equals(ok.backupId) || ok.rescueVersionCode != 9) {
            throw new AssertionError("receipt metadata not preserved");
        }
        checks++;

        // Signature / key failures
        byte[] badSig = validSig.clone();
        badSig[0] ^= 0x55;
        expect(false, "EVIDENCE_SIGNATURE_INVALID",
                OtaRecoveryEvidenceGate.verify(valid, badSig, key.getPublic(), DEVICE_UID, 6, 8, NOW),
                "corrupted sig");
        expect(false, "EVIDENCE_SIGNATURE_INVALID",
                OtaRecoveryEvidenceGate.verify(valid, validSig, wrongKey.getPublic(), DEVICE_UID, 6, 8, NOW),
                "wrong public key");
        expect(false, "EVIDENCE_SIGNATURE_INVALID",
                OtaRecoveryEvidenceGate.verify(null, validSig, key.getPublic(), DEVICE_UID, 6, 8, NOW),
                "null receipt");

        // Device UID & installed version mismatch
        expect(false, "EVIDENCE_DEVICE_UID_MISMATCH",
                OtaRecoveryEvidenceGate.verify(valid, validSig, key.getPublic(), OTHER_UID, 6, 8, NOW),
                "device UID mismatch");
        expect(false, "EVIDENCE_DEVICE_UID_UNAVAILABLE",
                OtaRecoveryEvidenceGate.verify(valid, validSig, key.getPublic(), null, 6, 8, NOW),
                "null local device UID");
        expect(false, "EVIDENCE_INSTALLED_VERSION_MISMATCH",
                OtaRecoveryEvidenceGate.verify(valid, validSig, key.getPublic(), DEVICE_UID, 5, 8, NOW),
                "installed version mismatch");

        // Expiration / time bounds
        expect(false, "EVIDENCE_EXPIRED",
                OtaRecoveryEvidenceGate.verify(valid, validSig, key.getPublic(), DEVICE_UID, 6, 8, expires),
                "expired at boundary");
        expect(false, "EVIDENCE_CREATED_IN_FUTURE",
                OtaRecoveryEvidenceGate.verify(valid, validSig, key.getPublic(), DEVICE_UID, 6, 8,
                        created - 600L),
                "created too far in future");

        byte[] longLived = buildReceipt(
                "jarvis-ota-evidence-v1", OtaCandidateGate.PACKAGE, DEVICE_UID,
                6, "bkp-20261124-02", created, created + 91L * 86400L, BACKUP_SHA, 9, "true", "true");
        expect(false, "EVIDENCE_LIFETIME_EXCESSIVE",
                OtaRecoveryEvidenceGate.verify(longLived, sign(longLived, key), key.getPublic(),
                        DEVICE_UID, 6, 8, NOW),
                "lifetime > 90d");

        byte[] invertedWindow = buildReceipt(
                "jarvis-ota-evidence-v1", OtaCandidateGate.PACKAGE, DEVICE_UID,
                6, "bkp-20261124-03", NOW, NOW - 1L, BACKUP_SHA, 9, "true", "true");
        expect(false, "EVIDENCE_WINDOW_INVALID",
                OtaRecoveryEvidenceGate.verify(invertedWindow, sign(invertedWindow, key),
                        key.getPublic(), DEVICE_UID, 6, 8, NOW),
                "expires <= created");

        // Rescue versionCode ordering & restore flags
        expect(false, "EVIDENCE_RESCUE_NOT_ABOVE_CANDIDATE",
                OtaRecoveryEvidenceGate.verify(valid, validSig, key.getPublic(), DEVICE_UID, 6, 9, NOW),
                "rescue == candidate (9 <= 9)");
        expect(false, "EVIDENCE_RESCUE_NOT_ABOVE_CANDIDATE",
                OtaRecoveryEvidenceGate.verify(valid, validSig, key.getPublic(), DEVICE_UID, 6, 10, NOW),
                "rescue < candidate (9 < 10)");

        byte[] noOffline = buildReceipt(
                "jarvis-ota-evidence-v1", OtaCandidateGate.PACKAGE, DEVICE_UID,
                6, "bkp-20261124-04", created, expires, BACKUP_SHA, 9, "false", "true");
        expect(false, "EVIDENCE_OFFLINE_RESTORE_NOT_VERIFIED",
                OtaRecoveryEvidenceGate.verify(noOffline, sign(noOffline, key), key.getPublic(),
                        DEVICE_UID, 6, 8, NOW),
                "offline restore false");

        byte[] destructive = buildReceipt(
                "jarvis-ota-evidence-v1", OtaCandidateGate.PACKAGE, DEVICE_UID,
                6, "bkp-20261124-05", created, expires, BACKUP_SHA, 9, "true", "false");
        expect(false, "EVIDENCE_NONDESTRUCTIVE_RESTORE_NOT_VERIFIED",
                OtaRecoveryEvidenceGate.verify(destructive, sign(destructive, key), key.getPublic(),
                        DEVICE_UID, 6, 8, NOW),
                "nonDestructive false");

        // Bad digest / wrong package / non-canonical CRLF
        byte[] badDigest = buildReceipt(
                "jarvis-ota-evidence-v1", OtaCandidateGate.PACKAGE, DEVICE_UID,
                6, "bkp-20261124-06", created, expires, "not-sha256", 9, "true", "true");
        expect(false, "EVIDENCE_BACKUP_DIGEST_INVALID",
                OtaRecoveryEvidenceGate.verify(badDigest, sign(badDigest, key), key.getPublic(),
                        DEVICE_UID, 6, 8, NOW),
                "bad backup digest");

        byte[] wrongPkg = buildReceipt(
                "jarvis-ota-evidence-v1", "org.evil.other", DEVICE_UID,
                6, "bkp-20261124-07", created, expires, BACKUP_SHA, 9, "true", "true");
        expect(false, "EVIDENCE_PACKAGE_MISMATCH",
                OtaRecoveryEvidenceGate.verify(wrongPkg, sign(wrongPkg, key), key.getPublic(),
                        DEVICE_UID, 6, 8, NOW),
                "wrong package");

        byte[] crlf = new String(valid, StandardCharsets.US_ASCII)
                .replace("\n", "\r\n").getBytes(StandardCharsets.US_ASCII);
        expect(false, "EVIDENCE_NONCANONICAL_BYTES",
                OtaRecoveryEvidenceGate.verify(crlf, sign(crlf, key), key.getPublic(),
                        DEVICE_UID, 6, 8, NOW),
                "CRLF rejected");

        System.out.println("OtaRecoveryEvidenceGateTest PASS: " + checks
                + " assertions (SYNTHETIC HOST FIXTURE ONLY — NOT AUTHORITATIVE TV EVIDENCE)");
    }
}
