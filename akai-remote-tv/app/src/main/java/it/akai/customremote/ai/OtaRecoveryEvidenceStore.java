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
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.security.PublicKey;
import java.util.Base64;
import java.util.Locale;

/**
 * Private on-device reader/verifier for PC-off OTA recovery evidence receipts.
 *
 * Reads only from app-private filesDir/ota-evidence without network calls or PC
 * dependency at runtime, binding cryptographic receipt verification to the
 * bundled trust anchor, Android Settings.Secure.ANDROID_ID, and — when present
 * on disk — the exact SHA-256 of filesDir/ota-evidence/ota-backup.bundle.
 */
public final class OtaRecoveryEvidenceStore {
    public static final String EVIDENCE_SUBDIR = "ota-evidence";
    public static final String RECEIPT_FILENAME = "ota-recovery-evidence.receipt";
    public static final String SIGNATURE_FILENAME = "ota-recovery-evidence.receipt.sig";
    public static final String PORTABLE_BUNDLE_FILENAME = "ota-recovery-evidence.pkg";
    public static final String LOCAL_ARCHIVE_FILENAME = "ota-backup.bundle";
    public static final int MAX_PORTABLE_BUNDLE_BYTES = 8192;
    private static final int MAX_SIG_BYTES = 512;
    private static final long MAX_LOCAL_ARCHIVE_BYTES = 64L * 1024L * 1024L;
    private static final String BUNDLE_RECEIPT_BEGIN =
            "-----BEGIN JARVIS OTA EVIDENCE RECEIPT V2-----";
    private static final String BUNDLE_RECEIPT_END =
            "-----END JARVIS OTA EVIDENCE RECEIPT V2-----";
    private static final String BUNDLE_SIG_BEGIN =
            "-----BEGIN JARVIS OTA EVIDENCE SIGNATURE BASE64-----";
    private static final String BUNDLE_SIG_END =
            "-----END JARVIS OTA EVIDENCE SIGNATURE BASE64-----";

    private OtaRecoveryEvidenceStore() {}

    public static final class PortableBundle {
        public final byte[] receiptBytes;
        public final byte[] signatureBytes;

        PortableBundle(byte[] receiptBytes, byte[] signatureBytes) {
            this.receiptBytes = receiptBytes;
            this.signatureBytes = signatureBytes;
        }
    }

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

            OtaRecoveryEvidenceGate.Verdict verdict = verifyBytesWithLocalAnchor(
                    context, receiptBytes, sigBytes,
                    actualInstalledVersionCode, candidateVersionCode, nowEpochSec);
            if (!verdict.accepted) return verdict;

