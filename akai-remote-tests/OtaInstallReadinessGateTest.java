package it.akai.customremote;

import it.akai.customremote.ai.OtaInstallReadinessGate;

public final class OtaInstallReadinessGateTest {
    private static final String EXPECTED =
            "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899";
    private static final String OTHER =
            "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
    private static int checks;

    private static void expected(boolean ready, String code,
                                 boolean owner, boolean backup,
                                 boolean restore, boolean androidPermission,
                                 boolean signed, boolean archive,
                                 int oldVersion, int nextVersion,
                                 String expectedHash, String actualHash) {
        OtaInstallReadinessGate.Verdict result = OtaInstallReadinessGate.evaluate(
                owner, backup, restore, androidPermission, signed, archive,
                oldVersion, nextVersion, expectedHash, actualHash);
        if (result.readyForUserApprovedInstaller != ready ||
                !code.equals(result.code))
            throw new AssertionError("wrong verdict, expected " + code +
                    " but got " + result.code);
        checks++;
    }

    public static void main(String[] args) {
        // A PASS here verifies policy branching, NOT actual backup or device installation.
        expected(true, "READY_FOR_OWNER_OS_CONFIRMATION_NOT_INSTALLED",
                true,true,true,true,true,true,4,5,EXPECTED,EXPECTED);
        expected(false, "OWNER_CONFIRMATION_REQUIRED",
                false,true,true,true,true,true,4,5,EXPECTED,EXPECTED);
        expected(false, "BACKUP_NOT_VERIFIED",
                true,false,true,true,true,true,4,5,EXPECTED,EXPECTED);
        expected(false, "RECOVERY_NOT_VERIFIED",
                true,true,false,true,true,true,4,5,EXPECTED,EXPECTED);
        expected(false, "ANDROID_INSTALL_PERMISSION_MISSING",
                true,true,true,false,true,true,4,5,EXPECTED,EXPECTED);
        expected(false, "SIGNED_MANIFEST_NOT_VERIFIED",
                true,true,true,true,false,true,4,5,EXPECTED,EXPECTED);
        expected(false, "ARCHIVE_IDENTITY_NOT_VERIFIED",
                true,true,true,true,true,false,4,5,EXPECTED,EXPECTED);
        expected(false, "INVALID_UPGRADE_VERSION",
                true,true,true,true,true,true,4,4,EXPECTED,EXPECTED);
        expected(false, "INVALID_UPGRADE_VERSION",
                true,true,true,true,true,true,4,3,EXPECTED,EXPECTED);
        expected(false, "INVALID_UPGRADE_VERSION",
                true,true,true,true,true,true,0,5,EXPECTED,EXPECTED);
        expected(false, "INSTALL_INPUT_DIGEST_MISMATCH",
                true,true,true,true,true,true,4,5,EXPECTED,OTHER);
        expected(false, "INSTALL_INPUT_DIGEST_MISMATCH",
                true,true,true,true,true,true,4,5,EXPECTED,null);
        expected(false, "INSTALL_INPUT_DIGEST_MISMATCH",
                true,true,true,true,true,true,4,5,"not-a-hash",EXPECTED);
        expected(true, "READY_FOR_OWNER_OS_CONFIRMATION_NOT_INSTALLED",
                true,true,true,true,true,true,4,5,EXPECTED.toUpperCase(),EXPECTED);
        System.out.println("OtaInstallReadinessGateTest PASS: " + checks
                + " local policy checks; NO TV backup, installer, or restore executed");
    }
}
