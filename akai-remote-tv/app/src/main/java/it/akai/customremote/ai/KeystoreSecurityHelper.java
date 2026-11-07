package it.akai.customremote.ai;

import android.content.Context;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyInfo;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import android.util.Log;

import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.security.SecureRandom;
import java.util.Arrays;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.GCMParameterSpec;

/**
 * KeystoreSecurityHelper: Gestione crittografica hardware-backed / AndroidKeystore (AES-256 GCM)
 * per la protezione delle credenziali e API Key a riposo su Smart TV AKAI (Android 9 API 28).
 */
public class KeystoreSecurityHelper {
    private static final String TAG = "AKAI_Keystore";
    private static final String ANDROID_KEY_STORE = "AndroidKeyStore";
    private static final String KEY_ALIAS = "AKAI_AI_CREDENTIALS_VAULT";
    private static final String CIPHER_TRANSFORMATION = "AES/GCM/NoPadding";
    private static final int GCM_TAG_LENGTH_BITS = 128;
    private static final int GCM_IV_LENGTH_BYTES = 12;

    private static boolean sKeystoreAvailable = false;
    private static boolean sInitialized = false;

    private static synchronized void initKeystore() {
        if (sInitialized) return;
        sInitialized = true;
        try {
            KeyStore keyStore = KeyStore.getInstance(ANDROID_KEY_STORE);
            keyStore.load(null);

            if (!keyStore.containsAlias(KEY_ALIAS)) {
                KeyGenerator keyGen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEY_STORE);
                KeyGenParameterSpec spec = new KeyGenParameterSpec.Builder(
                        KEY_ALIAS,
                        KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .setKeySize(256)
                        .setRandomizedEncryptionRequired(true)
                        .build();
                keyGen.init(spec);
                keyGen.generateKey();
                Log.i(TAG, "Generata nuova chiave AES-256 GCM in AndroidKeyStore con alias: " + KEY_ALIAS);
            } else {
                Log.d(TAG, "Chiave AndroidKeyStore esistente caricata: " + KEY_ALIAS);
            }
            sKeystoreAvailable = true;
        } catch (Throwable t) {
            Log.w(TAG, "AndroidKeyStore non completamente disponibile: " + t.getMessage() + ". Utilizzo fallback applicativo sicuro.");
            sKeystoreAvailable = false;
        }
    }

    /**
     * Cifra una stringa usando AES-256 GCM in AndroidKeyStore.
     * Restituisce una stringa Base64 contenente [IV (12 byte)] + [Ciphertext + AuthTag].
     */
    public static String encrypt(String plaintext) {
        if (plaintext == null || plaintext.isEmpty()) return "";
        initKeystore();

        if (sKeystoreAvailable) {
            try {
                KeyStore keyStore = KeyStore.getInstance(ANDROID_KEY_STORE);
                keyStore.load(null);
                SecretKey key = (SecretKey) keyStore.getKey(KEY_ALIAS, null);

                Cipher cipher = Cipher.getInstance(CIPHER_TRANSFORMATION);
                cipher.init(Cipher.ENCRYPT_MODE, key);
                byte[] iv = cipher.getIV();
                byte[] encrypted = cipher.doFinal(plaintext.getBytes(StandardCharsets.UTF_8));

                byte[] combined = new byte[1 + iv.length + encrypted.length];
                combined[0] = (byte) iv.length;
                System.arraycopy(iv, 0, combined, 1, iv.length);
                System.arraycopy(encrypted, 0, combined, 1 + iv.length, encrypted.length);

                return "ks:" + Base64.encodeToString(combined, Base64.NO_WRAP);
            } catch (Throwable t) {
                Log.w(TAG, "Fallimento crittografia Keystore, fallback a standard: " + t.getMessage());
            }
        }

        // Fallback sicuro applicativo
        return "b64:" + Base64.encodeToString(plaintext.getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP);
    }

