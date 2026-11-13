package android.content;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CopyOnWriteArrayList;

public interface SharedPreferences {

    interface OnSharedPreferenceChangeListener {
        void onSharedPreferenceChanged(SharedPreferences sharedPreferences, String key);
    }

    interface Editor {
        Editor putString(String key, String value);

        Editor putStringSet(String key, Set<String> values);

        Editor putInt(String key, int value);

        Editor putLong(String key, long value);

        Editor putFloat(String key, float value);

        Editor putBoolean(String key, boolean value);

        Editor remove(String key);

        Editor clear();

        boolean commit();

        void apply();
    }

    Map<String, ?> getAll();

    String getString(String key, String defValue);

    Set<String> getStringSet(String key, Set<String> defValues);

    int getInt(String key, int defValue);

    long getLong(String key, long defValue);

    float getFloat(String key, float defValue);

    boolean getBoolean(String key, boolean defValue);

    boolean contains(String key);

    Editor edit();

    void registerOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener listener);

    void unregisterOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener listener);

    /**
     * Preferences kept in memory and saved as JSON under {@code <data>/shared_prefs/<name>.json}, so tokens and
     * cookies spiders store survive engine restarts. (The name is kept from Win-box, where it was memory-only.)
     */
    final class Mem implements SharedPreferences {
        private static final Map<String, Mem> ALL = new ConcurrentHashMap<>();

        private final String name;
        private final Map<String, Object> values = new ConcurrentHashMap<>();
        private final CopyOnWriteArrayList<OnSharedPreferenceChangeListener> listeners = new CopyOnWriteArrayList<>();

        public static Mem get(String name) {
            return ALL.computeIfAbsent(name, Mem::new);
        }

        private Mem(String name) {
            this.name = name;
            load();
        }

        private File file() {
            String safe = name.replaceAll("[\\\\/:*?\"<>|]", "_");
            return new File(new File(Context.getBaseDir(), "shared_prefs"), safe + ".json");
        }

        private void load() {
            try {
                File f = file();
                if (!f.isFile()) return;
                JSONObject o = new JSONObject(new String(Files.readAllBytes(f.toPath()), StandardCharsets.UTF_8));
                Iterator<String> keys = o.keys();
                while (keys.hasNext()) {
                    String k = keys.next();
                    Object v = o.get(k);
                    if (v instanceof JSONArray) {
                        JSONArray a = (JSONArray) v;
                        Set<String> set = new HashSet<>();
                        for (int i = 0; i < a.length(); i++) set.add(a.getString(i));
                        values.put(k, set);
                    } else if (v instanceof JSONObject) {
                        // Typed numbers: {"t":"long","v":1}.
                        JSONObject t = (JSONObject) v;
                        String type = t.optString("t");
                        if ("long".equals(type)) values.put(k, t.getLong("v"));
                        else if ("float".equals(type)) values.put(k, (float) t.getDouble("v"));
                        else if ("int".equals(type)) values.put(k, t.getInt("v"));
                    } else if (v != JSONObject.NULL) {
                        values.put(k, v);
                    }
                }
            } catch (Exception e) {
                System.err.println("shared prefs " + name + ": " + e);
            }
        }

        private synchronized void save() {
            try {
                JSONObject o = new JSONObject();
                for (Map.Entry<String, Object> e : values.entrySet()) {
                    Object v = e.getValue();
                    if (v instanceof Set) o.put(e.getKey(), new JSONArray((Set<?>) v));
                    else if (v instanceof Long) o.put(e.getKey(), new JSONObject().put("t", "long").put("v", v));
                    else if (v instanceof Float) o.put(e.getKey(), new JSONObject().put("t", "float").put("v", ((Float) v).doubleValue()));
                    else if (v instanceof Integer) o.put(e.getKey(), new JSONObject().put("t", "int").put("v", v));
                    else o.put(e.getKey(), v);
                }
                File f = file();
                f.getParentFile().mkdirs();
                File tmp = new File(f.getPath() + ".tmp");
                Files.write(tmp.toPath(), o.toString().getBytes(StandardCharsets.UTF_8));
                if (!tmp.renameTo(f)) {
                    f.delete();
                    tmp.renameTo(f);
                }
            } catch (Exception e) {
                System.err.println("shared prefs " + name + ": " + e);
            }
        }

        @Override
        public Map<String, ?> getAll() {
            return new HashMap<>(values);
        }

        @Override
        public String getString(String key, String defValue) {
            Object v = values.get(key);
            return v instanceof String ? (String) v : defValue;
        }

        @Override
        @SuppressWarnings("unchecked")
        public Set<String> getStringSet(String key, Set<String> defValues) {
            Object v = values.get(key);
            return v instanceof Set ? (Set<String>) v : defValues;
        }

        @Override
        public int getInt(String key, int defValue) {
            Object v = values.get(key);
            return v instanceof Number ? ((Number) v).intValue() : defValue;
        }

        @Override
        public long getLong(String key, long defValue) {
            Object v = values.get(key);
            return v instanceof Number ? ((Number) v).longValue() : defValue;
        }

        @Override
        public float getFloat(String key, float defValue) {
            Object v = values.get(key);
            return v instanceof Number ? ((Number) v).floatValue() : defValue;
        }

        @Override
        public boolean getBoolean(String key, boolean defValue) {
            Object v = values.get(key);
            return v instanceof Boolean ? (Boolean) v : defValue;
        }

        @Override
        public boolean contains(String key) {
            return values.containsKey(key);
        }

        @Override
        public Editor edit() {
            return new EditorImpl();
        }

        @Override
        public void registerOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener listener) {
            listeners.addIfAbsent(listener);
        }

        @Override
        public void unregisterOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener listener) {
            listeners.remove(listener);
        }

        private final class EditorImpl implements Editor {
            private final Map<String, Object> pending = new LinkedHashMap<>();
            private final Object removed = new Object();
            private boolean clear;

            private Editor put(String key, Object value) {
                pending.put(key, value == null ? removed : value);
                return this;
            }

            public Editor putString(String key, String value) { return put(key, value); }

            public Editor putStringSet(String key, Set<String> values) { return put(key, values == null ? null : new HashSet<>(values)); }

            public Editor putInt(String key, int value) { return put(key, value); }

            public Editor putLong(String key, long value) { return put(key, value); }

            public Editor putFloat(String key, float value) { return put(key, value); }

            public Editor putBoolean(String key, boolean value) { return put(key, value); }

            public Editor remove(String key) { return put(key, null); }

            public Editor clear() {
                clear = true;
                return this;
            }

            public boolean commit() {
                if (clear) values.clear();
                for (Map.Entry<String, Object> e : pending.entrySet()) {
                    if (e.getValue() == removed) values.remove(e.getKey());
                    else values.put(e.getKey(), e.getValue());
                }
                save();
                for (String key : pending.keySet()) {
                    for (OnSharedPreferenceChangeListener l : listeners) {
                        try {
                            l.onSharedPreferenceChanged(Mem.this, key);
                        } catch (Throwable ignored) {
                        }
                    }
                }
                return true;
            }

            public void apply() {
                commit();
            }
        }
    }
}
