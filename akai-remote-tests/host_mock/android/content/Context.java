package android.content;

import java.io.File;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;

public abstract class Context {
    public static final int MODE_PRIVATE = 0;
    public static final String AUDIO_SERVICE = "audio";

    private final Map<String, SharedPreferences> mMockPrefs = new HashMap<>();

    public SharedPreferences getSharedPreferences(String name, int mode) {
        synchronized (mMockPrefs) {
            SharedPreferences sp = mMockPrefs.get(name);
            if (sp == null) {
                sp = new InMemorySharedPreferences();
                mMockPrefs.put(name, sp);
            }
            return sp;
        }
    }

    public File getFilesDir() { return new File("."); }
    public String getPackageName() { return "it.akai.customremote"; }
    public android.content.res.AssetManager getAssets() { return new android.content.res.AssetManager(); }
    public Context getApplicationContext() { return this; }
    public android.content.pm.PackageManager getPackageManager() { return new android.content.pm.PackageManager(); }
    public Object getSystemService(String name) { return null; }

    private static class InMemorySharedPreferences implements SharedPreferences {
        private final Map<String, Object> store = new LinkedHashMap<>();

        @Override
        public synchronized Map<String, ?> getAll() {
            return Collections.unmodifiableMap(new LinkedHashMap<>(store));
        }

        @Override
        public synchronized String getString(String key, String defValue) {
            Object v = store.get(key);
            return (v instanceof String) ? (String) v : defValue;
        }

        @Override
        public synchronized boolean getBoolean(String key, boolean defValue) {
            Object v = store.get(key);
            return (v instanceof Boolean) ? (Boolean) v : defValue;
        }

        @Override
        public synchronized int getInt(String key, int defValue) {
            Object v = store.get(key);
            return (v instanceof Number) ? ((Number) v).intValue() : defValue;
        }

        @Override
        public synchronized float getFloat(String key, float defValue) {
            Object v = store.get(key);
            return (v instanceof Number) ? ((Number) v).floatValue() : defValue;
        }

        @Override
        public synchronized boolean contains(String key) {
            return store.containsKey(key);
        }

        @Override
        public Editor edit() {
            return new Editor() {
                private final Map<String, Object> pending = new LinkedHashMap<>();
                private boolean clearRequested = false;

                @Override
                public Editor putString(String key, String value) {
                    pending.put(key, value);
                    return this;
                }

                @Override
                public Editor putBoolean(String key, boolean value) {
                    pending.put(key, Boolean.valueOf(value));
                    return this;
                }

                @Override
                public Editor putInt(String key, int value) {
                    pending.put(key, Integer.valueOf(value));
                    return this;
                }

                @Override
                public Editor putFloat(String key, float value) {
                    pending.put(key, Float.valueOf(value));
                    return this;
                }

                @Override
                public Editor remove(String key) {
                    pending.put(key, InMemorySharedPreferences.this); // sentinel
                    return this;
                }

                @Override
                public Editor clear() {
                    clearRequested = true;
                    return this;
                }

                @Override
                public void apply() {
                    commit();
                }

                @Override
                public boolean commit() {
                    synchronized (InMemorySharedPreferences.this) {
                        if (clearRequested) {
                            store.clear();
                        }
                        for (Map.Entry<String, Object> e : pending.entrySet()) {
                            if (e.getValue() == InMemorySharedPreferences.this || e.getValue() == null) {
                                store.remove(e.getKey());
                            } else {
                                store.put(e.getKey(), e.getValue());
                            }
                        }
                        return true;
                    }
                }
            };
        }
    }
}
