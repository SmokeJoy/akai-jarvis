package android.content.pm;

public class PackageInfo {
    public String packageName;
    public ApplicationInfo applicationInfo;
    public SigningInfo signingInfo;
    private long longVersionCode;

    public PackageInfo() {}

    public long getLongVersionCode() {
        return longVersionCode;
    }

    public void setLongVersionCode(long longVersionCode) {
        this.longVersionCode = longVersionCode;
    }
}
