package android.content.pm;

public final class SigningInfo {
    private final boolean multipleSigners;
    private final Signature[] signers;

    public SigningInfo(boolean multipleSigners, Signature[] signers) {
        this.multipleSigners = multipleSigners;
        this.signers = signers != null ? signers.clone() : new Signature[0];
    }

    public boolean hasMultipleSigners() {
        return multipleSigners;
    }

    public Signature[] getApkContentsSigners() {
        return signers.clone();
    }
}
