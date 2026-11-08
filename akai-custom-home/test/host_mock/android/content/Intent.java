package android.content;
import android.net.Uri;
public class Intent {
    public static final String ACTION_MAIN = "android.intent.action.MAIN";
    public static final String ACTION_VIEW = "android.intent.action.VIEW";
    public static final String CATEGORY_DEFAULT = "android.intent.category.DEFAULT";
    public static final String CATEGORY_LAUNCHER = "android.intent.category.LAUNCHER";
    public static final String CATEGORY_LEANBACK_LAUNCHER = "android.intent.category.LEANBACK_LAUNCHER";
    public static final String ACTION_PACKAGE_ADDED = "android.intent.action.PACKAGE_ADDED";
    public static final String ACTION_PACKAGE_REMOVED = "android.intent.action.PACKAGE_REMOVED";
    public static final String ACTION_PACKAGE_REPLACED = "android.intent.action.PACKAGE_REPLACED";
    public static final int FLAG_ACTIVITY_NEW_TASK = 268435456;
    public Intent() {}
    public Intent(String a) {}
    public Intent(String a, Uri u) {}
    public Intent addCategory(String c) { return this; }
    public Intent addFlags(int f) { return this; }
    public Intent setComponent(ComponentName c) { return this; }
    public Intent setPackage(String p) { return this; }
    public Intent setData(Uri u) { return this; }
}
