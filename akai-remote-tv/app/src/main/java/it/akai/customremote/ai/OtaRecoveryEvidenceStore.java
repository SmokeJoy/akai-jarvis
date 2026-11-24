package it.akai.customremote.ai;

import android.content.ContentResolver;
import android.content.Context;
import android.os.Build;
import android.provider.Settings;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.PublicKey;

/**
 * Private on-device reader/verifier for PC-off OTA recovery evidence receipts.
 *
 * Reads only from app-private filesDir/ota-evidence without network calls or PC
 * dependency at runtime, binding cryptographic receipt verification to the
 * bundled trust anchor and Android Settings.Secure.ANDROID_ID.
 */
public final class OtaRecoveryEvidenceStore {
    public static final String EVIDENCE_SUBDIR = "ota-evidence";
    public static final String RECEIPT_FILENAME = "ota-recovery-evidence.receipt";
    public static final String SIGNATURE_FILENAME = "ota-recovery-evidence.receipt.sig";
    private static final int MAX_SIG_BYTES = 512;

    private OtaRecoveryEvidenceStore() {}

    public static File evidenceDirectory(Context context) throws IOException {
        if (context == null || context.getFilesDir() == null) {
            throw new IOException("EVIDENCE_STORAGE_UNAVAILABLE");
        }
        File root = context.getFilesDir().getCanonicalFile();
        return new File(root, EVIDENCE_SUBDIR);
    }

    public static OtaRecoveryEvidenceGate.Verdict loadAndVerify(
            Context context, int actualInstalledVersionCode, int candidateVersionCode) {
        return loadAndVerify(context, actualInstalledVersionCode,
                candidateVersionCode, System.currentTimeMillis() / 1000L);
    }

