package it.akai.customremote;

import it.akai.customremote.ai.OtaArchiveIdentityGate;
import it.akai.customremote.ai.OtaCandidateGate;

public final class OtaArchiveIdentityGateTest {
    private static final String PINNED = OtaCandidateGate.EXPECTED_SIGNER_SHA256;
    private static final String WRONG =
            "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899";
    private static int checks;

    private static void expect(boolean allowed, String label,
                               String pkg, long version, int minSdk, int targetSdk,
                               String archiveSigner, long installed, String installedSigner,
                               String pinned) {
        OtaArchiveIdentityGate.Verdict v = OtaArchiveIdentityGate.inspect(
                pkg, version, minSdk, targetSdk, archiveSigner, installed, installedSigner, pinned);
        if (v.accepted != allowed) {
            throw new AssertionError(label + ": " + v.code);
        }
        checks++;
    }

    public static void main(String[] args) {
        String pkg = OtaCandidateGate.PACKAGE;
        expect(true, "valid Android9 v4 upgrade", pkg, 4, 21, 28, PINNED, 3, PINNED, PINNED);
        expect(false, "wrong package", "org.fake.tv", 4, 21, 28, PINNED, 3, PINNED, PINNED);
        expect(false, "missing package", null, 4, 21, 28, PINNED, 3, PINNED, PINNED);
        expect(false, "same version", pkg, 3, 21, 28, PINNED, 3, PINNED, PINNED);
        expect(false, "downgrade", pkg, 2, 21, 28, PINNED, 3, PINNED, PINNED);
        expect(false, "installed version unknown", pkg, 4, 21, 28, PINNED, 0, PINNED, PINNED);
        expect(false, "archive version unknown", pkg, 0, 21, 28, PINNED, 3, PINNED, PINNED);
        expect(false, "unsupported long version", pkg, 2147483648L, 21, 28, PINNED, 3, PINNED, PINNED);
        expect(false, "API too recent", pkg, 4, 29, 28, PINNED, 3, PINNED, PINNED);
        expect(false, "minSDK missing", pkg, 4, 0, 28, PINNED, 3, PINNED, PINNED);
        expect(false, "minSDK too old", pkg, 4, 20, 28, PINNED, 3, PINNED, PINNED);
        expect(false, "targetSDK missing", pkg, 4, 21, 0, PINNED, 3, PINNED, PINNED);
        expect(false, "targetSDK newer than TV", pkg, 4, 21, 29, PINNED, 3, PINNED, PINNED);
        expect(false, "wrong archive signer", pkg, 4, 21, 28, WRONG, 3, PINNED, PINNED);
        expect(false, "missing archive signer", pkg, 4, 21, 28, null, 3, PINNED, PINNED);
        expect(false, "wrong installed signer", pkg, 4, 21, 28, PINNED, 3, WRONG, PINNED);
        expect(false, "unknown installed signer", pkg, 4, 21, 28, PINNED, 3, "", PINNED);
        expect(false, "pin mismatch", pkg, 4, 21, 28, PINNED, 3, PINNED, WRONG);
        expect(false, "invalid pin", pkg, 4, 21, 28, PINNED, 3, PINNED, "invalid");
        expect(true, "case-insensitive hex", pkg, 4, 21, 28, PINNED.toUpperCase(),
               3, PINNED, PINNED);
        System.out.println("OtaArchiveIdentityGateTest PASS: " + checks +
                " checks (host policy only; no actual Android archive parsed)");
    }
}
