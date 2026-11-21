package it.akai.customremote.ai;

import android.content.Context;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.SigningInfo;
import android.os.Build;

import java.io.File;
import java.security.MessageDigest;
import java.util.Locale;

/**
 * Android 9 pre-install READ-ONLY inspection of the actual APK archive.
 *
 * No download, no UI, no PackageInstaller, and no ADB. It must be called
 * only AFTER verification of a pinned-key-signed release manifest and the
 * SHA-256 of the complete APK bytes. A successful result is NOT permission
 * to install or a substitute for owner-approved recovery and confirmation.
 */
public final class OtaAndroidArchiveInspector {
    private OtaAndroidArchiveInspector() {}

    public static final class Result {
        public final boolean accepted;
        public final String code;

        private Result(boolean accepted, String code) {
            this.accepted = accepted;
            this.code = code;
        }
    }

    private static Result deny(String code) { return new Result(false, code); }

    private static String signerSha256(SigningInfo signingInfo) {
        if (signingInfo == null || signingInfo.hasMultipleSigners()) return null;
        android.content.pm.Signature[] current = signingInfo.getApkContentsSigners();
        if (current == null || current.length != 1 || current[0] == null) return null;
        try {
            byte[] encodedCertificate = current[0].toByteArray();
            if (encodedCertificate == null || encodedCertificate.length == 0) return null;
            byte[] hash = MessageDigest.getInstance("SHA-256").digest(encodedCertificate);
            StringBuilder hex = new StringBuilder(hash.length * 2);
            for (byte b : hash) {
                hex.append(String.format(Locale.ROOT, "%02x", b & 0xff));
            }
            return hex.toString();
        } catch (Exception failure) {
            return null;
        }
    }

    /** Trusted installed package identity from Android, NEVER from OTA JSON/HTML. */
    public static final class InstalledIdentity {
        public final long versionCode;
        public final String signerSha256;

        private InstalledIdentity(long versionCode, String signerSha256) {
            this.versionCode = versionCode;
            this.signerSha256 = signerSha256;
        }
    }

    public static InstalledIdentity readInstalledIdentity(Context context) {
        if (context == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.P)
            return null;
        try {
            PackageInfo installed = context.getPackageManager().getPackageInfo(
                    OtaCandidateGate.PACKAGE, PackageManager.GET_SIGNING_CERTIFICATES);
            if (installed == null || installed.getLongVersionCode() < 1 ||
                    installed.getLongVersionCode() > Integer.MAX_VALUE)
                return null;
            String signer = signerSha256(installed.signingInfo);
            if (signer == null || !OtaCandidateGate.EXPECTED_SIGNER_SHA256.equalsIgnoreCase(signer))
                return null;
            return new InstalledIdentity(installed.getLongVersionCode(), signer);
        } catch (Exception unavailable) {
            return null;
        }
    }

    /**
     * Exactly one same-signer, higher-version package on the installed Android 9
     * device. The archive MUST already be in the app's private files directory;
     * caller must ensure its previously checked bytes cannot change before
     * a future owner-confirmed installation step.
     *
     * expectedCandidate metadata is untrusted unless a separate pinned-key
     * manifest-signature check succeeded. This class NEVER treats it as proof
     * of certificate validity or as authorization to install.
     */
    public static Result inspect(Context context, File downloadedApk,
                                 OtaCandidateGate.Candidate expectedCandidate) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P)
            return deny("ANDROID_API_UNSUPPORTED");
        if (context == null || downloadedApk == null || expectedCandidate == null)
            return deny("MISSING_INSPECTION_INPUT");
        try {
            File privateDir = context.getFilesDir().getCanonicalFile();
            File archiveFile = downloadedApk.getCanonicalFile();
            String root = privateDir.getPath() + File.separator;
            if (!archiveFile.getPath().startsWith(root) ||
                    !archiveFile.getName().endsWith(".apk") ||
                    !archiveFile.isFile() || archiveFile.length() < 1024 ||
                    archiveFile.length() > OtaCandidateGate.MAX_APK_BYTES)
                return deny("ARCHIVE_NOT_PRIVATE_OR_INVALID");

            PackageManager pm = context.getPackageManager();
            PackageInfo archive = pm.getPackageArchiveInfo(archiveFile.getPath(),
                    PackageManager.GET_SIGNING_CERTIFICATES);
            PackageInfo installed = pm.getPackageInfo(OtaCandidateGate.PACKAGE,
                    PackageManager.GET_SIGNING_CERTIFICATES);
            if (archive == null || installed == null || archive.applicationInfo == null)
                return deny("ARCHIVE_OR_INSTALLED_INFO_UNKNOWN");

            String archiveDigest = signerSha256(archive.signingInfo);
            String installedDigest = signerSha256(installed.signingInfo);
            OtaArchiveIdentityGate.Verdict verdict = OtaArchiveIdentityGate.inspect(
                    archive.packageName, archive.getLongVersionCode(),
                    archive.applicationInfo.minSdkVersion,
                    archive.applicationInfo.targetSdkVersion,
                    archiveDigest, installed.getLongVersionCode(), installedDigest,
                    OtaCandidateGate.EXPECTED_SIGNER_SHA256);
            if (!verdict.accepted) return deny(verdict.code);
            if (!archive.packageName.equals(expectedCandidate.packageName) ||
                    archive.getLongVersionCode() != expectedCandidate.versionCode ||
                    archive.applicationInfo.minSdkVersion != expectedCandidate.minSdk)
                return deny("SIGNED_MANIFEST_ARCHIVE_MISMATCH");
            return new Result(true, "ARCHIVE_INSPECTED_NOT_AUTHORIZED_FOR_INSTALL");
        } catch (PackageManager.NameNotFoundException unavailable) {
            return deny("INSTALLED_PACKAGE_NOT_FOUND");
        } catch (Exception failure) {
            return deny("ARCHIVE_INSPECTION_FAILED");
        }
    }
}
