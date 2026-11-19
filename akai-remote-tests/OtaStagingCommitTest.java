package it.akai.customremote;

import it.akai.customremote.ai.OtaStagingCommit;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.security.MessageDigest;

public final class OtaStagingCommitTest {
    private static int checks;

    private static void check(boolean condition, String label) {
        if (!condition) throw new AssertionError(label);
        checks++;
    }

    private static String hash(byte[] data) throws Exception {
        byte[] sum = MessageDigest.getInstance("SHA-256").digest(data);
        StringBuilder out = new StringBuilder();
        for (byte b : sum) out.append(String.format("%02x", b & 0xff));
        return out.toString();
    }

    private static byte[] bytes(int seed) {
        byte[] result = new byte[2048];
        for (int i = 0; i < result.length; i++) result[i] = (byte) (i + seed);
        return result;
    }

    private static File part(File dir, byte[] data) throws IOException {
        File file = File.createTempFile("jarvis-", ".part", dir);
        Files.write(file.toPath(), data);
        return file;
    }

    private static void mustReject(File part, File dir, int version, long size,
                                   String sha, String label) throws Exception {
        try {
            OtaStagingCommit.finish(part, dir, version, size, sha);
            throw new AssertionError("accepted " + label);
        } catch (IOException expected) {
            checks++;
        }
    }

    public static void main(String[] args) throws Exception {
        File root = Files.createTempDirectory("jarvis-staging-test-").toFile();
        try {
            byte[] oldBytes = bytes(1), newBytes = bytes(2);
            String oldHash = hash(oldBytes), newHash = hash(newBytes);

            File oldPart = part(root, oldBytes);
            File oldCandidate = OtaStagingCommit.finish(
                    oldPart, root, 4, oldBytes.length, oldHash);
            check(oldCandidate.isFile(), "older APK must be retained");
            check(!oldPart.exists(), "old partial was moved");
            check(oldCandidate.getName().contains(oldHash), "content-addressed filename");

            // A corrupt replacement must not remove or modify the older
            // valid candidate, including a same-version staging retry.
            File wrongPart = part(root, newBytes);
            mustReject(wrongPart, root, 4, newBytes.length, oldHash,
                    "same-version mismatched download");
            check(oldCandidate.isFile(), "old candidate preserved after bad download");
            check(java.util.Arrays.equals(Files.readAllBytes(oldCandidate.toPath()), oldBytes),
                    "old candidate bytes preserved");
            check(wrongPart.exists(), "failed move retains source until caller cleanup");
            wrongPart.delete();

            // A different valid v5 is added while v4 is preserved.
            File newCandidate = OtaStagingCommit.finish(
                    part(root, newBytes), root, 5, newBytes.length, newHash);
            check(oldCandidate.isFile() && newCandidate.isFile(),
                    "previous and new valid candidates coexist");
            check(!oldCandidate.equals(newCandidate), "versions are immutable filenames");

            // Idempotent duplicate uses existing validated file rather
            // than deleting it before rename; it cleans only the new partial.
            File repeatPart = part(root, newBytes);
            File reused = OtaStagingCommit.finish(repeatPart, root, 5,
                    newBytes.length, newHash);
            check(reused.equals(newCandidate), "identical candidate reused");
            check(!repeatPart.exists(), "duplicate partial cleaned after successful reuse");
            check(java.util.Arrays.equals(Files.readAllBytes(newCandidate.toPath()), newBytes),
                    "reused candidate bytes unmodified");

            // If the destination is corrupt, do not overwrite it.
            Files.write(newCandidate.toPath(), oldBytes);
            File conflict = part(root, newBytes);
            mustReject(conflict, root, 5, newBytes.length, newHash,
                    "existing target corrupted");
            check(java.util.Arrays.equals(Files.readAllBytes(newCandidate.toPath()), oldBytes),
                    "corrupt existing file was not overwritten");
            check(oldCandidate.isFile(), "older candidate unaffected by conflict");
            conflict.delete();

            mustReject(part(root, newBytes), root, 0, newBytes.length, newHash,
                    "invalid version code");
            mustReject(part(root, newBytes), root, 6, newBytes.length - 1, newHash,
                    "wrong declared size");
            mustReject(part(root, newBytes), root, 6, newBytes.length, "invalid",
                    "invalid hash");
            File outside = part(Files.createTempDirectory("jarvis-outside-").toFile(), newBytes);
            mustReject(outside, root, 6, newBytes.length, newHash,
                    "outside source path denied");

            System.out.println("OtaStagingCommitTest PASS: " + checks
                    + " checks (real filesystem negative cases, no networking/install)");
        } finally {
            File[] children = root.listFiles();
            if (children != null) for (File child : children) child.delete();
            root.delete();
        }
    }
}