            // When a local encrypted backup bundle copy exists on device inside
            // ota-evidence/, verify its physical bytes match backupArchiveSha256.
            File localArchive = new File(expectedDir, LOCAL_ARCHIVE_FILENAME);
            if (Files.exists(localArchive.toPath(), LinkOption.NOFOLLOW_LINKS)) {
                String actualArchiveSha = sha256BoundedPrivateFile(
                        localArchive, expectedDir, MAX_LOCAL_ARCHIVE_BYTES);
                if (actualArchiveSha == null ||
                        !actualArchiveSha.equalsIgnoreCase(verdict.backupArchiveSha256)) {
                    return OtaRecoveryEvidenceGate.externalDeny("EVIDENCE_LOCAL_ARCHIVE_HASH_MISMATCH");
                }
            }
            return verdict;
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
        return verifyAndPersistReceipt(context, receiptBytes, signatureBytes,
                actualInstalledVersionCode, candidateVersionCode, true, nowEpochSec);
    }

    /**
     * ADB-free import helper for UI/USB/drop-folder flows before a staged
     * candidate version is known; enforces signature, device UID, installed
     * version, backup digest, and coherent rescue ceiling.
     */
    public static OtaRecoveryEvidenceGate.Verdict importVerifiedReceiptForInstalled(
            Context context, byte[] receiptBytes, byte[] signatureBytes,
            int actualInstalledVersionCode, long nowEpochSec) {
        return verifyAndPersistReceipt(context, receiptBytes, signatureBytes,
                actualInstalledVersionCode, 0, false, nowEpochSec);
    }

    public static PortableBundle parsePortableBundle(byte[] bundleBytes) {
        if (bundleBytes == null || bundleBytes.length == 0 ||
                bundleBytes.length > MAX_PORTABLE_BUNDLE_BYTES) {
            return null;
        }
        for (byte b : bundleBytes) {
            int c = b & 0xff;
            if (c != 10 && (c < 32 || c > 126)) {
                return null;
            }
        }
        String raw = new String(bundleBytes, StandardCharsets.US_ASCII);
        if (!raw.endsWith("\n")) return null;
        String[] lines = raw.split("\n", -1);
        if (lines.length < 7 || !lines[lines.length - 1].isEmpty()) {
            return null;
        }
        if (!BUNDLE_RECEIPT_BEGIN.equals(lines[0])) {
            return null;
        }
        int receiptEndIdx = -1;
        for (int i = 1; i < lines.length - 4; i++) {
            if (BUNDLE_RECEIPT_END.equals(lines[i])) {
                receiptEndIdx = i;
                break;
            }
        }
        if (receiptEndIdx <= 1 || receiptEndIdx + 4 != lines.length - 1) {
            return null;
        }
        if (!BUNDLE_SIG_BEGIN.equals(lines[receiptEndIdx + 1]) ||
                !BUNDLE_SIG_END.equals(lines[receiptEndIdx + 3])) {
            return null;
        }
        String sigB64 = lines[receiptEndIdx + 2];
        if (sigB64.isEmpty() || !sigB64.matches("[A-Za-z0-9+/=]+")) {
            return null;
        }
        StringBuilder receiptBuilder = new StringBuilder();
        for (int i = 1; i < receiptEndIdx; i++) {
            receiptBuilder.append(lines[i]).append('\n');
        }
        byte[] receiptBytes = receiptBuilder.toString().getBytes(StandardCharsets.US_ASCII);
        if (receiptBytes.length == 0 || receiptBytes.length > OtaRecoveryEvidenceGate.MAX_RECEIPT_BYTES) {
            return null;
        }
        byte[] signatureBytes;
        try {
            signatureBytes = Base64.getDecoder().decode(sigB64);
        } catch (IllegalArgumentException invalidB64) {
            return null;
        }
        if (signatureBytes.length == 0 || signatureBytes.length > MAX_SIG_BYTES) {
            return null;
        }
        return new PortableBundle(receiptBytes, signatureBytes);
    }

    public static OtaRecoveryEvidenceGate.Verdict importVerifiedPortableBundle(
            Context context, byte[] bundleBytes,
            int actualInstalledVersionCode, int candidateVersionCodeOrZero, long nowEpochSec) {
        PortableBundle bundle = parsePortableBundle(bundleBytes);
        if (bundle == null) {
            return OtaRecoveryEvidenceGate.externalDeny("EVIDENCE_BUNDLE_INVALID");
        }
        return verifyAndPersistReceipt(context, bundle.receiptBytes, bundle.signatureBytes,
                actualInstalledVersionCode, candidateVersionCodeOrZero,
                candidateVersionCodeOrZero > 0, nowEpochSec);
    }

    public static OtaRecoveryEvidenceGate.Verdict importVerifiedFromDirectory(
            Context context, File importDir,
            int actualInstalledVersionCode, int candidateVersionCodeOrZero, long nowEpochSec) {
        if (importDir == null) {
            return OtaRecoveryEvidenceGate.externalDeny("EVIDENCE_IMPORT_SOURCE_MISSING");
        }
        try {
            Path dirPath = importDir.toPath();
            if (Files.isSymbolicLink(dirPath) ||
                    !Files.isDirectory(dirPath, LinkOption.NOFOLLOW_LINKS)) {
                return OtaRecoveryEvidenceGate.externalDeny("EVIDENCE_IMPORT_SOURCE_MISSING");
            }
            File canonicalImportDir = importDir.getCanonicalFile();
            if (!canonicalImportDir.equals(importDir.getAbsoluteFile())) {
                return OtaRecoveryEvidenceGate.externalDeny("EVIDENCE_IMPORT_SOURCE_MISSING");
            }
            File pkgFile = new File(canonicalImportDir, PORTABLE_BUNDLE_FILENAME);
            if (Files.exists(pkgFile.toPath(), LinkOption.NOFOLLOW_LINKS)) {
                byte[] pkgBytes = readBoundedPrivateFile(
                        pkgFile, canonicalImportDir, MAX_PORTABLE_BUNDLE_BYTES);
                if (pkgBytes == null) {
                    return OtaRecoveryEvidenceGate.externalDeny("EVIDENCE_BUNDLE_INVALID");
                }
                return importVerifiedPortableBundle(context, pkgBytes,
                        actualInstalledVersionCode, candidateVersionCodeOrZero, nowEpochSec);
            }
            File receiptFile = new File(canonicalImportDir, RECEIPT_FILENAME);
            File sigFile = new File(canonicalImportDir, SIGNATURE_FILENAME);
            if (Files.exists(receiptFile.toPath(), LinkOption.NOFOLLOW_LINKS) &&
                    Files.exists(sigFile.toPath(), LinkOption.NOFOLLOW_LINKS)) {
                byte[] receiptBytes = readBoundedPrivateFile(
                        receiptFile, canonicalImportDir, OtaRecoveryEvidenceGate.MAX_RECEIPT_BYTES);
                byte[] sigBytes = readBoundedPrivateFile(
                        sigFile, canonicalImportDir, MAX_SIG_BYTES);
                if (receiptBytes == null || sigBytes == null) {
                    return OtaRecoveryEvidenceGate.externalDeny("EVIDENCE_RECEIPT_UNREADABLE");
                }
                return verifyAndPersistReceipt(context, receiptBytes, sigBytes,
                        actualInstalledVersionCode, candidateVersionCodeOrZero,
                        candidateVersionCodeOrZero > 0, nowEpochSec);
            }
            return OtaRecoveryEvidenceGate.externalDeny("EVIDENCE_IMPORT_SOURCE_MISSING");
        } catch (Exception unavailable) {
            return OtaRecoveryEvidenceGate.externalDeny("EVIDENCE_STORAGE_UNAVAILABLE");
        }
    }

    public static byte[] readBoundedStream(InputStream in, int maxBytes) {
        if (in == null || maxBytes <= 0) return null;
        try {
            ByteArrayOutputStream out = new ByteArrayOutputStream(Math.min(maxBytes, 4096));
            byte[] buf = new byte[1024];
            int total = 0;
            int n;
            while ((n = in.read(buf)) != -1) {
                if (n == 0) continue;
                if (total + n > maxBytes) return null;
                out.write(buf, 0, n);
                total += n;
            }
            return (total > 0) ? out.toByteArray() : null;
        } catch (IOException e) {
            return null;
        }
    }

    private static OtaRecoveryEvidenceGate.Verdict verifyAndPersistReceipt(
            Context context, byte[] receiptBytes, byte[] signatureBytes,
            int actualInstalledVersionCode, int candidateVersionCode,
            boolean enforceCandidateVersion, long nowEpochSec) {
        OtaRecoveryEvidenceGate.Verdict verdict = verifyBytesWithLocalAnchor(
                context, receiptBytes, signatureBytes, actualInstalledVersionCode,
                candidateVersionCode, enforceCandidateVersion, nowEpochSec);
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

            File localArchive = new File(dir, LOCAL_ARCHIVE_FILENAME);
            if (Files.exists(localArchive.toPath(), LinkOption.NOFOLLOW_LINKS)) {
                String actualArchiveSha = sha256BoundedPrivateFile(
                        localArchive, dir, MAX_LOCAL_ARCHIVE_BYTES);
                if (actualArchiveSha == null ||
                        !actualArchiveSha.equalsIgnoreCase(verdict.backupArchiveSha256)) {
                    return OtaRecoveryEvidenceGate.externalDeny("EVIDENCE_LOCAL_ARCHIVE_HASH_MISMATCH");
                }
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
        return verifyBytesWithLocalAnchor(context, receiptBytes, signatureBytes,
                actualInstalledVersionCode, candidateVersionCode, true, nowEpochSec);
    }

    private static OtaRecoveryEvidenceGate.Verdict verifyBytesWithLocalAnchor(
            Context context, byte[] receiptBytes, byte[] signatureBytes,
            int actualInstalledVersionCode, int candidateVersionCode,
            boolean enforceCandidateVersion, long nowEpochSec) {
        if (context == null || context.getFilesDir() == null) {
            return OtaRecoveryEvidenceGate.externalDeny("EVIDENCE_STORAGE_UNAVAILABLE");
        }
        PublicKey pinnedKey = OtaReleaseTrust.readBundledPublicKey(context);
        if (pinnedKey == null) {
            return OtaRecoveryEvidenceGate.externalDeny("EVIDENCE_TRUST_KEY_NOT_PROVISIONED");
        }
        ContentResolver resolver = context.getContentResolver();
        String deviceUid = Settings.Secure.getString(resolver, Settings.Secure.ANDROID_ID);
        return enforceCandidateVersion
                ? OtaRecoveryEvidenceGate.verify(receiptBytes, signatureBytes, pinnedKey,
                        deviceUid, actualInstalledVersionCode, candidateVersionCode, nowEpochSec)
                : OtaRecoveryEvidenceGate.verifyForInstalled(receiptBytes, signatureBytes,
                        pinnedKey, deviceUid, actualInstalledVersionCode, nowEpochSec);
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

    private static String sha256BoundedPrivateFile(File target, File canonicalDir, long maxBytes) {
        try {
            Path p = target.toPath();
            if (Files.isSymbolicLink(p) ||
                    !Files.isRegularFile(p, LinkOption.NOFOLLOW_LINKS) ||
                    !canonicalDir.equals(target.getCanonicalFile().getParentFile())) {
                return null;
            }
            long len = target.length();
            if (len <= 0L || len > maxBytes) return null;
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] buf = new byte[16 * 1024];
            long total = 0L;
            try (FileInputStream in = new FileInputStream(target)) {
                int n;
                while ((n = in.read(buf)) != -1) {
                    if (n == 0) continue;
                    total += n;
                    if (total > maxBytes) return null;
                    md.update(buf, 0, n);
                }
            }
            if (total != len) return null;
            byte[] digest = md.digest();
            StringBuilder hex = new StringBuilder(digest.length * 2);
            for (byte b : digest) {
                hex.append(String.format(Locale.ROOT, "%02x", b & 0xff));
            }
            return hex.toString();
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
