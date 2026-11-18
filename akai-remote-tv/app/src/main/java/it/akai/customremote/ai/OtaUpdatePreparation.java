package it.akai.customremote.ai;

import android.content.Context;
import android.os.Looper;
import java.io.File;
import java.io.FileInputStream;
import java.security.PublicKey;
import java.util.Set;

/**
 * Manual, fail-closed OTA preparation pipeline for Android 9.
 *
 * Not connected to boot, timers, user interface or PackageInstaller. Only a
 * future explicit owner "Check for updates" action on a worker may call this.
 * This verifies the installed signer, bundled OFFLINE trust anchor, detached
 * manifest signature, allowlisted HTTPS, downloaded APK SHA-256 and Android
 * archive package/signature before returning a private staging path.
 *
 * No install, upgrade, reboot, ADB, root, data mutation or cloud LLM calls.
 * A successful Result is only a candidate for backup/recovery preflight,
 * independent owner confirmation and a later OS PackageInstaller workflow.
 */
public final class OtaUpdatePreparation {
    private OtaUpdatePreparation() {}

    public static final class Result {
        public final boolean staged;
        public final String code;
        public final File privateApk;
        public final int candidateVersionCode;
        public final String expectedSha256;

        private Result(boolean staged, String code, File privateApk, int version, String digest) {
            this.staged = staged;
            this.code = code;
            this.privateApk = privateApk;
            this.candidateVersionCode = version;
            this.expectedSha256 = digest;
        }
    }

    private static Result deny(String code) {
        return new Result(false, code, null, 0, null);
    }

    public static Result prepare(Context context, String locallyConfiguredManifestUrl,
                                 Set<String> locallyTrustedHosts) {
        if (context == null || locallyConfiguredManifestUrl == null)
            return deny("PREPARE_MISSING_INPUT");
        if (Looper.myLooper() == Looper.getMainLooper())
            return deny("PREPARE_MAIN_THREAD_FORBIDDEN");
        if (Thread.currentThread().isInterrupted())
            return deny("PREPARE_CANCELLED");
        if (!OtaHttpsTransport.safeHttpsEndpoint(
                locallyConfiguredManifestUrl, locallyTrustedHosts, ".manifest"))
            return deny("PREPARE_MANIFEST_HOST_NOT_ALLOWED");

        OtaAndroidArchiveInspector.InstalledIdentity installed =
                OtaAndroidArchiveInspector.readInstalledIdentity(context);
        if (installed == null) return deny("PREPARE_INSTALLED_IDENTITY_UNKNOWN");

        // The release public key is bundled in the owner's original-signed APK.
        // Missing asset => OTA unavailable; NEVER accept a key from the server.
        PublicKey pinnedReleaseKey = OtaReleaseTrust.readBundledPublicKey(context);
        if (pinnedReleaseKey == null) return deny("PREPARE_RELEASE_KEY_NOT_PROVISIONED");

        OtaSignedReleaseManifest.Result signed;
        try {
            byte[] manifest = OtaHttpsTransport.fetchSmall(
                    locallyConfiguredManifestUrl, locallyTrustedHosts,
                    ".manifest", OtaCandidateGate.MAX_MANIFEST_BYTES);
            if (Thread.currentThread().isInterrupted()) return deny("PREPARE_CANCELLED");
            byte[] detachedSignature = OtaHttpsTransport.fetchSmall(
                    locallyConfiguredManifestUrl + ".sig", locallyTrustedHosts, ".sig", 512);
            signed = OtaSignedReleaseManifest.verify(
                    manifest, detachedSignature, pinnedReleaseKey,
                    (int) installed.versionCode, installed.signerSha256,
                    locallyTrustedHosts);
        } catch (Exception transportFailure) {
            return deny("PREPARE_MANIFEST_FETCH_FAILED");
        }
        if (!signed.verified()) return deny("PREPARE_" + signed.code);
        if (Thread.currentThread().isInterrupted()) return deny("PREPARE_CANCELLED");

        File staged = null;
        boolean accepted = false;
        try {
            staged = OtaHttpsTransport.stageVerifiedApk(
                    signed, locallyTrustedHosts, context.getFilesDir());
            if (Thread.currentThread().isInterrupted()) return deny("PREPARE_CANCELLED");

            OtaAndroidArchiveInspector.Result inspected =
                    OtaAndroidArchiveInspector.inspect(context, staged, signed.candidate);
            if (!inspected.accepted) return deny("PREPARE_" + inspected.code);

            // Rehash after the PackageManager archive inspection too. The later
            // owner-confirmed installer must perform its OWN final identity and
            // hash verification on the exact bytes it stages into Android.
            try (FileInputStream file = new FileInputStream(staged)) {
                if (!OtaCandidateGate.verifyApkStream(
                        file, signed.candidate.sizeBytes, signed.candidate.apkSha256))
                    return deny("PREPARE_ARCHIVE_CHANGED");
            }
            accepted = true;
            return new Result(true, "VERIFIED_PRIVATE_APK_NOT_INSTALLED",
                    staged, signed.candidate.versionCode, signed.candidate.apkSha256);
        } catch (Exception unavailable) {
            return deny("PREPARE_DOWNLOAD_OR_INSPECTION_FAILED");
        } finally {
            if (!accepted && staged != null) staged.delete();
        }
    }
}
