package android.content.pm;

public class ApplicationInfo {
    public String packageName;
    public int minSdkVersion = 21;
    public int targetSdkVersion = 28;

    public ApplicationInfo() {}

    public ApplicationInfo(String packageName) {
        this.packageName = packageName;
    }
}
