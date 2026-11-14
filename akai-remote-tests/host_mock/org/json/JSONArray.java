package org.json;

import java.util.*;

public class JSONArray {
    private final List<Object> list = new ArrayList<>();

    public JSONArray() {}

    public JSONArray(String json) throws JSONException {
        if (json == null || json.trim().isEmpty()) return;
        Object parsed = JSONObject.parseValue(json.trim());
        if (parsed instanceof JSONArray) {
            this.list.addAll(((JSONArray) parsed).list);
        } else {
            throw new JSONException("A JSONArray text must start with '['");
        }
    }

    public JSONArray put(Object val) {
        list.add(val);
        return this;
    }

    public int length() {
        return list.size();
    }

    public Object get(int index) throws JSONException {
        if (index < 0 || index >= list.size()) throw new JSONException("Index out of bounds: " + index);
        return list.get(index);
    }

    public Object opt(int index) {
        if (index < 0 || index >= list.size()) return null;
        return list.get(index);
    }

    public JSONObject getJSONObject(int index) throws JSONException {
        Object val = get(index);
        if (val instanceof JSONObject) return (JSONObject) val;
        throw new JSONException("Element at " + index + " is not a JSONObject");
    }

    public JSONObject optJSONObject(int index) {
        Object val = opt(index);
        return (val instanceof JSONObject) ? (JSONObject) val : null;
    }

    public String optString(int index) {
        Object val = opt(index);
        return val != null ? String.valueOf(val) : "";
    }

    public String getString(int index) throws JSONException {
        Object val = get(index);
        return val != null ? String.valueOf(val) : "";
    }

    @Override
    public String toString() {
        StringBuilder sb = new StringBuilder("[");
        boolean first = true;
        for (Object item : list) {
            if (!first) sb.append(",");
            first = false;
            sb.append(JSONObject.formatValue(item));
        }
        sb.append("]");
        return sb.toString();
    }
}
