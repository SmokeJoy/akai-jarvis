package org.json;

import java.util.*;

public class JSONObject {
    private final Map<String, Object> map = new LinkedHashMap<>();

    public JSONObject() {}

    public JSONObject(String json) throws JSONException {
        if (json == null || json.trim().isEmpty()) {
            return;
        }
        Object parsed = parseValue(json.trim());
        if (parsed instanceof JSONObject) {
            this.map.putAll(((JSONObject) parsed).map);
        } else {
            throw new JSONException("A JSONObject text must begin with '{'");
        }
    }

    public JSONObject put(String key, Object value) throws JSONException {
        if (key == null) throw new JSONException("Null key");
        map.put(key, value);
        return this;
    }

    public JSONObject put(String key, boolean value) throws JSONException {
        return put(key, Boolean.valueOf(value));
    }

    public JSONObject put(String key, double value) throws JSONException {
        return put(key, Double.valueOf(value));
    }

    public JSONObject put(String key, int value) throws JSONException {
        return put(key, Integer.valueOf(value));
    }

    public JSONObject put(String key, long value) throws JSONException {
        return put(key, Long.valueOf(value));
    }

    public Object get(String key) throws JSONException {
        if (!map.containsKey(key)) throw new JSONException("No value for " + key);
        return map.get(key);
    }

    public Object opt(String key) {
        return map.get(key);
    }

    public boolean has(String key) {
        return map.containsKey(key);
    }

    public Object remove(String key) {
        return map.remove(key);
    }

    public String getString(String key) throws JSONException {
        Object val = get(key);
        return val != null ? String.valueOf(val) : null;
    }

    public String optString(String key) {
        return optString(key, "");
    }

    public String optString(String key, String fallback) {
        Object val = opt(key);
        return val != null ? String.valueOf(val) : fallback;
    }

    public boolean getBoolean(String key) throws JSONException {
        Object val = get(key);
        if (val instanceof Boolean) return (Boolean) val;
        if ("true".equalsIgnoreCase(String.valueOf(val))) return true;
        if ("false".equalsIgnoreCase(String.valueOf(val))) return false;
        throw new JSONException("Value for " + key + " is not a boolean");
    }

    public boolean optBoolean(String key) {
        return optBoolean(key, false);
    }

    public boolean optBoolean(String key, boolean fallback) {
        Object val = opt(key);
        if (val instanceof Boolean) return (Boolean) val;
        if (val != null) {
            String s = String.valueOf(val);
            if ("true".equalsIgnoreCase(s)) return true;
            if ("false".equalsIgnoreCase(s)) return false;
        }
        return fallback;
    }

    public int getInt(String key) throws JSONException {
        Object val = get(key);
        if (val instanceof Number) return ((Number) val).intValue();
        try {
            return Integer.parseInt(String.valueOf(val));
        } catch (Exception e) {
            throw new JSONException("Value for " + key + " is not an int");
        }
    }

    public int optInt(String key) {
        return optInt(key, 0);
    }

    public int optInt(String key, int fallback) {
        Object val = opt(key);
        if (val instanceof Number) return ((Number) val).intValue();
        if (val != null) {
            try { return Integer.parseInt(String.valueOf(val)); } catch (Exception ignored) {}
        }
        return fallback;
    }

    public long getLong(String key) throws JSONException {
        Object val = get(key);
        if (val instanceof Number) return ((Number) val).longValue();
        try {
            return Long.parseLong(String.valueOf(val));
        } catch (Exception e) {
            throw new JSONException("Value for " + key + " is not a long");
        }
    }

    public long optLong(String key) {
        return optLong(key, 0L);
    }

    public long optLong(String key, long fallback) {
        Object val = opt(key);
        if (val instanceof Number) return ((Number) val).longValue();
        if (val != null) {
            try { return Long.parseLong(String.valueOf(val)); } catch (Exception ignored) {}
        }
        return fallback;
    }

    public double getDouble(String key) throws JSONException {
        Object val = get(key);
        if (val instanceof Number) return ((Number) val).doubleValue();
        try {
            return Double.parseDouble(String.valueOf(val));
        } catch (Exception e) {
            throw new JSONException("Value for " + key + " is not a double");
        }
    }

    public double optDouble(String key) {
        return optDouble(key, 0.0);
    }

    public double optDouble(String key, double fallback) {
        Object val = opt(key);
        if (val instanceof Number) return ((Number) val).doubleValue();
        if (val != null) {
            try { return Double.parseDouble(String.valueOf(val)); } catch (Exception ignored) {}
        }
        return fallback;
    }

    public JSONObject getJSONObject(String key) throws JSONException {
        Object val = get(key);
        if (val instanceof JSONObject) return (JSONObject) val;
        throw new JSONException("Value for " + key + " is not a JSONObject");
    }

