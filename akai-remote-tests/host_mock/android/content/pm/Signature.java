package android.content.pm;

public class Signature {
    private final byte[] certificateBytes;

    public Signature(byte[] certificateBytes) {
        this.certificateBytes = certificateBytes != null ? certificateBytes.clone() : new byte[0];
    }

    public byte[] toByteArray() {
        return certificateBytes.clone();
    }
}
