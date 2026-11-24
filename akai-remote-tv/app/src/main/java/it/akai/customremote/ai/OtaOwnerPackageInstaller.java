package it.akai.customremote.ai;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInstaller;
import android.os.Build;

import it.akai.customremote.OtaInstallResultReceiver;

import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.security.MessageDigest;
import java.util.Locale;

/**
 * Android 9 owner-confirmed OTA PackageInstaller session.
 *
 * NOT wired to an automatic trigger. Only an explicit on-TV confirmation
 * AFTER independently verified APK/SQLite/WAL/TLS backup and RECOVERY may
 * invoke this. A downloaded candidate alone is NOT permission to install.
 * A session write is not an install; commit delegates final approval to OS.
 *
 * No INSTALL_PACKAGES privileged permission, no silent install, no root/ADB,
 * no removal of installed app, no rollback assumption. Status and OS consent
 * must be handled by the non-exported OtaInstallResultReceiver.
 */
public final class OtaOwnerPackageInstaller {
    private OtaOwnerPackageInstaller() {}

    public static final class Outcome {
        public final boolean submittedToAndroid;
        public final String code;

        private Outcome(boolean submitted, String code) {
            this.submittedToAndroid = submitted;
            this.code = code;
        }
    }

    private static Outcome deny(String code) { return new Outcome(false, code); }

    /**
     * This function is BLOCKED unless the owner has explicitly confirmed
     * THIS specific candidate on the physical TV and independently checked
     * actual backup+restoration evidence. Do NOT pass guessed true booleans.
     * It must be called on a short-lived background worker, never at boot.
     *
     * Only MainActivity's physical two-checkbox owner confirmation dialog after
     * preflight may invoke this method; never wire it to Web API, AI or boot.
     */
    public static Outcome submitAfterPhysicalOwnerApproval(
            Context context,
            OtaUpdatePreparation.Result prepared,
            boolean ownerApprovedOnTv,
            boolean backupEvidenceIndependentlyVerified,
            boolean restorationEvidenceIndependentlyVerified) {
        return submitAfterPhysicalOwnerApproval(
                context, prepared, ownerApprovedOnTv,
                backupEvidenceIndependentlyVerified,
                restorationEvidenceIndependentlyVerified,
                OtaCandidateGate.EXPECTED_SIGNER_SHA256);
    }

    static Outcome submitAfterPhysicalOwnerApproval(
            Context context,
            OtaUpdatePreparation.Result prepared,
            boolean ownerApprovedOnTv,
            boolean backupEvidenceIndependentlyVerified,
            boolean restorationEvidenceIndependentlyVerified,
            String expectedSignerSha256) {

        if (Build.VERSION.SDK_INT != Build.VERSION_CODES.P)
            return deny("ANDROID9_ONLY");
        if (context == null || prepared == null || !ownerApprovedOnTv)
            return deny("PHYSICAL_OWNER_APPROVAL_REQUIRED");
        if (!backupEvidenceIndependentlyVerified ||
                !restorationEvidenceIndependentlyVerified)
            return deny("BACKUP_AND_RECOVERY_EVIDENCE_REQUIRED");

        if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper())
            return deny("INSTALL_MAIN_THREAD_FORBIDDEN");
        if (Thread.currentThread().isInterrupted())
            return deny("INSTALL_CANCELLED");

        OtaAndroidInstallPreflight.Verdict preflight =
                OtaAndroidInstallPreflight.inspect(context, prepared, expectedSignerSha256);
        if (!preflight.readyForOwnerRecoveryReview)
            return deny("PREFLIGHT_" + preflight.code);

        OtaAndroidArchiveInspector.InstalledIdentity installed =
                OtaAndroidArchiveInspector.readInstalledIdentity(context, expectedSignerSha256);
        if (installed == null) return deny("INSTALLED_IDENTITY_NOT_TRUSTED");

