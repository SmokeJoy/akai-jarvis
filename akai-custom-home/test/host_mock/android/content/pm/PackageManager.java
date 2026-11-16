package android.content.pm;
import android.content.Intent;
import android.graphics.drawable.Drawable;
import java.util.ArrayList;
import java.util.List;
public class PackageManager {
    public List<ResolveInfo> queryIntentActivities(Intent i, int f) { return new ArrayList<ResolveInfo>(); }
    public Intent getLaunchIntentForPackage(String p) { return new Intent(); }
    public Intent getLeanbackLaunchIntentForPackage(String p) { return new Intent(); }
    public PackageInfo getPackageInfo(String packageName, int flags) throws Exception { return null; }
    public Drawable getApplicationBanner(ApplicationInfo info) { return null; }
}
