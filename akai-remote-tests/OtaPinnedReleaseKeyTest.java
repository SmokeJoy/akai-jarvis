package it.akai.customremote;

import it.akai.customremote.ai.OtaPinnedReleaseKey;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.PublicKey;
import java.security.interfaces.RSAPublicKey;
import java.util.Arrays;

public final class OtaPinnedReleaseKeyTest {
    private static int checks;

    private static void expect(boolean accepted, byte[] bytes, String label) {
        PublicKey key = OtaPinnedReleaseKey.decodeBundledSpki(bytes);
        if ((key != null) != accepted) throw new AssertionError(label);
        checks++;
    }

    public static void main(String[] args) throws Exception {
        KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
        generator.initialize(2048);
        KeyPair valid = generator.generateKeyPair();
        byte[] encoded = valid.getPublic().getEncoded();

        expect(true, encoded, "valid 2048 RSA SPKI");
        PublicKey decoded = OtaPinnedReleaseKey.decodeBundledSpki(encoded);
        if (!(decoded instanceof RSAPublicKey) ||
                !decoded.equals(valid.getPublic()))
            throw new AssertionError("decoded public key identity mismatch");
        checks++;
        expect(false, null, "absent key");
        expect(false, new byte[0], "empty key");
        expect(false, new byte[1025], "oversized key");

        KeyPairGenerator weak = KeyPairGenerator.getInstance("RSA");
        weak.initialize(1024);
        expect(false, weak.generateKeyPair().getPublic().getEncoded(), "weak 1024-bit key");

        byte[] damaged = encoded.clone();
        damaged[20] ^= 0x33;
        expect(false, damaged, "corrupt DER");
        byte[] trailing = Arrays.copyOf(encoded, encoded.length + 1);
        trailing[trailing.length - 1] = 1;
        expect(false, trailing, "trailing DER garbage");
        expect(false, Arrays.copyOf(encoded, encoded.length - 5), "truncated key");

        System.out.println("OtaPinnedReleaseKeyTest PASS: " + checks +
                " checks (test key only; production OTA key not provisioned)");
    }
}
