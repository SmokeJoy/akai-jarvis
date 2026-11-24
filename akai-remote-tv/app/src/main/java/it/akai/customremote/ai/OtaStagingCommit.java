package it.akai.customremote.ai;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.LinkOption;

/**
 * Never-destructive finalization of a verified OTA APK on Android API 26+.
 *
 * Every candidate receives an immutable version-and-full-digest filename.
 * In particular there is NO delete-previous-APK and NO REPLACE_EXISTING move.
 * Older versions and previously verified candidates remain available even if
 * writing, verification or moving a new candidate fails.
 *
 * Both source and destination must be ordinary files inside the same private
 * staging directory. Invoked only after the complete download has been synced.
 */
public final class OtaStagingCommit {
    private OtaStagingCommit() {}

    public static File finish(File partial, File stagingDir, int versionCode,
                              long declaredSize, String sha256) throws IOException {
        if (partial == null || stagingDir == null || versionCode < 1 ||
                declaredSize < 1024 || declaredSize > OtaCandidateGate.MAX_APK_BYTES ||
                sha256 == null || !sha256.matches("[a-fA-F0-9]{64}"))
            throw new IOException("INVALID_STAGING_INPUT");

        File dir = stagingDir.getCanonicalFile();
        if (!Files.isDirectory(dir.toPath(), LinkOption.NOFOLLOW_LINKS) ||
                Files.isSymbolicLink(stagingDir.toPath()))
            throw new IOException("STAGING_DIRECTORY_INVALID");

        File source = partial.getCanonicalFile();
        if (!dir.equals(source.getParentFile()) ||
                !source.getName().startsWith("jarvis-") ||
                !source.getName().endsWith(".part") ||
                !Files.isRegularFile(partial.toPath(), LinkOption.NOFOLLOW_LINKS) ||
                Files.isSymbolicLink(partial.toPath()))
            throw new IOException("STAGING_SOURCE_INVALID");

        String canonicalHash = sha256.toLowerCase(java.util.Locale.ROOT);
        File target = new File(dir, "jarvis-" + versionCode + "-" + canonicalHash + ".apk");
        if (!dir.equals(target.getCanonicalFile().getParentFile()) ||
                Files.isSymbolicLink(target.toPath()))
            throw new IOException("STAGING_TARGET_INVALID");

        // Do NOT trust an earlier hash check; bytes may have changed in between.
        if (!verify(source, declaredSize, canonicalHash))
            throw new IOException("STAGING_SOURCE_HASH_MISMATCH");

        if (Files.exists(target.toPath(), LinkOption.NOFOLLOW_LINKS)) {
            // Reusing the identical immutable file is safe. A file with the
            // same filename but wrong content is never replaced or removed.
            if (!Files.isRegularFile(target.toPath(), LinkOption.NOFOLLOW_LINKS) ||
                    !verify(target, declaredSize, canonicalHash))
                throw new IOException("STAGING_EXISTING_TARGET_INVALID");
            if (!partial.delete()) throw new IOException("STAGING_PARTIAL_CLEANUP_FAILED");
            return target;
        }

        // Android API 26+ Files.move without REPLACE_EXISTING refuses an
        // existing target. Never use ATOMIC_MOVE here: Android explicitly
        // allows platform-dependent replacement of existing destinations.
        Files.move(source.toPath(), target.toPath());
        if (!verify(target, declaredSize, canonicalHash))
            throw new IOException("STAGING_TARGET_CHANGED_AFTER_MOVE");
        return target;
    }

    private static boolean verify(File file, long expectedSize, String expectedSha)
            throws IOException {
        if (!Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS) ||
                file.length() != expectedSize) return false;
        try (FileInputStream in = new FileInputStream(file)) {
            return OtaCandidateGate.verifyApkStream(in, expectedSize, expectedSha);
        }
    }
}
