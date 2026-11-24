package it.akai.customremote.ai;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.security.MessageDigest;

/**
 * Copies verified APK bytes into a PackageInstaller session stream without
 * trusting a stale file digest. No Android calls: testable independently.
 *
 * Leaves both streams open for the caller to fsync and close. The Android
 * caller MUST rehash via PackageInstaller.Session.openRead("base.apk")
 * before commit; this copy check alone cannot authorize installation.
 */
public final class OtaSessionByteTransfer {
    private OtaSessionByteTransfer() {}

    public static long copyVerified(InputStream input, OutputStream sessionOutput,
                                    long expectedSize, String expectedSha256)
            throws IOException {
        if (input == null || sessionOutput == null || expectedSize < 1024 ||
                expectedSize > OtaCandidateGate.MAX_APK_BYTES ||
                expectedSha256 == null || !expectedSha256.matches("[0-9a-fA-F]{64}"))
            throw new IOException("OTA_SESSION_INVALID_INPUT");
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            long count = 0;
            int zeroReads = 0;
            byte[] buffer = new byte[16 * 1024];
            while (true) {
                if (Thread.currentThread().isInterrupted())
                    throw new IOException("OTA_SESSION_CANCELLED");
                int n = input.read(buffer);
                if (Thread.currentThread().isInterrupted())
                    throw new IOException("OTA_SESSION_CANCELLED");
                if (n < 0) break;
                if (n == 0) {
                    if (++zeroReads >= 3) throw new IOException("OTA_SESSION_EMPTY_READS");
                    continue;
                }
                zeroReads = 0;
                if (n > expectedSize - count)
                    throw new IOException("OTA_SESSION_SIZE_EXCEEDED");
                sessionOutput.write(buffer, 0, n);
                digest.update(buffer, 0, n);
                count += n;
            }
            if (count != expectedSize)
                throw new IOException("OTA_SESSION_TRUNCATED");
            if (!OtaCandidateGate.digestMatches(digest.digest(), expectedSha256))
                throw new IOException("OTA_SESSION_HASH_MISMATCH");
            if (Thread.currentThread().isInterrupted())
                throw new IOException("OTA_SESSION_CANCELLED");
            sessionOutput.flush();
            return count;
        } catch (java.security.NoSuchAlgorithmException impossibleOnAndroid) {
            throw new IOException("OTA_SESSION_SHA256_UNAVAILABLE", impossibleOnAndroid);
        }
    }
}
