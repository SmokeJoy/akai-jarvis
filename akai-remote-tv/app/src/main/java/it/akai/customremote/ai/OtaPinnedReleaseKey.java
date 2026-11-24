package it.akai.customremote.ai;

import java.security.KeyFactory;
import java.security.PublicKey;
import java.security.interfaces.RSAPublicKey;
import java.security.spec.X509EncodedKeySpec;
import java.util.Arrays;

/**
 * Decode ONLY a locally bundled DER X.509 SubjectPublicKeyInfo OTA release key.
 * Never fetch this key from the OTA server or accept it from the signed manifest.
 * The APK signing certificate and OTA release-manifest key are distinct identities.
 */
public final class OtaPinnedReleaseKey {
    private OtaPinnedReleaseKey() {}

    public static PublicKey decodeBundledSpki(byte[] der) {
        if (der == null || der.length < 200 || der.length > 1024)
            return null;
        try {
            PublicKey parsed = KeyFactory.getInstance("RSA")
                    .generatePublic(new X509EncodedKeySpec(der));
            if (!(parsed instanceof RSAPublicKey)) return null;
            RSAPublicKey rsa = (RSAPublicKey) parsed;
            int bits = rsa.getModulus().bitLength();
            if (bits < 2048 || bits > 4096) return null;
            // Avoid unusual exponents and noncanonical/trailing DER.
            if (!java.math.BigInteger.valueOf(65537L).equals(rsa.getPublicExponent()) ||
                    !Arrays.equals(der, rsa.getEncoded()))
                return null;
            return rsa;
        } catch (RuntimeException invalid) {
            return null;
        } catch (java.security.GeneralSecurityException invalid) {
            return null;
        }
    }
}
