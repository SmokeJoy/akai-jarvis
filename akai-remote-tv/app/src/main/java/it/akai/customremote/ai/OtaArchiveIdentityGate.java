package it.akai.customremote.ai;

/**
 * Fail-closed, pure Java policy for archive metadata read from Android PackageManager.
 *
 * This gate is intentionally separate from OtaCandidateGate (untrusted manifest fields).
 * Callers must pass the ACTUAL current signer digests obtained from PackageManager
 * for both installed package and downloaded APK, and a locally pinned expected signer.
 * It cannot install or authorize an APK by itself.
 */
public final class OtaArchiveIdentityGate {
    private OtaArchiveIdentityGate() {}

    public static final class Verdict {
        public final boolean accepted;
        public final String code;

        private Verdict(boolean accepted, String code) {
            this.accepted = accepted;
            this.code = code;
        }
    }

    private static Verdict deny(String code) {
        return new Verdict(false, code);
    }

    private static boolean sha256Equals(String first, String second) {
        return first != null && second != null &&
                first.matches("[0-9a-fA-F]{64}") &&
                second.matches("[0-9a-fA-F]{64}") &&
                first.equalsIgnoreCase(second);
    }

    /**
     * Validate package/archive facts, NOT metadata supplied by an OTA server.
     * minSdk/targetSdk come from the archive ApplicationInfo obtained via Android.
     * A value of zero or null means UNKNOWN => deny.
     */
    public static Verdict inspect(String archivePackage, long archiveVersion,
                                  int archiveMinSdk, int archiveTargetSdk,
                                  String archiveSignerSha256, long installedVersion,
                                  String installedSignerSha256, String pinnedSignerSha256) {
        if (!OtaCandidateGate.PACKAGE.equals(archivePackage))
            return deny("ARCHIVE_PACKAGE_MISMATCH");
        if (installedVersion < 1 || archiveVersion < 1)
            return deny("UNKNOWN_VERSION");
        if (archiveVersion <= installedVersion)
            return deny("NOT_AN_UPGRADE");
        if (archiveVersion > Integer.MAX_VALUE)
            return deny("UNSUPPORTED_VERSION_CODE");
        if (archiveMinSdk < 21 || archiveMinSdk > OtaCandidateGate.TV_API_LEVEL)
            return deny("ARCHIVE_MIN_SDK_INCOMPATIBLE");
        if (archiveTargetSdk < 1 || archiveTargetSdk > OtaCandidateGate.TV_API_LEVEL)
            return deny("ARCHIVE_TARGET_SDK_UNEXPECTED");
        if (!sha256Equals(installedSignerSha256, pinnedSignerSha256))
            return deny("INSTALLED_SIGNER_MISMATCH");
        if (!sha256Equals(archiveSignerSha256, pinnedSignerSha256))
            return deny("ARCHIVE_SIGNER_MISMATCH");
        return new Verdict(true, "ARCHIVE_IDENTITY_ACCEPTED_NOT_INSTALLED");
    }
}
