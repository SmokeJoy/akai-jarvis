package android.content.pm;
import android.graphics.drawable.Drawable;
public class ActivityInfo {
    public String packageName = "";
    public String name = "";
    public ApplicationInfo applicationInfo = new ApplicationInfo();
    public Drawable loadBanner(PackageManager pm) { return null; }
}
