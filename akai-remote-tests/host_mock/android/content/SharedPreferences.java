package android.content;

import java.util.Map;

public interface SharedPreferences {
    interface Editor {
        Editor putString(String key, String value);
        Editor putBoolean(String key, boolean value);
        Editor putInt(String key, int value);
        Editor putFloat(String key, float value);
        Editor remove(String key);
        Editor clear();
        void apply();
        boolean commit();
    }

    Map<String, ?> getAll();
    String getString(String key, String defValue);
    boolean getBoolean(String key, boolean defValue);
    int getInt(String key, int defValue);
    float getFloat(String key, float defValue);
    boolean contains(String key);
    Editor edit();
}
