package android.content;

import java.util.HashMap;
import java.util.Map;

public class Intent {
    public static final String EXTRA_INTENT = "android.intent.extra.INTENT";
    public static final int FLAG_ACTIVITY_NEW_TASK = 0x10000000;

    private String action;
    private String packageName;
    private Class<?> componentClass;
    private int flags;
    private final Map<String, Object> extras = new HashMap<>();

    public Intent() {}

    public Intent(Context context, Class<?> cls) {
        this.packageName = context != null ? context.getPackageName() : null;
        this.componentClass = cls;
    }

    public Intent setAction(String action) {
        this.action = action;
        return this;
    }

    public String getAction() {
        return action;
    }

    public Intent setPackage(String packageName) {
        this.packageName = packageName;
        return this;
    }

    public String getPackage() {
        return packageName;
    }

    public Class<?> getComponentClass() {
        return componentClass;
    }

    public Intent putExtra(String name, int value) {
        extras.put(name, Integer.valueOf(value));
        return this;
    }

    public int getIntExtra(String name, int defaultValue) {
        Object v = extras.get(name);
        return (v instanceof Integer) ? ((Integer) v).intValue() : defaultValue;
    }

    public Intent addFlags(int flags) {
        this.flags |= flags;
        return this;
    }

    public int getFlags() {
        return flags;
    }
}
