package android.content;
import java.util.Set;
public interface SharedPreferences {
    interface Editor {
        Editor putString(String k, String v);
        Editor putStringSet(String k, Set<String> v);
        Editor putInt(String k, int v);
        Editor putBoolean(String k, boolean v);
        void apply();
    }
    String getString(String k, String d);
    Set<String> getStringSet(String k, Set<String> d);
    int getInt(String k, int d);
    boolean getBoolean(String k, boolean d);
    Editor edit();
}
