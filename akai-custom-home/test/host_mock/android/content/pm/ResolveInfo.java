package android.content.pm;
import android.graphics.drawable.Drawable;
public class ResolveInfo {
    public ActivityInfo activityInfo = new ActivityInfo();
    public CharSequence loadLabel(PackageManager pm) { return ""; }
    public Drawable loadIcon(PackageManager pm) { return null; }
}
