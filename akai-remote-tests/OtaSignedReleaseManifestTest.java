package it.akai.customremote;

import it.akai.customremote.ai.OtaCandidateGate;
import it.akai.customremote.ai.OtaSignedReleaseManifest;

import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.Signature;
import java.util.Collections;
import java.util.Set;

public final class OtaSignedReleaseManifestTest {
    private static final String PINNED = OtaCandidateGate.EXPECTED_SIGNER_SHA256;
    private static final String HASH =
            "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899";
    private static final Set<String> TRUSTED = Collections.singleton("updates.example.com");
    private static int checks = 0;

    private static byte[] sign(byte[] bytes, KeyPair key) throws Exception {
        Signature rsa = Signature.getInstance("SHA256withRSA");
        rsa.initSign(key.getPrivate());
        rsa.update(bytes);
        return rsa.sign();
    }

    private static String goodManifest() {
        return "format=jarvis-ota-v1\n"
                + "package=it.akai.customremote\n"
                + "versionCode=5\n"
                + "signerSha256=" + PINNED + "\n"
                + "apkSha256=" + HASH + "\n"
                + "url=https://updates.example.com/releases/jarvis-v5.apk\n"
                + "abi=armeabi-v7a\n"
                + "minSdk=21\n"
                + "sizeBytes=2048\n"
                + "channel=stable\n";
    }

    private static void expect(boolean accepted, String label,
                               byte[] bytes, byte[] detached, KeyPair key,
                               int installedVersion, String installedSigner,
                               Set<String> trustedHosts) {
        OtaSignedReleaseManifest.Result value = OtaSignedReleaseManifest.verify(
                bytes, detached, key.getPublic(), installedVersion, installedSigner, trustedHosts);
        if (value.verified() != accepted || value.verified() != (value.candidate != null))
            throw new AssertionError(label + ": " + value.code);
        if (accepted && !"SIGNED_MANIFEST_VERIFIED_NOT_INSTALLED".equals(value.code))
            throw new AssertionError(label + ": wrong result code " + value.code);
        checks++;
    }

    private static void rejectedEvenWhenSigned(KeyPair key, String input, String label)
            throws Exception {
        byte[] bytes = input.getBytes(StandardCharsets.UTF_8);
        expect(false, label, bytes, sign(bytes, key), key, 4, PINNED, TRUSTED);
    }

    public static void main(String[] args) throws Exception {
        KeyPairGenerator kpg = KeyPairGenerator.getInstance("RSA");
        kpg.initialize(2048);
        KeyPair key = kpg.generateKeyPair();
        KeyPair wrongKey = kpg.generateKeyPair();
        byte[] good = goodManifest().getBytes(StandardCharsets.US_ASCII);
        byte[] signature = sign(good, key);

        expect(true, "valid manifest", good, signature, key, 4, PINNED, TRUSTED);
        expect(false, "no trust key", good, signature, wrongKey, 4, PINNED, TRUSTED);
        expect(false, "old version installed", good, signature, key, 5, PINNED, TRUSTED);
        expect(false, "installed signer mismatch", good, signature, key, 4, HASH, TRUSTED);
        expect(false, "empty host list", good, signature, key, 4, PINNED,
                Collections.<String>emptySet());
        byte[] modified = good.clone();
        modified[good.length - 2] ^= 1;
        expect(false, "modified bytes after signing", modified, signature, key, 4, PINNED, TRUSTED);
        byte[] damagedSignature = signature.clone();
        damagedSignature[0] ^= 1;
        expect(false, "corrupt signature", good, damagedSignature, key, 4, PINNED, TRUSTED);
        expect(false, "no signature", good, null, key, 4, PINNED, TRUSTED);
        rejectedEvenWhenSigned(key, goodManifest().replace("format=jarvis-ota-v1",
                "format=jarvis-ota-v2"), "unknown protocol version");
        rejectedEvenWhenSigned(key, goodManifest().replace("versionCode=5\n",
                "versionCode=05\n"), "leading zero");
        rejectedEvenWhenSigned(key, goodManifest().replace("versionCode=5\n",
                "versionCode=2147483648\n"), "integer overflow");
        rejectedEvenWhenSigned(key, goodManifest().replace("sizeBytes=2048\n",
                "sizeBytes=0\n"), "zero APK size");
        rejectedEvenWhenSigned(key, goodManifest().replace("minSdk=21\n",
                "minSdk=29\n"), "incompatible SDK");
        rejectedEvenWhenSigned(key, goodManifest().replace(
                "url=https://updates.example.com/releases/jarvis-v5.apk",
                "url=https://updates.example.com.evil.test/jarvis-v5.apk"), "host spoofing");
        rejectedEvenWhenSigned(key, goodManifest().replace(
                "package=it.akai.customremote", "package=org.evil.app"), "wrong package");
        rejectedEvenWhenSigned(key, goodManifest().replace("channel=stable\n",
                "channel=preview\n"), "preview channel");
        rejectedEvenWhenSigned(key, goodManifest().replace(
                "versionCode=5\n", "versionCode=5\nversionCode=5\n"), "duplicated field");
        rejectedEvenWhenSigned(key, goodManifest().replace(
                "versionCode=5\n", "sizeBytes=2048\n"), "wrong ordered field");
        rejectedEvenWhenSigned(key, goodManifest().substring(0,
                goodManifest().length() - 1), "missing final newline");
        rejectedEvenWhenSigned(key, goodManifest().replace("\n", "\r\n"), "CRLF injection");
        rejectedEvenWhenSigned(key, goodManifest().replace("format=jarvis-ota-v1",
                "format=jarvis-ota-v1\u0000"), "NUL injection");
        rejectedEvenWhenSigned(key, goodManifest().replace("channel=stable",
                "channel=stablé"), "non-ASCII bytes");

        System.out.println("OtaSignedReleaseManifestTest PASS: " + checks
                + " signed protocol tests (no real HTTP/download/install)");
    }
}
