package it.akai.customremote.ai;

import android.content.Context;
import android.os.Build;
import java.io.File;
import java.io.FileInputStream;
import java.nio.file.Files;
import java.nio.file.LinkOption;

/**
 * READ-ONLY on-device preflight immediately preceding an eventual owner
 * PackageInstaller session. This class NEVER calls createSession(), commit(),
 * INSTALL intent, ADB, root, or filesystem delete.
 *
 * The result is strictly advisory: owner confirmation, recoverable APK/SQLite/
 * WAL/TLS backup evidence, and Android's own install confirmation are separate
 * MANDATORY gates. No remote AI command or Web Remote request may bypass them.
 */
public final class OtaAndroidInstallPreflight {
    private OtaAndroidInstallPreflight() {}

    public static final class Verdict {
        public final boolean readyForOwnerRecoveryReview;
        public final String code;

        private Verdict(boolean accepted, String code) {
            this.readyForOwnerRecoveryReview = accepted;
            this.code = code;
        }
    }

    private static Verdict deny(String code) {
        return new Verdict(false, code);
    }

    public static Verdict inspect(Context context, OtaUpdatePreparation.Result prepared) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P)
            return deny("ANDROID9_REQUIRED");
        if (context == null || prepared == null || !prepared.staged ||
                prepared.privateApk == null || prepared.verifiedCandidate == null)
            return deny("NO_SIGNED_STAGED_APK");
        if (!OtaCandidateGate.PACKAGE.equals(context.getPackageName()))
            return deny("UNEXPECTED_INSTALLER_PACKAGE");
        if (!"VERIFIED_PRIVATE_APK_NOT_INSTALLED".equals(prepared.code) ||
                prepared.candidateVersionCode != prepared.verifiedCandidate.versionCode ||
                prepared.expectedSha256 == null ||
                !prepared.expectedSha256.equalsIgnoreCase(prepared.verifiedCandidate.apkSha256))
            return deny("SIGNED_CANDIDATE_INCONSISTENT");

        try {
            File root = context.getFilesDir().getCanonicalFile();
            File expectedStage = new File(root, "ota-staging");
            File stage = expectedStage.getCanonicalFile();
            File input = prepared.privateApk.getCanonicalFile();
            String name = "jarvis-" + prepared.candidateVersionCode + "-" +
                    prepared.expectedSha256.toLowerCase(java.util.Locale.ROOT) + ".apk";
            if (!expectedStage.getAbsoluteFile().equals(stage) ||
                    Files.isSymbolicLink(expectedStage.toPath()) ||
                    !Files.isDirectory(stage.toPath(), LinkOption.NOFOLLOW_LINKS) ||
                    !stage.equals(input.getParentFile()) ||
                    !name.equals(input.getName()) ||
                    Files.isSymbolicLink(prepared.privateApk.toPath()) ||
                    !Files.isRegularFile(input.toPath(), LinkOption.NOFOLLOW_LINKS) ||
                    input.length() != prepared.verifiedCandidate.sizeBytes)
                return deny("UNTRUSTED_PRIVATE_APK_PATH");

            // Android must inspect the ACTUAL signed package/certificate again;
            // never rely on metadata previously supplied by the OTA server.
            OtaAndroidArchiveInspector.Result archive =
                    OtaAndroidArchiveInspector.inspect(context, input, prepared.verifiedCandidate);
            if (!archive.accepted) return deny("APK_" + archive.code);

            try (FileInputStream bytes = new FileInputStream(input)) {
                if (!OtaCandidateGate.verifyApkStream(bytes,
                        prepared.verifiedCandidate.sizeBytes, prepared.expectedSha256))
                    return deny("APK_BYTES_CHANGED");
            }
            if (!context.getPackageManager().canRequestPackageInstalls())
                return deny("ANDROID_UNKNOWN_SOURCE_PERMISSION_REQUIRED");

            // PackageInstaller duplicates the APK bytes into its own session.
            // Conservative space probe only; disk space must be checked again
            // during any future write and does not prove recovery capability.
            long required = prepared.verifiedCandidate.sizeBytes + (2L * 1024L * 1024L);
            if (root.getUsableSpace() < required)
                return deny("INSUFFICIENT_PRIVATE_STORAGE");

            return new Verdict(true, "TECHNICAL_PREFLIGHT_OK_BACKUP_AND_OWNER_NOT_CHECKED");
        } catch (Exception invalid) {
            return deny("ANDROID_PREFLIGHT_FAILED");
        }
    }
}