        PackageInstaller installer = context.getPackageManager().getPackageInstaller();
        if (installer == null) return deny("PACKAGE_INSTALLER_UNAVAILABLE");
        PackageInstaller.Session session = null;
        int sessionId = -1;
        boolean committed = false;
        try {
            PackageInstaller.SessionParams params = new PackageInstaller.SessionParams(
                    PackageInstaller.SessionParams.MODE_FULL_INSTALL);
            params.setAppPackageName(OtaCandidateGate.PACKAGE);
            params.setSize(prepared.verifiedCandidate.sizeBytes);

            sessionId = installer.createSession(params);
            session = installer.openSession(sessionId);

            // Use the exact verified private APK. The source is read again
            // just before committing; no trust in remote manifest alone.
            try (FileInputStream in = new FileInputStream(prepared.privateApk);
                 OutputStream out = session.openWrite("base.apk", 0L,
                         prepared.verifiedCandidate.sizeBytes)) {
                OtaSessionByteTransfer.copyVerified(
                        in, out, prepared.verifiedCandidate.sizeBytes,
                        prepared.expectedSha256);
                session.fsync(out);
            }
            if (Thread.currentThread().isInterrupted())
                throw new IOException("INSTALL_CANCELLED");

            // Read actual bytes INSIDE the PackageInstaller session. This
            // catches corruption or stale file replacement after initial
            // staging and BEFORE the session is irreversibly committed.
            String sessionHash = hexSha256FromSession(session,
                    prepared.verifiedCandidate.sizeBytes);
            if (sessionHash == null)
                throw new IOException("INSTALL_SESSION_HASH_UNAVAILABLE");

            OtaInstallReadinessGate.Verdict decision =
                    OtaInstallReadinessGate.evaluate(
                            ownerApprovedOnTv,
                            backupEvidenceIndependentlyVerified,
                            restorationEvidenceIndependentlyVerified,
                            context.getPackageManager().canRequestPackageInstalls(),
                            prepared.verifiedCandidate != null &&
                                    "VERIFIED_PRIVATE_APK_NOT_INSTALLED".equals(prepared.code),
                            preflight.readyForOwnerRecoveryReview,
                            (int) installed.versionCode, prepared.candidateVersionCode,
                            prepared.expectedSha256, sessionHash);
            if (!decision.readyForUserApprovedInstaller)
                throw new IOException("INSTALL_DENIED_" + decision.code);

            // Receiver is explicit and exported=false; callback may request
            // OS approval via STATUS_PENDING_USER_ACTION.
            Intent callback = new Intent(context, OtaInstallResultReceiver.class);
            callback.setAction(OtaInstallResultReceiver.ACTION_OTA_INSTALL_RESULT);
            callback.setPackage(context.getPackageName());
            callback.putExtra(OtaInstallResultReceiver.EXTRA_EXPECTED_SESSION_ID, sessionId);
            callback.putExtra(OtaInstallResultReceiver.EXTRA_EXPECTED_VERSION_CODE,
                    prepared.candidateVersionCode);
            PendingIntent pending = PendingIntent.getBroadcast(context, sessionId,
                    callback, PendingIntent.FLAG_UPDATE_CURRENT);
            session.commit(pending.getIntentSender());
            committed = true;
            return new Outcome(true, "SUBMITTED_TO_ANDROID_AWAITING_OS_USER_RESULT");
        } catch (Exception failure) {
            // Deliberately do not include potentially sensitive exception
            // messages, local paths or certificate data in UI/result.
            return deny("INSTALL_SESSION_REJECTED");
        } finally {
            if (session != null) {
                if (!committed) {
                    try { session.abandon(); } catch (Exception ignored) {}
                }
                try { session.close(); } catch (Exception ignored) {}
            } else if (!committed && sessionId >= 0) {
                try { installer.abandonSession(sessionId); } catch (Exception ignored) {}
            }
        }
    }

    private static String hexSha256FromSession(PackageInstaller.Session session,
                                               long expectedBytes) throws IOException {
        try (InputStream stream = session.openRead("base.apk")) {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            long total = 0;
            byte[] buffer = new byte[16 * 1024];
            int emptyReads = 0;
            while (true) {
                if (Thread.currentThread().isInterrupted())
                    throw new IOException("SESSION_RECHECK_CANCELLED");
                int n = stream.read(buffer);
                if (n < 0) break;
                if (n == 0) {
                    if (++emptyReads >= 3)
                        throw new IOException("SESSION_RECHECK_STALLED");
                    continue;
                }
                emptyReads = 0;
                if (n > expectedBytes - total)
                    throw new IOException("SESSION_RECHECK_EXCESS");
                digest.update(buffer, 0, n);
                total += n;
            }
            if (total != expectedBytes)
                throw new IOException("SESSION_RECHECK_TRUNCATED");
            byte[] sum = digest.digest();
            StringBuilder hex = new StringBuilder(64);
            for (byte b : sum) hex.append(String.format(Locale.ROOT, "%02x", b & 0xff));
            return hex.toString();
        } catch (java.security.NoSuchAlgorithmException invalidProvider) {
            throw new IOException("SESSION_SHA256_UNAVAILABLE", invalidProvider);
        }
    }
}
