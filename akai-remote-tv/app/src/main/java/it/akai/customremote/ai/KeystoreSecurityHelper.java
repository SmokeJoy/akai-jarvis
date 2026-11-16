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
    private static volatile Boolean sHardwareBackedDetected = null;
    private static volatile SecretKey sTestFallbackSecretKey = null;
    private static volatile boolean sForceKeystoreUnavailableForTest = false;

    /**
     * Solo per unit test JVM host dove AndroidKeyStore non esiste: inietta una SecretKey AES-256 in memoria
     * per esercitare la vera cifratura AES/GCM/NoPadding, oppure lascia null per testare il blocco P0 fail-closed.
     */
    public static synchronized void setTestFallbackSecretKey(SecretKey key) {
        sTestFallbackSecretKey = key;
        sHardwareBackedDetected = null;
        sInitialized = false;
    }

    public static synchronized void setForceKeystoreUnavailableForTest(boolean force) {
        sForceKeystoreUnavailableForTest = force;
        if (force) {
            sKeystoreAvailable = false;
            sHardwareBackedDetected = false;
        }
        sInitialized = false;
    }

    private static synchronized void initKeystore() {
        if (sInitialized) return;
        sInitialized = true;
        sHardwareBackedDetected = null;
        if (sForceKeystoreUnavailableForTest) {
            sKeystoreAvailable = false;
            sHardwareBackedDetected = false;
            return;
        }
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
            if (sTestFallbackSecretKey != null) {
                sKeystoreAvailable = true;
                sHardwareBackedDetected = false;
                Log.d(TAG, "AndroidKeyStore assente su host test: attiva chiave AES-256 GCM iniettata per test.");
            } else {
                Log.w(TAG, "AndroidKeyStore non disponibile (nessun fallback in chiaro consentito): " + t.getMessage());
                sKeystoreAvailable = false;
                sHardwareBackedDetected = false;
            }
        }
    }

    private static SecretKey resolveActiveSecretKey() throws Exception {
        if (sForceKeystoreUnavailableForTest) {
            return null;
        }
        try {
            KeyStore keyStore = KeyStore.getInstance(ANDROID_KEY_STORE);
            keyStore.load(null);
            SecretKey ksKey = (SecretKey) keyStore.getKey(KEY_ALIAS, null);
            if (ksKey != null) {
                return ksKey;
            }
        } catch (Throwable ignored) {
        }
        return sTestFallbackSecretKey;
    }

    /**
     * Cifra una stringa usando AES-256 GCM in AndroidKeyStore.
     * FAIL-CLOSED P0: Se nessuna chiave crittografica AES-256-GCM è disponibile, rifiuta il salvataggio
     * sollevando IllegalStateException (nessun fallback in chiaro Base64 consentito).
     */
    public static String encrypt(String plaintext) {
        if (plaintext == null || plaintext.isEmpty()) return "";
        initKeystore();

        if (!sKeystoreAvailable) {
            throw new IllegalStateException("ERRORE P0 CREDENZIALI: Cifratura crittografica AES-256-GCM non disponibile. Memorizzazione chiave API rifiutata (nessun fallback in chiaro consentito).");
        }

        try {
            SecretKey key = resolveActiveSecretKey();
            if (key == null) {
                throw new IllegalStateException("Chiave crittografica AES-256-GCM assente.");
            }

            Cipher cipher = Cipher.getInstance(CIPHER_TRANSFORMATION);
            byte[] iv;
            if (sTestFallbackSecretKey != null && key == sTestFallbackSecretKey) {
                iv = new byte[GCM_IV_LENGTH_BYTES];
                new SecureRandom().nextBytes(iv);
                cipher.init(Cipher.ENCRYPT_MODE, key, new GCMParameterSpec(GCM_TAG_LENGTH_BITS, iv));
            } else {
                cipher.init(Cipher.ENCRYPT_MODE, key);
                iv = cipher.getIV();
            }
            if (iv == null || iv.length < 12) {
                throw new IllegalStateException("IV AES-GCM non valido.");
            }
            byte[] encrypted = cipher.doFinal(plaintext.getBytes(StandardCharsets.UTF_8));

            byte[] combined = new byte[1 + iv.length + encrypted.length];
            combined[0] = (byte) iv.length;
            System.arraycopy(iv, 0, combined, 1, iv.length);
            System.arraycopy(encrypted, 0, combined, 1 + iv.length, encrypted.length);

            return "ks:" + Base64.encodeToString(combined, Base64.NO_WRAP);
        } catch (IllegalStateException ise) {
            throw ise;
        } catch (Throwable t) {
            Log.e(TAG, "ERRORE P0: Fallimento crittografia AES-256-GCM (nessun fallback in chiaro consentito): " + t.getMessage());
            throw new IllegalStateException("ERRORE P0 CREDENZIALI: Fallimento crittografia AES-256-GCM (" + t.getMessage() + "). Memorizzazione chiave API rifiutata.", t);
        }
    }

    /**
     * Decifra una stringa precedentemente cifrata con prefisso ks: (AES-256 GCM).
     * Rifiuta qualsiasi payload in chiaro legacy (b64: o non cifrato) restituendo stringa vuota.
     */
    public static String decrypt(String ciphertext) {
        if (ciphertext == null || ciphertext.isEmpty()) return "";
        initKeystore();

        if (!ciphertext.startsWith("ks:")) {
            Log.w(TAG, "Payload credenziali legacy non cifrato (prefisso mancante o b64:) rifiutato per sicurezza; richiesta migrazione cifrata o reinserimento.");
            return "";
        }

        if (!sKeystoreAvailable) {
            Log.e(TAG, "Impossibile decifrare credenziale ks:: Keystore crittografico non disponibile.");
            return "";
        }

        try {
            byte[] combined = Base64.decode(ciphertext.substring(3), Base64.DEFAULT);
            if (combined.length < 13) return "";

            int ivLen = combined[0] & 0xFF;
            if (ivLen < 12 || 1 + ivLen >= combined.length) return "";
            byte[] iv = Arrays.copyOfRange(combined, 1, 1 + ivLen);
            byte[] encrypted = Arrays.copyOfRange(combined, 1 + ivLen, combined.length);

            SecretKey key = resolveActiveSecretKey();
            if (key == null) return "";

            Cipher cipher = Cipher.getInstance(CIPHER_TRANSFORMATION);
            GCMParameterSpec spec = new GCMParameterSpec(GCM_TAG_LENGTH_BITS, iv);
            cipher.init(Cipher.DECRYPT_MODE, key, spec);

            byte[] plainBytes = cipher.doFinal(encrypted);
            return new String(plainBytes, StandardCharsets.UTF_8);
        } catch (Throwable t) {
            Log.e(TAG, "Errore decifratura AndroidKeyStore: " + t.getMessage());
            return "";
        }
    }

    /**
     * Indica se il valore salvato usa un formato legacy non cifrato (es. b64: o stringa raw senza prefisso ks:).
     */
    public static boolean isLegacyUnencryptedPayload(String stored) {
        return stored != null && !stored.trim().isEmpty() && !stored.startsWith("ks:");
    }

    /**
     * Tenta di migrare un payload legacy non cifrato in formato AES-256-GCM ("ks:...").
     * Se la cifratura crittografica non e' disponibile, solleva IllegalStateException per forzare la rimozione e il reinserimento.
     */
    public static String migrateLegacyPayloadIfPossible(String stored) {
        if (stored == null || stored.trim().isEmpty()) return "";
        if (stored.startsWith("ks:")) {
            return stored;
        }
        String rawSecret;
        if (stored.startsWith("b64:")) {
            byte[] dec = Base64.decode(stored.substring(4), Base64.DEFAULT);
            rawSecret = new String(dec, StandardCharsets.UTF_8);
        } else {
            try {
                byte[] dec = Base64.decode(stored, Base64.DEFAULT);
                String candidate = new String(dec, StandardCharsets.UTF_8);
                rawSecret = candidate.isEmpty() ? stored : candidate;
            } catch (Exception e) {
                rawSecret = stored;
            }
        }
        return encrypt(rawSecret);
    }

    public static boolean isKeystoreAvailable() {
        initKeystore();
        return sKeystoreAvailable;
    }

    /**
     * Alias pubblico per isHardwareBacked(): rileva realmente KeyInfo.isInsideSecureHardware().
     */
    public static boolean isHardwareBackedKeystore() {
        return isHardwareBacked();
    }

    /**
     * Verifica strumentale se la chiave AES dell'Android Keystore risiede realmente in hardware protetto (TEE / TrustZone).
     */
    public static boolean isHardwareBacked() {
        initKeystore();
        if (!sKeystoreAvailable) return false;
        if (sHardwareBackedDetected != null) return sHardwareBackedDetected;
        try {
            KeyStore keyStore = KeyStore.getInstance(ANDROID_KEY_STORE);
            keyStore.load(null);
            SecretKey key = (SecretKey) keyStore.getKey(KEY_ALIAS, null);
            if (key == null) {
                sHardwareBackedDetected = false;
                return false;
            }

            SecretKeyFactory factory = SecretKeyFactory.getInstance(key.getAlgorithm(), ANDROID_KEY_STORE);
            KeyInfo keyInfo = (KeyInfo) factory.getKeySpec(key, KeyInfo.class);
            boolean insideHw = keyInfo != null && keyInfo.isInsideSecureHardware();
            sHardwareBackedDetected = insideHw;
            Log.i(TAG, "KeyInfo.isInsideSecureHardware() = " + insideHw + (keyInfo != null ? " (origin=" + keyInfo.getOrigin() + ")" : ""));
            return insideHw;
        } catch (Throwable t) {
            Log.w(TAG, "Impossibile interrogare KeyInfo: " + t.getMessage());
            sHardwareBackedDetected = false;
            return false;
        }
    }

    public static String getKeySecurityDetails() {
        initKeystore();
        if (!sKeystoreAvailable) return "Keystore AES-256-GCM non disponibile (salvataggio chiavi bloccato fail-closed)";
        if (sTestFallbackSecretKey != null && Boolean.FALSE.equals(sHardwareBackedDetected)) {
            return "Software AES-256-GCM Key (Host Test Mode, Hardware-Backed: false)";
        }
        try {
            KeyStore keyStore = KeyStore.getInstance(ANDROID_KEY_STORE);
            keyStore.load(null);
            SecretKey key = (SecretKey) keyStore.getKey(KEY_ALIAS, null);
            if (key == null) return "Chiave non trovata in Keystore";

            SecretKeyFactory factory = SecretKeyFactory.getInstance(key.getAlgorithm(), ANDROID_KEY_STORE);
            KeyInfo keyInfo = (KeyInfo) factory.getKeySpec(key, KeyInfo.class);
            boolean insideHw = keyInfo != null && keyInfo.isInsideSecureHardware();
            sHardwareBackedDetected = insideHw;
            return "Hardware-Backed: " + insideHw + ", Origin: " + keyInfo.getOrigin() + ", Purposes: " + keyInfo.getPurposes();
        } catch (Throwable t) {
            return "Errore lettura KeyInfo: " + t.getMessage();
        }
    }
}
