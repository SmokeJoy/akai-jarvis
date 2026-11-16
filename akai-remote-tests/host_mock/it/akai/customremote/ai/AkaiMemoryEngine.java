package it.akai.customremote.ai;

import android.content.Context;
import org.json.JSONArray;
import org.json.JSONObject;
import java.util.LinkedHashMap;
import java.util.Map;

public class AkaiMemoryEngine {
    private static final AkaiMemoryEngine sInstance = new AkaiMemoryEngine();
    private boolean mGuestMode = false;
    private final Map<String, JSONObject> mProcedures = new LinkedHashMap<>();
    private final Map<String, String> mPreferences = new LinkedHashMap<>();
    private final Map<String, Long> mStats = new LinkedHashMap<>();
    private JSONArray mConversations = new JSONArray();

    public static synchronized AkaiMemoryEngine getInstance(Context context) {
        return sInstance;
    }

    public synchronized void resetForTest() {
        mGuestMode = false;
        mProcedures.clear();
        mPreferences.clear();
        mStats.clear();
        mConversations = new JSONArray();
    }

    public synchronized boolean isGuestMode() {
        return mGuestMode;
    }

    public synchronized void setGuestMode(boolean guestMode) {
        this.mGuestMode = guestMode;
    }

    public synchronized JSONObject getAllPreferences() {
        JSONObject out = new JSONObject();
        try {
            for (Map.Entry<String, String> e : mPreferences.entrySet()) {
                out.put(e.getKey(), e.getValue());
            }
        } catch (Exception ignored) {}
        return out;
    }

    public synchronized String getPreference(String key, String defValue) {
        String v = mPreferences.get(key);
        return v != null ? v : defValue;
    }

    public synchronized boolean setPreference(String key, String value, String category, int isPersonal) {
        if (key == null) return false;
        mPreferences.put(key, value);
        return true;
    }

    public synchronized void setPreference(String key, String value) {
        setPreference(key, value, "general", 0);
    }

    public synchronized boolean deletePreference(String key) {
        return key != null && mPreferences.remove(key) != null;
    }

    public synchronized void clearPersonalPreferencesOnly() {
        // No-op in minimal host mock unless needed
    }

    public synchronized void saveConversationExchange(String query, String reply, String status,
                                                         String intentKey, int tokens, double costEur) {
        try {
            JSONObject item = new JSONObject();
            item.put("user_query", query);
            item.put("assistant_reply", reply);
            item.put("status", status);
            item.put("intent_key", intentKey);
            item.put("tokens_spent", tokens);
            item.put("cost_eur", costEur);
            mConversations.put(item);
        } catch (Exception ignored) {}
    }

    public synchronized JSONArray getRecentConversations(int limit) {
        JSONArray res = new JSONArray();
        int start = Math.max(0, mConversations.length() - Math.max(1, limit));
        for (int i = start; i < mConversations.length(); i++) {
            res.put(mConversations.opt(i));
        }
        return res;
    }

    public synchronized JSONObject findProcedureByGoal(String goal) {
        if (goal == null) return null;
        String clean = goal.trim().toLowerCase();
        JSONObject exact = mProcedures.get(clean);
        if (exact != null) return exact;
        for (JSONObject p : mProcedures.values()) {
            String gi = p.optString("goal_intent", "").toLowerCase();
            if (!gi.isEmpty() && (gi.equals(clean) || clean.contains(gi))) {
                return p;
            }
        }
        return null;
    }

    public synchronized JSONObject getProcedure(String intentKey) {
        return intentKey != null ? mProcedures.get(intentKey) : null;
    }

    public synchronized void recordProcedureSuccess(String intentKey) {
        JSONObject p = mProcedures.get(intentKey);
        if (p != null) {
            try { p.put("success_count", p.optInt("success_count", 0) + 1); } catch (Exception ignored) {}
        }
    }

    public synchronized void recordProcedureFailure(String intentKey) {
        JSONObject p = mProcedures.get(intentKey);
        if (p != null) {
            try { p.put("failure_count", p.optInt("failure_count", 0) + 1); } catch (Exception ignored) {}
        }
    }

    public synchronized boolean saveVerifiedProcedure(String intentKey, String goalIntent, String description,
                                                      String appPackage, String initialState, JSONArray actions,
                                                      String successCondition, String appVersion) {
        return saveVerifiedProcedure(intentKey, goalIntent, description, appPackage, initialState, actions, successCondition, appVersion, true);
    }

    public synchronized boolean saveVerifiedProcedure(String intentKey, String goalIntent, String description,
                                                      String appPackage, String initialState, JSONArray actions,
                                                      String successCondition, String appVersion, boolean isPersonal) {
        if (intentKey == null || actions == null || actions.length() == 0) return false;
        try {
            JSONObject obj = new JSONObject();
            obj.put("intent_key", intentKey);
            obj.put("goal_intent", goalIntent != null ? goalIntent.toLowerCase().trim() : intentKey);
            obj.put("description", description != null ? description : intentKey);
            obj.put("app_package", appPackage);
            obj.put("initial_state", initialState);
            obj.put("action_sequence", actions);
            obj.put("actions", actions);
            obj.put("success_condition", successCondition);
            obj.put("app_version", appVersion);
            obj.put("success_count", 1);
            mProcedures.put(intentKey, obj);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    public synchronized int getSavedProceduresCount() {
        return mProcedures.size();
    }

    public synchronized JSONArray getAllProcedures() {
        JSONArray arr = new JSONArray();
        for (JSONObject p : mProcedures.values()) {
            arr.put(p);
        }
        return arr;
    }

    public synchronized long getDatabaseSizeBytes() {
        return 1024L * 512;
    }

    public synchronized void resetProcedures() {
        mProcedures.clear();
    }

    public synchronized void incrementStat(String metric, int amount) {
        if (metric == null) return;
        long prev = mStats.containsKey(metric) ? mStats.get(metric) : 0L;
        mStats.put(metric, prev + amount);
    }

    public synchronized JSONObject getAllStats() {
        JSONObject out = new JSONObject();
        try {
            for (Map.Entry<String, Long> e : mStats.entrySet()) {
                out.put(e.getKey(), e.getValue());
            }
        } catch (Exception ignored) {}
        return out;
    }
}