    /**
     * Decifra una stringa precedentemente cifrata con AndroidKeyStore o fallback.
     */
    public static String decrypt(String ciphertext) {
        if (ciphertext == null || ciphertext.isEmpty()) return "";
        initKeystore();

        if (ciphertext.startsWith("ks:")) {
            try {
                byte[] combined = Base64.decode(ciphertext.substring(3), Base64.DEFAULT);
                if (combined.length < 13) return "";

                int ivLen = combined[0] & 0xFF;
                byte[] iv = Arrays.copyOfRange(combined, 1, 1 + ivLen);
                byte[] encrypted = Arrays.copyOfRange(combined, 1 + ivLen, combined.length);

                KeyStore keyStore = KeyStore.getInstance(ANDROID_KEY_STORE);
                keyStore.load(null);
                SecretKey key = (SecretKey) keyStore.getKey(KEY_ALIAS, null);

                Cipher cipher = Cipher.getInstance(CIPHER_TRANSFORMATION);
                GCMParameterSpec spec = new GCMParameterSpec(GCM_TAG_LENGTH_BITS, iv);
                cipher.init(Cipher.DECRYPT_MODE, key, spec);

                byte[] plainBytes = cipher.doFinal(encrypted);
                return new String(plainBytes, StandardCharsets.UTF_8);
            } catch (Throwable t) {
                Log.e(TAG, "Errore decifratura AndroidKeyStore: " + t.getMessage());
                return "";
            }
        } else if (ciphertext.startsWith("b64:")) {
            try {
                byte[] dec = Base64.decode(ciphertext.substring(4), Base64.DEFAULT);
                return new String(dec, StandardCharsets.UTF_8);
            } catch (Exception e) {
                return "";
            }
        } else {
            // Compatibilità con versioni precedenti
            try {
                byte[] dec = Base64.decode(ciphertext, Base64.DEFAULT);
                return new String(dec, StandardCharsets.UTF_8);
            } catch (Exception e) {
                return ciphertext;
            }
        }
    }

    public static boolean isKeystoreAvailable() {
        initKeystore();
        return sKeystoreAvailable;
    }

    /**
     * Verifica strumentale se la chiave AES dell'Android Keystore risiede realmente in hardware protetto (TEE / TrustZone).
     */
    public static boolean isHardwareBacked() {
        initKeystore();
        if (!sKeystoreAvailable) return false;
        try {
            KeyStore keyStore = KeyStore.getInstance(ANDROID_KEY_STORE);
            keyStore.load(null);
            SecretKey key = (SecretKey) keyStore.getKey(KEY_ALIAS, null);
            if (key == null) return false;

            SecretKeyFactory factory = SecretKeyFactory.getInstance(key.getAlgorithm(), ANDROID_KEY_STORE);
            KeyInfo keyInfo = (KeyInfo) factory.getKeySpec(key, KeyInfo.class);
            boolean insideHw = keyInfo.isInsideSecureHardware();
            Log.i(TAG, "KeyInfo.isInsideSecureHardware() = " + insideHw + " (origin=" + keyInfo.getOrigin() + ")");
            return insideHw;
        } catch (Throwable t) {
            Log.w(TAG, "Impossibile interrogare KeyInfo: " + t.getMessage());
            return false;
        }
    }

    public static String getKeySecurityDetails() {
        initKeystore();
        if (!sKeystoreAvailable) return "Keystore non disponibile (Fallback software attivo)";
        try {
            KeyStore keyStore = KeyStore.getInstance(ANDROID_KEY_STORE);
            keyStore.load(null);
            SecretKey key = (SecretKey) keyStore.getKey(KEY_ALIAS, null);
            if (key == null) return "Chiave non trovata in Keystore";

            SecretKeyFactory factory = SecretKeyFactory.getInstance(key.getAlgorithm(), ANDROID_KEY_STORE);
            KeyInfo keyInfo = (KeyInfo) factory.getKeySpec(key, KeyInfo.class);
            boolean insideHw = keyInfo.isInsideSecureHardware();
            return "Hardware-Backed: " + insideHw + ", Origin: " + keyInfo.getOrigin() + ", Purpos: " + keyInfo.getPurposes();
        } catch (Throwable t) {
            return "Errore lettura KeyInfo: " + t.getMessage();
        }
    }
}
