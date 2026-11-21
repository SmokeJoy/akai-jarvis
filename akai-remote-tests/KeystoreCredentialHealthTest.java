package it.akai.customremote;

import android.content.Context;
import android.content.SharedPreferences;
import it.akai.customremote.ai.AiProviderAdapter;
import it.akai.customremote.ai.KeystoreSecurityHelper;
import org.json.JSONObject;

import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;

/**
 * Verifies boolean-only AndroidKeyStore alias and credential decryptability checks:
 * 1) Missing alias is never auto-created by read-only checks.
 * 2) Matching AES-256 key decrypts stored credentials with boolean-only output (no secrets exposed).
 * 3) Simulating adb uninstall keystore wipe (null alias or regenerated mismatching key) flags
 *    undecryptable_stored_credentials=true even when XML ciphertexts remain present.
 * 4) Legacy non-"ks:" payloads are rejected as undecryptable.
 */
public final class KeystoreCredentialHealthTest {
    private static int passed = 0;

    private static void expect(boolean ok, String msg) {
        if (!ok) throw new AssertionError(msg);
        passed++;
    }

    private static SecretKey generateAes256Key() throws Exception {
        KeyGenerator kg = KeyGenerator.getInstance("AES");
        kg.init(256);
        return kg.generateKey();
    }

    public static void main(String[] args) throws Exception {
        try {
            KeystoreSecurityHelper.setForceKeystoreUnavailableForTest(false);
            KeystoreSecurityHelper.setTestFallbackSecretKey(null);

            Context ctx = new Context() {};
            AiProviderAdapter adapter = new AiProviderAdapter(ctx);

            // 1. Missing alias stays absent (never auto-created by read-only health check)
            expect(!KeystoreSecurityHelper.hasExistingKeyAlias(), "missing alias initially false");
            JSONObject emptyHealth = adapter.getCredentialKeystoreHealth();
            expect(!KeystoreSecurityHelper.hasExistingKeyAlias(), "read-only health check never auto-creates alias");
            expect(!emptyHealth.getBoolean("keystore_alias_present"), "empty alias absent");
            expect(!emptyHealth.getBoolean("deepseek_ciphertext_present"), "empty ds absent");
            expect(!emptyHealth.getBoolean("kimi_ciphertext_present"), "empty km absent");
            expect(!emptyHealth.getBoolean("undecryptable_stored_credentials"), "no undecryptable empty creds");
            expect(emptyHealth.getBoolean("all_stored_credentials_decryptable"), "vacuously decryptable");

            // 2. Valid AES-256 key encrypts & passes boolean health without leaking secrets
            SecretKey keyA = generateAes256Key();
            KeystoreSecurityHelper.setTestFallbackSecretKey(keyA);
            String dummyDs = "dummy_test_ds_cred_alpha_001";
            String dummyKm = "dummy_test_km_cred_beta_002";
            adapter.setApiKey(AiProviderAdapter.PROVIDER_DEEPSEEK, dummyDs);
            adapter.setApiKey(AiProviderAdapter.PROVIDER_KIMI, dummyKm);

            JSONObject okHealth = adapter.getCredentialKeystoreHealth();
            expect(okHealth.getBoolean("keystore_alias_present"), "keyA alias present");
            expect(okHealth.getBoolean("deepseek_ciphertext_present"), "ds ciphertext present");
            expect(okHealth.getBoolean("deepseek_decryptable"), "ds decryptable with keyA");
            expect(okHealth.getBoolean("kimi_ciphertext_present"), "km ciphertext present");
            expect(okHealth.getBoolean("kimi_decryptable"), "km decryptable with keyA");
            expect(!okHealth.getBoolean("undecryptable_stored_credentials"), "no undecryptable with keyA");
            expect(okHealth.getBoolean("all_stored_credentials_decryptable"), "all decryptable with keyA");
            String okJson = okHealth.toString();
            expect(!okJson.contains(dummyDs) && !okJson.contains(dummyKm) && !okJson.contains("ks:"),
                    "health JSON never contains plaintext keys or ciphertexts");

            // 3. Simulated adb uninstall keystore wipe while XML prefs restored intact
            KeystoreSecurityHelper.setTestFallbackSecretKey(null);
            JSONObject wipedHealth = adapter.getCredentialKeystoreHealth();
            expect(!KeystoreSecurityHelper.hasExistingKeyAlias(), "wiped alias stays absent after health poll");
            expect(!wipedHealth.getBoolean("keystore_alias_present"), "wiped alias false");
            expect(wipedHealth.getBoolean("deepseek_ciphertext_present"), "ds ciphertext still in XML");
            expect(!wipedHealth.getBoolean("deepseek_decryptable"), "ds undecryptable after keystore wipe");
            expect(wipedHealth.getBoolean("kimi_ciphertext_present"), "km ciphertext still in XML");
            expect(!wipedHealth.getBoolean("kimi_decryptable"), "km undecryptable after keystore wipe");
            expect(wipedHealth.getBoolean("undecryptable_stored_credentials"), "flags lost credentials on wipe");
            expect(!wipedHealth.getBoolean("all_stored_credentials_decryptable"), "all_decryptable false on wipe");

            // 4. Simulated regenerated Keystore key (keyB != keyA) with restored keyA XML
            SecretKey keyB = generateAes256Key();
            KeystoreSecurityHelper.setTestFallbackSecretKey(keyB);
            JSONObject mismatchHealth = adapter.getCredentialKeystoreHealth();
            expect(mismatchHealth.getBoolean("keystore_alias_present"), "keyB alias present");
            expect(mismatchHealth.getBoolean("deepseek_ciphertext_present"), "ds ciphertext present for mismatch");
            expect(!mismatchHealth.getBoolean("deepseek_decryptable"), "keyB cannot decrypt keyA ds ciphertext");
            expect(!mismatchHealth.getBoolean("kimi_decryptable"), "keyB cannot decrypt keyA km ciphertext");
            expect(mismatchHealth.getBoolean("undecryptable_stored_credentials"), "flags mismatching keystore");
            expect(!mismatchHealth.getBoolean("all_stored_credentials_decryptable"), "all_decryptable false on mismatch");

            // 5. Legacy unencrypted payload blocked even with valid key
            KeystoreSecurityHelper.setTestFallbackSecretKey(keyA);
            SharedPreferences sp = ctx.getSharedPreferences("akai_ai_security_prefs", Context.MODE_PRIVATE);
            sp.edit().putString("sec_enc_deepseek_key", "b64:legacyPlain").apply();
            JSONObject legacyHealth = adapter.getCredentialKeystoreHealth();
            expect(legacyHealth.getBoolean("deepseek_ciphertext_present"), "legacy payload detected present");
            expect(!legacyHealth.getBoolean("deepseek_decryptable"), "legacy non-ks payload rejected");
            expect(legacyHealth.getBoolean("undecryptable_stored_credentials"), "legacy payload flagged undecryptable");

            System.out.println("[PASS] KeystoreCredentialHealthTest: all " + passed + " assertions passed.");
        } finally {
            KeystoreSecurityHelper.setTestFallbackSecretKey(null);
            KeystoreSecurityHelper.setForceKeystoreUnavailableForTest(false);
        }
    }
}