    static OtaRecoveryEvidenceGate.Verdict loadAndVerify(
            Context context, int actualInstalledVersionCode,
            int candidateVersionCode, long nowEpochSec) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            return OtaRecoveryEvidenceGate.externalDeny("EVIDENCE_ANDROID_API_UNSUPPORTED");
        }
        if (context == null || context.getFilesDir() == null) {
            return OtaRecoveryEvidenceGate.externalDeny("EVIDENCE_STORAGE_UNAVAILABLE");
        }

        try {
            File root = context.getFilesDir().getCanonicalFile();
            File expectedDir = new File(root, EVIDENCE_SUBDIR);
            Path dirPath = expectedDir.toPath();
            if (Files.isSymbolicLink(dirPath) ||
                    !Files.isDirectory(dirPath, LinkOption.NOFOLLOW_LINKS) ||
                    !expectedDir.getCanonicalFile().equals(expectedDir.getAbsoluteFile())) {
                return OtaRecoveryEvidenceGate.externalDeny("EVIDENCE_RECEIPT_MISSING");
            }

            File receiptFile = new File(expectedDir, RECEIPT_FILENAME);
            File sigFile = new File(expectedDir, SIGNATURE_FILENAME);
            if (!Files.exists(receiptFile.toPath(), LinkOption.NOFOLLOW_LINKS) ||
                    !Files.exists(sigFile.toPath(), LinkOption.NOFOLLOW_LINKS)) {
                return OtaRecoveryEvidenceGate.externalDeny("EVIDENCE_RECEIPT_MISSING");
            }

            byte[] receiptBytes = readBoundedPrivateFile(
                    receiptFile, expectedDir, OtaRecoveryEvidenceGate.MAX_RECEIPT_BYTES);
            byte[] sigBytes = readBoundedPrivateFile(sigFile, expectedDir, MAX_SIG_BYTES);
            if (receiptBytes == null || sigBytes == null) {
                return OtaRecoveryEvidenceGate.externalDeny("EVIDENCE_RECEIPT_UNREADABLE");
            }

            return verifyBytesWithLocalAnchor(
                    context, receiptBytes, sigBytes,
                    actualInstalledVersionCode, candidateVersionCode, nowEpochSec);
        } catch (Exception unavailable) {
            return OtaRecoveryEvidenceGate.externalDeny("EVIDENCE_STORAGE_UNAVAILABLE");
        }
    }

    /**
     * Local PC-off import helper: verifies the detached RSA receipt BEFORE
     * writing atomically into private filesDir/ota-evidence. Never writes
     * unverified or forged files and never transmits private material.
     */
    public static OtaRecoveryEvidenceGate.Verdict importVerifiedReceipt(
            Context context, byte[] receiptBytes, byte[] signatureBytes,
            int actualInstalledVersionCode, int candidateVersionCode, long nowEpochSec) {
        OtaRecoveryEvidenceGate.Verdict verdict = verifyBytesWithLocalAnchor(
                context, receiptBytes, signatureBytes,
                actualInstalledVersionCode, candidateVersionCode, nowEpochSec);
        if (!verdict.accepted) return verdict;

        try {
            File root = context.getFilesDir().getCanonicalFile();
            File dir = new File(root, EVIDENCE_SUBDIR);
            if (!Files.exists(dir.toPath(), LinkOption.NOFOLLOW_LINKS)) {
                if (!dir.mkdir()) {
                    return OtaRecoveryEvidenceGate.externalDeny("EVIDENCE_STORAGE_UNAVAILABLE");
                }
            }
            if (Files.isSymbolicLink(dir.toPath()) ||
                    !Files.isDirectory(dir.toPath(), LinkOption.NOFOLLOW_LINKS) ||
                    !dir.getCanonicalFile().equals(dir.getAbsoluteFile())) {
                return OtaRecoveryEvidenceGate.externalDeny("EVIDENCE_STORAGE_UNAVAILABLE");
            }

            writeAtomicPrivateFile(dir, RECEIPT_FILENAME, receiptBytes);
            writeAtomicPrivateFile(dir, SIGNATURE_FILENAME, signatureBytes);
            return verdict;
        } catch (Exception writeFailure) {
            return OtaRecoveryEvidenceGate.externalDeny("EVIDENCE_STORAGE_UNAVAILABLE");
        }
    }

    private static OtaRecoveryEvidenceGate.Verdict verifyBytesWithLocalAnchor(
            Context context, byte[] receiptBytes, byte[] signatureBytes,
            int actualInstalledVersionCode, int candidateVersionCode, long nowEpochSec) {
        if (context == null) {
            return OtaRecoveryEvidenceGate.externalDeny("EVIDENCE_STORAGE_UNAVAILABLE");
        }
        PublicKey pinnedKey = OtaReleaseTrust.readBundledPublicKey(context);
        if (pinnedKey == null) {
            return OtaRecoveryEvidenceGate.externalDeny("EVIDENCE_TRUST_KEY_NOT_PROVISIONED");
        }
        ContentResolver resolver = context.getContentResolver();
        String deviceUid = Settings.Secure.getString(resolver, Settings.Secure.ANDROID_ID);
        return OtaRecoveryEvidenceGate.verify(
                receiptBytes, signatureBytes, pinnedKey, deviceUid,
                actualInstalledVersionCode, candidateVersionCode, nowEpochSec);
    }

    private static byte[] readBoundedPrivateFile(File target, File canonicalDir, int maxBytes) {
        try {
            Path p = target.toPath();
            if (Files.isSymbolicLink(p) ||
                    !Files.isRegularFile(p, LinkOption.NOFOLLOW_LINKS) ||
                    !canonicalDir.equals(target.getCanonicalFile().getParentFile())) {
                return null;
            }
            long len = target.length();
            if (len <= 0L || len > maxBytes) return null;

            ByteArrayOutputStream out = new ByteArrayOutputStream((int) len);
            byte[] buf = new byte[1024];
            int total = 0;
            try (FileInputStream in = new FileInputStream(target)) {
                int n;
                while ((n = in.read(buf)) != -1) {
                    if (n == 0) continue;
                    if (total + n > maxBytes) return null;
                    out.write(buf, 0, n);
                    total += n;
                }
            }
            return (total > 0) ? out.toByteArray() : null;
        } catch (Exception e) {
            return null;
        }
    }

    private static void writeAtomicPrivateFile(File dir, String finalName, byte[] data)
            throws IOException {
        File tmp = File.createTempFile("evidence-", ".tmp", dir);
        boolean moved = false;
        try {
            try (FileOutputStream out = new FileOutputStream(tmp)) {
                out.write(data);
                out.getFD().sync();
            }
            File dest = new File(dir, finalName);
            if (Files.isSymbolicLink(dest.toPath())) {
                throw new IOException("EVIDENCE_SYMLINK_FORBIDDEN");
            }
            Files.move(tmp.toPath(), dest.toPath(), StandardCopyOption.REPLACE_EXISTING);
            moved = true;
        } finally {
            if (!moved) tmp.delete();
        }
    }
}