    public JSONObject optJSONObject(String key) {
        Object val = opt(key);
        return (val instanceof JSONObject) ? (JSONObject) val : null;
    }

    public JSONArray getJSONArray(String key) throws JSONException {
        Object val = get(key);
        if (val instanceof JSONArray) return (JSONArray) val;
        throw new JSONException("Value for " + key + " is not a JSONArray");
    }

    public JSONArray optJSONArray(String key) {
        Object val = opt(key);
        return (val instanceof JSONArray) ? (JSONArray) val : null;
    }

    public int length() {
        return map.size();
    }

    public Set<String> keySet() {
        return map.keySet();
    }

    public Iterator<String> keys() {
        return map.keySet().iterator();
    }

    @Override
    public String toString() {
        StringBuilder sb = new StringBuilder("{");
        boolean first = true;
        for (Map.Entry<String, Object> entry : map.entrySet()) {
            if (!first) sb.append(",");
            first = false;
            sb.append("\"").append(escape(entry.getKey())).append("\":");
            sb.append(formatValue(entry.getValue()));
        }
        sb.append("}");
        return sb.toString();
    }

    static String formatValue(Object val) {
        if (val == null) return "null";
        if (val instanceof String) return "\"" + escape((String) val) + "\"";
        if (val instanceof Number || val instanceof Boolean) return String.valueOf(val);
        if (val instanceof JSONObject || val instanceof JSONArray) return val.toString();
        return "\"" + escape(String.valueOf(val)) + "\"";
    }

    static String escape(String s) {
        if (s == null) return "";
        return s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t");
    }

    // Simple JSON Parser
    static Object parseValue(String src) throws JSONException {
        if (src == null) return null;
        src = src.trim();
        if (src.isEmpty()) return null;
        if (src.startsWith("{")) {
            return parseObject(src);
        } else if (src.startsWith("[")) {
            return parseArray(src);
        } else if (src.startsWith("\"")) {
            return parseString(src);
        } else if ("true".equals(src)) {
            return Boolean.TRUE;
        } else if ("false".equals(src)) {
            return Boolean.FALSE;
        } else if ("null".equals(src)) {
            return null;
        } else {
            try {
                if (src.contains(".")) return Double.parseDouble(src);
                return Long.parseLong(src);
            } catch (Exception e) {
                return src;
            }
        }
    }

    private static JSONObject parseObject(String src) throws JSONException {
        JSONObject obj = new JSONObject();
        src = src.substring(1, src.length() - 1).trim();
        if (src.isEmpty()) return obj;

        List<String> pairs = splitTokens(src, ',');
        for (String pair : pairs) {
            int colonIdx = findColon(pair);
            if (colonIdx < 0) continue;
            String k = pair.substring(0, colonIdx).trim();
            String v = pair.substring(colonIdx + 1).trim();
            if (k.startsWith("\"") && k.endsWith("\"")) {
                k = unescape(k.substring(1, k.length() - 1));
            }
            obj.put(k, parseValue(v));
        }
        return obj;
    }

    static JSONArray parseArray(String src) throws JSONException {
        JSONArray arr = new JSONArray();
        src = src.substring(1, src.length() - 1).trim();
        if (src.isEmpty()) return arr;

        List<String> items = splitTokens(src, ',');
        for (String item : items) {
            arr.put(parseValue(item.trim()));
        }
        return arr;
    }

    private static String parseString(String src) {
        if (src.startsWith("\"") && src.endsWith("\"") && src.length() >= 2) {
            return unescape(src.substring(1, src.length() - 1));
        }
        return src;
    }

    private static int findColon(String s) {
        boolean inQuotes = false;
        int depth = 0;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '"' && (i == 0 || s.charAt(i - 1) != '\\')) inQuotes = !inQuotes;
            else if (!inQuotes) {
                if (c == '{' || c == '[') depth++;
                else if (c == '}' || c == ']') depth--;
                else if (c == ':' && depth == 0) return i;
            }
        }
        return -1;
    }

    static List<String> splitTokens(String s, char delim) {
        List<String> list = new ArrayList<>();
        boolean inQuotes = false;
        int depth = 0;
        int start = 0;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '"' && (i == 0 || s.charAt(i - 1) != '\\')) inQuotes = !inQuotes;
            else if (!inQuotes) {
                if (c == '{' || c == '[') depth++;
                else if (c == '}' || c == ']') depth--;
                else if (c == delim && depth == 0) {
                    list.add(s.substring(start, i).trim());
                    start = i + 1;
                }
            }
        }
        if (start < s.length()) {
            list.add(s.substring(start).trim());
        }
        return list;
    }

    static String unescape(String s) {
        return s.replace("\\\"", "\"").replace("\\\\", "\\").replace("\\n", "\n").replace("\\r", "\r").replace("\\t", "\t");
    }
}
