package it.akai.customremote.ai;

import android.content.Context;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.security.PublicKey;

/**
 * OTA release trust anchor from a file BUNDLED IN THE ORIGINAL-SIGNED APK.
 * No network, generated keys, fallback trust anchor or auto-enrolment.
 *
 * The asset is deliberately absent until the owner creates a distinct offline
 * release signing key and approves embedding its PUBLIC SPKI bytes in v4.
 * Until then OTA must remain DISABLED and not install anything.
 */
public final class OtaReleaseTrust {
    private static final String ASSET = "ota-release-public.der";
    private OtaReleaseTrust() {}

    public static PublicKey readBundledPublicKey(Context context) {
        if (context == null) return null;
        try (InputStream in = context.getAssets().open(ASSET);
             ByteArrayOutputStream bytes = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[512];
            int n;
            int emptyReads = 0;
            while ((n = in.read(buffer)) != -1) {
                if (n == 0) {
                    if (++emptyReads >= 3) return null;
                    continue;
                }
                emptyReads = 0;
                if (bytes.size() + n > 1024) return null;
                bytes.write(buffer, 0, n);
            }
            return OtaPinnedReleaseKey.decodeBundledSpki(bytes.toByteArray());
        } catch (Exception missingOrInvalidAsset) {
            return null;
        }
    }
}
