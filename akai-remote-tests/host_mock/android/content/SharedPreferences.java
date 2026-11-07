package android.content;

import java.util.Map;
import java.util.Set;

public interface SharedPreferences {
    interface Editor {
        Editor putString(String key, String value);
        Editor remove(String key);
        Editor clear();
        void apply();
        boolean commit();
    }

    Map<String, ?> getAll();
    String getString(String key, String defValue);
    Editor edit();
}
