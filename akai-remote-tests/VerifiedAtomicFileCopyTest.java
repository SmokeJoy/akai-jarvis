package it.akai.customremote;

import it.akai.customremote.ai.VerifiedAtomicFileCopy;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.Arrays;

public final class VerifiedAtomicFileCopyTest {
    private static int checks = 0;

    private static void check(boolean b, String label) {
        if (!b) throw new AssertionError(label);
        checks++;
    }

    private static void expectFailure(File src, File dst, String label) throws Exception {
        try {
            VerifiedAtomicFileCopy.copy(src, dst);
            throw new AssertionError("accepted unsafe copy: " + label);
        } catch (IOException expected) {
            checks++;
        }
    }

    private static byte[] content(int length, int offset) {
        byte[] result = new byte[length];
        for (int i = 0; i < length; i++) result[i] = (byte) (i * 13 + offset);
        return result;
    }

    public static void main(String[] args) throws Exception {
        File dir = Files.createTempDirectory("jarvis-verified-dbcopy-").toFile();
        try {
            File from = new File(dir, "source.db");
            File target = new File(dir, "restored.db");
            byte[] first = content(200_000, 7);
            byte[] prior = content(2048, 11);
            Files.write(from.toPath(), first);
            Files.write(target.toPath(), prior);
            VerifiedAtomicFileCopy.copy(from, target);
            check(Arrays.equals(first, Files.readAllBytes(target.toPath())),
                    "larger copy all bytes, old target atomically replaced");

            byte[] second = content(4097, 13);
            Files.write(from.toPath(), second);
            VerifiedAtomicFileCopy.copy(from, target);
            check(Arrays.equals(second, Files.readAllBytes(target.toPath())),
                    "smaller copy complete, no stale trailing bytes");

            expectFailure(from, from, "same source/target");
            check(Arrays.equals(second, Files.readAllBytes(from.toPath())),
                    "same-path error leaves original source intact");

            File nonexistent = new File(dir, "missing.db");
            expectFailure(nonexistent, target, "nonexistent source");
            check(Arrays.equals(second, Files.readAllBytes(target.toPath())),
                    "missing source cannot damage previous target");

            File empty = new File(dir, "empty.db");
            Files.write(empty.toPath(), new byte[0]);
            expectFailure(empty, target, "empty SQLite snapshot");
            check(Arrays.equals(second, Files.readAllBytes(target.toPath())),
                    "empty source cannot replace verified copy");

            File directoryTarget = new File(dir, "does-not-exist");
            expectFailure(from, new File(directoryTarget, "target.db"), "nonexistent parent");
            check(Arrays.equals(second, Files.readAllBytes(target.toPath())),
                    "missing target dir cannot alter existing copies");

            Thread.currentThread().interrupt();
            try {
                expectFailure(from, target, "thread interrupted before copying");
                check(Thread.currentThread().isInterrupted(), "interrupt flag preserved");
            } finally {
                Thread.interrupted();
            }
            check(Arrays.equals(second, Files.readAllBytes(target.toPath())),
                    "cancelled copy did not truncate target");
            File[] left = dir.listFiles((d, name) -> name.endsWith(".part"));
            check(left != null && left.length == 0,
                    "temporary partial copies cleaned after failure");

            System.out.println("VerifiedAtomicFileCopyTest PASS: " + checks
                    + " filesystem assertions; no live Android SQLite restore tested");
        } finally {
            File[] all = dir.listFiles();
            if (all != null) for (File entry : all) entry.delete();
            dir.delete();
        }
    }
}
