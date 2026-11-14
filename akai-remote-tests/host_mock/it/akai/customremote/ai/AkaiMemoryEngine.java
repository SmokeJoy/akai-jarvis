package it.akai.customremote.ai;

import android.content.Context;
import org.json.JSONArray;
import org.json.JSONObject;

public class AkaiMemoryEngine {
    private static AkaiMemoryEngine sInstance = new AkaiMemoryEngine();
    private boolean mGuestMode = false;

    public static synchronized AkaiMemoryEngine getInstance(Context context) {
        return sInstance;
    }

    public boolean isGuestMode() {
        return mGuestMode;
    }

    public void setGuestMode(boolean guestMode) {
        this.mGuestMode = guestMode;
    }

    public String getPreference(String key, String defValue) {
        return defValue;
    }

    public JSONArray getRecentConversations(int limit) {
        return new JSONArray();
    }

    public JSONObject findProcedureByGoal(String goal) {
        return null;
    }
}
