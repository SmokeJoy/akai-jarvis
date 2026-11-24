package android.content;

public class ContentResolver {
    private final String androidId;

    public ContentResolver() {
        this.androidId = null;
    }

    public ContentResolver(String androidId) {
        this.androidId = androidId;
    }

    public String getTestAndroidId() {
        return androidId;
    }
}
