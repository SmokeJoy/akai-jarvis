package android.content;
import android.net.Uri;
import java.util.HashMap;
import java.util.Map;

public class Intent {
    public static final String ACTION_MAIN = "android.intent.action.MAIN";
    public static final String ACTION_VIEW = "android.intent.action.VIEW";
    public static final String CATEGORY_DEFAULT = "android.intent.category.DEFAULT";
    public static final String CATEGORY_LAUNCHER = "android.intent.category.LAUNCHER";
    public static final String CATEGORY_LEANBACK_LAUNCHER = "android.intent.category.LEANBACK_LAUNCHER";
    public static final String ACTION_PACKAGE_ADDED = "android.intent.action.PACKAGE_ADDED";
    public static final String ACTION_PACKAGE_REMOVED = "android.intent.action.PACKAGE_REMOVED";
    public static final String ACTION_PACKAGE_REPLACED = "android.intent.action.PACKAGE_REPLACED";
    public static final String EXTRA_REPLACING = "android.intent.extra.REPLACING";
    public static final int FLAG_ACTIVITY_NEW_TASK = 268435456;

    private String action;
    private Uri data;
    private final Map<String, Object> extras = new HashMap<String, Object>();

    public Intent() {}
    public Intent(String a) { this.action = a; }
    public Intent(String a, Uri u) { this.action = a; this.data = u; }

    public String getAction() { return action; }
    public Uri getData() { return data; }
    public Intent setData(Uri u) { this.data = u; return this; }

    public Intent putExtra(String name, boolean value) { extras.put(name, value); return this; }
    public boolean getBooleanExtra(String name, boolean defaultValue) {
        Object val = extras.get(name);
        return (val instanceof Boolean) ? (Boolean) val : defaultValue;
    }

    public Intent addCategory(String c) { return this; }
    public Intent addFlags(int f) { return this; }
    public Intent setComponent(ComponentName c) { return this; }
    public Intent setPackage(String p) { return this; }
}
