package it.akai.customremote;

import it.akai.customremote.ai.OtaSessionByteTransfer;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.security.MessageDigest;
import java.util.Arrays;

public final class OtaSessionByteTransferTest {
    private static int checks;

    private static void ok(boolean value, String label) {
        if (!value) throw new AssertionError(label);
        checks++;
    }
    private static String hex(byte[] raw) throws Exception {
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(raw);
        StringBuilder builder = new StringBuilder();
        for (byte b : digest) builder.append(String.format("%02x", b & 0xff));
        return builder.toString();
    }
    private static void denied(InputStream stream, OutputStream dest,
                               long size, String hash, String label) throws Exception {
        try {
            OtaSessionByteTransfer.copyVerified(stream, dest, size, hash);
            throw new AssertionError("accepted " + label);
        } catch (IOException validFailure) {
            checks++;
        }
    }

    public static void main(String[] args) throws Exception {
        byte[] bytes = new byte[8192];
        for (int i = 0; i < bytes.length; i++) bytes[i] = (byte) (i * 37);
        String digest = hex(bytes);
        ByteArrayOutputStream copied = new ByteArrayOutputStream();
        long result = OtaSessionByteTransfer.copyVerified(
                new ByteArrayInputStream(bytes), copied, bytes.length, digest);
        ok(result == bytes.length, "exact byte count");
        ok(Arrays.equals(bytes, copied.toByteArray()), "copied bytes identical");

        byte[] corrupted = bytes.clone();
        corrupted[777] ^= 1;
        denied(new ByteArrayInputStream(corrupted), new ByteArrayOutputStream(),
                bytes.length, digest, "changed input");
        denied(new ByteArrayInputStream(bytes), new ByteArrayOutputStream(),
                bytes.length - 1, digest, "overlong stream");
        denied(new ByteArrayInputStream(Arrays.copyOf(bytes, 2048)),
                new ByteArrayOutputStream(), bytes.length, digest, "truncated");
        denied(new ByteArrayInputStream(bytes), new ByteArrayOutputStream(),
                bytes.length, "invalid", "malformed SHA");
        denied(null, new ByteArrayOutputStream(), bytes.length, digest, "null input");
        denied(new ByteArrayInputStream(bytes), null, bytes.length, digest, "null output");
        denied(new ByteArrayInputStream(bytes), new ByteArrayOutputStream(),
                1000, digest, "undersized claim");
        denied(new ByteArrayInputStream(bytes), new ByteArrayOutputStream(),
                26L * 1024L * 1024L, digest, "oversized claim");

        denied(new InputStream() {
            @Override public int read() { return 0; }
            @Override public int read(byte[] b, int off, int len) { return 0; }
        }, new ByteArrayOutputStream(), bytes.length, digest, "stalled read");

        denied(new InputStream() {
            @Override public int read() throws IOException { throw new IOException("broken"); }
            @Override public int read(byte[] b, int off, int len) throws IOException {
                throw new IOException("broken");
            }
        }, new ByteArrayOutputStream(), bytes.length, digest, "input exception");

        denied(new ByteArrayInputStream(bytes), new OutputStream() {
            @Override public void write(int value) throws IOException {
                throw new IOException("disk full");
            }
            @Override public void write(byte[] b, int off, int len) throws IOException {
                throw new IOException("disk full");
            }
        }, bytes.length, digest, "session disk failure");

        Thread.currentThread().interrupt();
        try {
            denied(new ByteArrayInputStream(bytes), new ByteArrayOutputStream(),
                    bytes.length, digest, "cancelled before copy");
            ok(Thread.currentThread().isInterrupted(), "interrupt flag preserved");
        } finally {
            Thread.interrupted();
        }
        denied(new InputStream() {
            @Override public int read() { return 0; }
            @Override public int read(byte[] b, int off, int len) {
                Thread.currentThread().interrupt();
                b[off] = 1;
                return 1;
            }
        }, new ByteArrayOutputStream(), bytes.length, digest, "cancelled during copy");
        ok(Thread.currentThread().isInterrupted(), "interrupt flag on cancel preserved");
        Thread.interrupted();

        System.out.println("OtaSessionByteTransferTest PASS " + checks +
                " exact-byte, hash and cancellation tests (no installer called)");
    }
}
