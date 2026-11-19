package it.akai.customremote.ai;

/**
 * Fail-closed decision policy for a future owner-initiated PackageInstaller
 * session on Android 9. This is NOT the installation and does not assert any
 * backup, restore, owner confirmation, or signing check has actually occurred.
 *
 * Inputs must be obtained from trusted local evidence by the Android caller:
 * - owner action: a visible, explicit TV confirmation (not a REST/AI command)
 * - backup and recovery: completed, independently checked TV preflight
 * - installed signer and archive signer: PackageManager on the actual device
 * - APK digest: rehashed from the bytes that will be written into the session.
 *
 * Supplying true booleans without the corresponding real evidence is a bug.
 */
public final class OtaInstallReadinessGate {
    private OtaInstallReadinessGate() {}

    public static final class Verdict {
        public final boolean readyForUserApprovedInstaller;
        public final String code;

        private Verdict(boolean allowed, String code) {
            this.readyForUserApprovedInstaller = allowed;
            this.code = code;
        }
    }

    private static Verdict deny(String code) { return new Verdict(false, code); }

    private static boolean matchingSha(String left, String right) {
        return left != null && right != null &&
                left.matches("[0-9a-fA-F]{64}") &&
                right.matches("[0-9a-fA-F]{64}") &&
                left.equalsIgnoreCase(right);
    }

    public static Verdict evaluate(boolean physicallyOwnerInitiated,
                                   boolean backupEvidenceChecked,
                                   boolean restoreProcedureChecked,
                                   boolean androidInstallerPermissionGranted,
                                   boolean signedManifestVerified,
                                   boolean realArchiveIdentityVerified,
                                   int installedVersionCode,
                                   int nextVersionCode,
                                   String expectedApkSha256,
                                   String readBackSha256) {
        if (!physicallyOwnerInitiated) return deny("OWNER_CONFIRMATION_REQUIRED");
        if (!backupEvidenceChecked) return deny("BACKUP_NOT_VERIFIED");
        if (!restoreProcedureChecked) return deny("RECOVERY_NOT_VERIFIED");
        if (!androidInstallerPermissionGranted) return deny("ANDROID_INSTALL_PERMISSION_MISSING");
        if (!signedManifestVerified) return deny("SIGNED_MANIFEST_NOT_VERIFIED");
        if (!realArchiveIdentityVerified) return deny("ARCHIVE_IDENTITY_NOT_VERIFIED");
        if (installedVersionCode < 1 || nextVersionCode <= installedVersionCode)
            return deny("INVALID_UPGRADE_VERSION");
        if (!matchingSha(expectedApkSha256, readBackSha256))
            return deny("INSTALL_INPUT_DIGEST_MISMATCH");
        return new Verdict(true, "READY_FOR_OWNER_OS_CONFIRMATION_NOT_INSTALLED");
    }
}
