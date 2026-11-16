package android.security.keystore;

import java.security.spec.KeySpec;

public class KeyInfo implements KeySpec {
    public boolean isInsideSecureHardware() { return false; }
    public int getOrigin() { return 0; }
    public int getPurposes() { return 0; }
}
