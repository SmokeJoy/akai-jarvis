package it.akai.customremote.ai;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Arrays;

/**
 * Verified file replacement for SQLite snapshots. Never writes directly into
 * the target: first writes a unique SAME-FILESYSTEM temporary file, syncs it,
 * verifies exact length+SHA-256, then requires an atomic rename.
 *
 * Atomic file copy is NOT a complete SQLite rollback, WAL quiescence or TLS
 * backup. The application caller must independently handle those gates and
 * retain a working pre-restoration backup before replacing a live database.
 */
public final class VerifiedAtomicFileCopy {
    private VerifiedAtomicFileCopy() {}

    public static void copy(File source, File target) throws IOException {
        if (source == null || target == null) throw new IOException("COPY_MISSING_PATH");
        File src = source.getCanonicalFile();
        File dst = target.getCanonicalFile();
        if (src.equals(dst)) throw new IOException("COPY_SOURCE_EQUALS_TARGET");
        if (!src.isFile() || src.length() == 0) throw new IOException("COPY_SOURCE_INVALID");
        File parent = dst.getParentFile();
        if (parent == null || !parent.isDirectory())
            throw new IOException("COPY_TARGET_DIRECTORY_INVALID");

        File staged = File.createTempFile(".jarvis-verified-copy-", ".part", parent);
        boolean success = false;
        try {
            MessageDigest sourceHash = MessageDigest.getInstance("SHA-256");
            long size = 0;
            try (FileInputStream in = new FileInputStream(src);
                 FileOutputStream out = new FileOutputStream(staged)) {
                byte[] buf = new byte[16 * 1024];
                int n;
                while ((n = in.read(buf)) != -1) {
                    if (Thread.currentThread().isInterrupted())
                        throw new IOException("COPY_INTERRUPTED");
                    if (n == 0) continue;
                    sourceHash.update(buf, 0, n);
                    out.write(buf, 0, n);
                    size += n;
                }
                out.getFD().sync();
            }
            if (size == 0 || staged.length() != size)
                throw new IOException("COPY_LENGTH_NOT_VERIFIED");

            MessageDigest copiedHash = MessageDigest.getInstance("SHA-256");
            long readbackSize = 0;
            try (FileInputStream readback = new FileInputStream(staged)) {
                byte[] buf = new byte[16 * 1024];
                int n;
                while ((n = readback.read(buf)) != -1) {
                    if (Thread.currentThread().isInterrupted())
                        throw new IOException("COPY_INTERRUPTED");
                    if (n == 0) continue;
                    copiedHash.update(buf, 0, n);
                    readbackSize += n;
                }
            }
            if (readbackSize != size ||
                    !Arrays.equals(sourceHash.digest(), copiedHash.digest()))
                throw new IOException("COPY_HASH_NOT_VERIFIED");

            // No non-atomic fallback. If this device's filesystem cannot
            // atomically replace the destination, preserve the old file and
            // report failure rather than risk a partially written database.
            Files.move(staged.toPath(), dst.toPath(),
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING);
            success = true;
        } catch (NoSuchAlgorithmException unexpected) {
            throw new IOException("COPY_SHA256_UNAVAILABLE", unexpected);
        } finally {
            if (!success) staged.delete();
        }
    }
}
