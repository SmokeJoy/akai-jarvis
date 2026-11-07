package it.akai.customremote.ai;

import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.Locale;

/**
 * AkaiMemoryEngine: Gestore SQLite a doppio livello su TV AKAI (Schema v2).
 * 
 * Livello 1: procedural_memory - Procedure tecniche verificate con:
 *            - intent_key (identificativo univoco)
 *            - goal_intent (obiettivo espresso in linguaggio naturale)
 *            - initial_state (contesto iniziale atteso: es. pacchetto in primo piano)
 *            - action_sequence (sequenza ordinata di azioni)
 *            - success_condition (condizione verificabile di completamento)
 *            - app_version, success_count, failure_count, last_verified_at
 *            - fallback_strategy (strategia alternativa in caso di insuccesso)
 * 
 * Livello 2: user_preferences - Memoria abitudini personali (facoltativa, cancellabile,
 *            con supporto Guest Mode e separazione netta dai dati tecnici).
 * 
 * Livello 3: ai_usage_stats - Statistiche di utilizzo, token e cost tracking.
 */
public class AkaiMemoryEngine extends SQLiteOpenHelper {
    private static final String TAG = "AKAI_MemoryEngine";
    private static final String DB_NAME = "akai_memory.db";
    private static final int DB_VERSION = 5;

    private static AkaiMemoryEngine sInstance = null;

    // Tabella procedural_memory
    public static final String TABLE_PROCEDURES = "procedural_memory";
    public static final String COL_ID = "id";
    public static final String COL_INTENT_KEY = "intent_key";
    public static final String COL_GOAL_INTENT = "goal_intent";
    public static final String COL_DESCRIPTION = "description";
    public static final String COL_APP_PACKAGE = "app_package";
    public static final String COL_INITIAL_STATE = "initial_state";
    public static final String COL_ACTION_SEQUENCE = "action_sequence";
    public static final String COL_SUCCESS_CONDITION = "success_condition";
    public static final String COL_APP_VERSION = "app_version";
    public static final String COL_SUCCESS_COUNT = "success_count";
    public static final String COL_FAILURE_COUNT = "failure_count";
    public static final String COL_LAST_USED = "last_used";
    public static final String COL_LAST_VERIFIED = "last_verified_at";
    public static final String COL_FALLBACK_STRATEGY = "fallback_strategy";
    public static final String COL_CREATED_AT = "created_at";

    // Tabella user_preferences
    public static final String TABLE_PREFERENCES = "user_preferences";
    public static final String COL_PREF_KEY = "pref_key";
    public static final String COL_PREF_VAL = "pref_value";
    public static final String COL_CATEGORY = "category";
    public static final String COL_IS_PERSONAL = "is_personal";
    public static final String COL_ENABLED = "enabled";
    public static final String COL_UPDATED_AT = "updated_at";

    // Tabella conversations (Fase 15: Memoria conversazionale con limite max 20 scambi)
    public static final String TABLE_CONVERSATIONS = "conversations";
    public static final String COL_CONV_ID = "id";
    public static final String COL_CONV_TIMESTAMP = "timestamp";
    public static final String COL_CONV_QUERY = "user_query";
    public static final String COL_CONV_REPLY = "assistant_reply";
    public static final String COL_CONV_STATUS = "status";
    public static final String COL_CONV_INTENT = "intent_key";
    public static final String COL_CONV_TOKENS = "tokens_spent";
    public static final String COL_CONV_COST = "cost_eur";

    // Tabella ai_usage_stats
    public static final String TABLE_STATS = "ai_usage_stats";
    public static final String COL_METRIC_KEY = "metric_key";
    public static final String COL_METRIC_VAL = "metric_value";

    public static synchronized AkaiMemoryEngine getInstance(Context context) {
        if (sInstance == null) {
            sInstance = new AkaiMemoryEngine(context.getApplicationContext());
        }
        return sInstance;
    }

    private AkaiMemoryEngine(Context context) {
        super(context, DB_NAME, null, DB_VERSION);
    }

    @Override
    public void onCreate(SQLiteDatabase db) {
        Log.i(TAG, "Creating AKAI Memory SQLite database schemas v2...");

        // 1. procedural_memory (v2)
        String sqlProcedures = "CREATE TABLE " + TABLE_PROCEDURES + " (" +
                COL_ID + " INTEGER PRIMARY KEY AUTOINCREMENT, " +
                COL_INTENT_KEY + " TEXT UNIQUE NOT NULL, " +
                COL_GOAL_INTENT + " TEXT, " +
                COL_DESCRIPTION + " TEXT NOT NULL, " +
                COL_APP_PACKAGE + " TEXT, " +
                COL_INITIAL_STATE + " TEXT, " +
                COL_ACTION_SEQUENCE + " TEXT NOT NULL, " +
                COL_SUCCESS_CONDITION + " TEXT, " +
                COL_APP_VERSION + " TEXT, " +
                COL_SUCCESS_COUNT + " INTEGER DEFAULT 1, " +
                COL_FAILURE_COUNT + " INTEGER DEFAULT 0, " +
                COL_LAST_USED + " INTEGER, " +
                COL_LAST_VERIFIED + " INTEGER, " +
                COL_FALLBACK_STRATEGY + " TEXT, " +
                COL_CREATED_AT + " INTEGER);";
        db.execSQL(sqlProcedures);

        // 2. user_preferences (v2)
        String sqlPrefs = "CREATE TABLE " + TABLE_PREFERENCES + " (" +
                COL_PREF_KEY + " TEXT PRIMARY KEY, " +
                COL_PREF_VAL + " TEXT NOT NULL, " +
                COL_CATEGORY + " TEXT NOT NULL, " +
                COL_IS_PERSONAL + " INTEGER DEFAULT 1, " +
                COL_ENABLED + " INTEGER DEFAULT 1, " +
                COL_UPDATED_AT + " INTEGER);";
        db.execSQL(sqlPrefs);

        // 3. conversations (Fase 15)
        String sqlConversations = "CREATE TABLE " + TABLE_CONVERSATIONS + " (" +
                COL_CONV_ID + " INTEGER PRIMARY KEY AUTOINCREMENT, " +
                COL_CONV_TIMESTAMP + " INTEGER NOT NULL, " +
                COL_CONV_QUERY + " TEXT NOT NULL, " +
                COL_CONV_REPLY + " TEXT NOT NULL, " +
                COL_CONV_STATUS + " TEXT NOT NULL, " +
                COL_CONV_INTENT + " TEXT, " +
                COL_CONV_TOKENS + " INTEGER DEFAULT 0, " +
                COL_CONV_COST + " REAL DEFAULT 0.0);";
        db.execSQL(sqlConversations);

        // 4. ai_usage_stats
        String sqlStats = "CREATE TABLE " + TABLE_STATS + " (" +
                COL_METRIC_KEY + " TEXT PRIMARY KEY, " +
                COL_METRIC_VAL + " INTEGER DEFAULT 0);";
        db.execSQL(sqlStats);

        // Pre-popolamento iniziale
        seedInitialData(db);
    }

    @Override
    public void onUpgrade(SQLiteDatabase db, int oldVersion, int newVersion) {
        Log.i(TAG, "Upgrading AKAI Memory DB from v" + oldVersion + " to v" + newVersion);
        if (oldVersion < 2) {
            try {
                db.execSQL("ALTER TABLE " + TABLE_PROCEDURES + " ADD COLUMN " + COL_GOAL_INTENT + " TEXT;");
                db.execSQL("ALTER TABLE " + TABLE_PROCEDURES + " ADD COLUMN " + COL_INITIAL_STATE + " TEXT;");
                db.execSQL("ALTER TABLE " + TABLE_PROCEDURES + " ADD COLUMN " + COL_SUCCESS_CONDITION + " TEXT;");
                db.execSQL("ALTER TABLE " + TABLE_PROCEDURES + " ADD COLUMN " + COL_APP_VERSION + " TEXT;");
                db.execSQL("ALTER TABLE " + TABLE_PROCEDURES + " ADD COLUMN " + COL_FAILURE_COUNT + " INTEGER DEFAULT 0;");
                db.execSQL("ALTER TABLE " + TABLE_PROCEDURES + " ADD COLUMN " + COL_LAST_VERIFIED + " INTEGER;");
                db.execSQL("ALTER TABLE " + TABLE_PROCEDURES + " ADD COLUMN " + COL_FALLBACK_STRATEGY + " TEXT;");

                db.execSQL("ALTER TABLE " + TABLE_PREFERENCES + " ADD COLUMN " + COL_IS_PERSONAL + " INTEGER DEFAULT 1;");
                db.execSQL("ALTER TABLE " + TABLE_PREFERENCES + " ADD COLUMN " + COL_ENABLED + " INTEGER DEFAULT 1;");
            } catch (Exception e) {
                Log.w(TAG, "Schema upgrade migration notice: " + e.getMessage());
            }
        }
        if (oldVersion < 4) {
            try {
                seedProceduralTemplates(db, System.currentTimeMillis());
            } catch (Exception e) {
                Log.w(TAG, "Schema upgrade v4 notice: " + e.getMessage());
            }
        }
        if (oldVersion < 5) {
            try {
                String sqlConv = "CREATE TABLE IF NOT EXISTS " + TABLE_CONVERSATIONS + " (" +
                        COL_CONV_ID + " INTEGER PRIMARY KEY AUTOINCREMENT, " +
                        COL_CONV_TIMESTAMP + " INTEGER NOT NULL, " +
                        COL_CONV_QUERY + " TEXT NOT NULL, " +
                        COL_CONV_REPLY + " TEXT NOT NULL, " +
                        COL_CONV_STATUS + " TEXT NOT NULL, " +
                        COL_CONV_INTENT + " TEXT, " +
                        COL_CONV_TOKENS + " INTEGER DEFAULT 0, " +
                        COL_CONV_COST + " REAL DEFAULT 0.0);";
                db.execSQL(sqlConv);
                seedProceduralTemplates(db, System.currentTimeMillis());
            } catch (Exception e) {
                Log.w(TAG, "Schema upgrade v5 notice: " + e.getMessage());
            }
        }
    }

    private void seedInitialData(SQLiteDatabase db) {
        long now = System.currentTimeMillis();
        try {
            seedProceduralTemplates(db, now);

            // Preferences
            insertPref(db, "favorite_channels", "[\"Italia 2\", \"Rai 1\", \"Canale 5\", \"Focus\", \"20 Mediaset\"]", "channels", 1, now);
            insertPref(db, "favorite_genres", "[\"Fantascienza\", \"Documentari\", \"Serie TV\", \"Animazione\", \"Calcio\"]", "genres", 1, now);
            insertPref(db, "favorite_apps", "[\"Mediaset Infinity\", \"RaiPlay\", \"YouTube\", \"Disney+\"]", "apps", 1, now);
            insertPref(db, "guest_mode", "false", "settings", 0, now);
            insertPref(db, "budget_max_session_usd", "0.20", "safety", 0, now);
            insertPref(db, "budget_max_total_usd", "2.00", "safety", 0, now);

            // Stats
            insertStat(db, "local_executions_zero_token", 16);
            insertStat(db, "cloud_ai_calls", 0);
            insertStat(db, "prompt_tokens", 0);
            insertStat(db, "completion_tokens", 0);
        } catch (Exception e) {
            Log.e(TAG, "Error seeding memory: " + e.getMessage());
        }
    }

    private void seedProceduralTemplates(SQLiteDatabase db, long now) {
        try {
            // Template YouTube TV (semplice apertura package verificata da pkg_is)
            JSONArray ytActions = new JSONArray();
            ytActions.put(new JSONObject().put("type", "launch_app").put("pkg", "com.google.android.youtube.tv").put("name", "YouTube TV"));
            ContentValues cvYt = new ContentValues();
            cvYt.put(COL_INTENT_KEY, "youtube");
            cvYt.put(COL_GOAL_INTENT, "apri youtube");
            cvYt.put(COL_DESCRIPTION, "Template apertura YouTube TV");
            cvYt.put(COL_APP_PACKAGE, "com.google.android.youtube.tv");
            cvYt.put(COL_INITIAL_STATE, "{\"pkg\":\"any\"}");
            cvYt.put(COL_ACTION_SEQUENCE, ytActions.toString());
            cvYt.put(COL_SUCCESS_CONDITION, "{\"type\":\"pkg_is\",\"value\":\"com.google.android.youtube.tv\"}");
            cvYt.put(COL_APP_VERSION, "v2.0");
            cvYt.put(COL_SUCCESS_COUNT, 0);
            cvYt.put(COL_FAILURE_COUNT, 0);
            cvYt.put(COL_LAST_USED, 0);
            cvYt.put(COL_LAST_VERIFIED, 0); // 0 = mai verificato a runtime
            cvYt.put(COL_CREATED_AT, now);
            db.insertWithOnConflict(TABLE_PROCEDURES, null, cvYt, SQLiteDatabase.CONFLICT_IGNORE);

            Log.i(TAG, "seedProceduralTemplates: default templates inserted with CONFLICT_IGNORE.");
        } catch (Exception e) {
            Log.w(TAG, "Error seeding procedural templates: " + e.getMessage());
        }
    }

    private void insertPref(SQLiteDatabase db, String key, String val, String cat, int isPersonal, long time) {
        ContentValues cv = new ContentValues();
        cv.put(COL_PREF_KEY, key);
        cv.put(COL_PREF_VAL, val);
        cv.put(COL_CATEGORY, cat);
        cv.put(COL_IS_PERSONAL, isPersonal);
        cv.put(COL_ENABLED, 1);
        cv.put(COL_UPDATED_AT, time);
        db.insertWithOnConflict(TABLE_PREFERENCES, null, cv, SQLiteDatabase.CONFLICT_REPLACE);
    }

    private void insertStat(SQLiteDatabase db, String key, int val) {
        ContentValues cv = new ContentValues();
        cv.put(COL_METRIC_KEY, key);
        cv.put(COL_METRIC_VAL, val);
        db.insertWithOnConflict(TABLE_STATS, null, cv, SQLiteDatabase.CONFLICT_REPLACE);
    }

    // =========================================================================
    // RICERCA & MATCH PROCEDURALE DINAMICO
    // =========================================================================

    public synchronized JSONObject findProcedureByGoal(String rawQuery) {
        if (rawQuery == null || rawQuery.trim().isEmpty()) return null;
        String clean = rawQuery.trim().toLowerCase(Locale.ITALIAN).replaceAll("[^a-z0-9\\s]", " ").replaceAll("\\s+", " ").trim();

        SQLiteDatabase db = getReadableDatabase();
        Cursor c = null;

        try {
            // Check 1: Match esatto su intent_key
            c = db.query(TABLE_PROCEDURES, null, COL_INTENT_KEY + "=?", new String[]{clean}, null, null, null);
            if (c != null && c.moveToFirst()) {
                return parseProcedureCursor(c);
            }
            if (c != null) c.close();

            // Check 2: Match su goal_intent
            c = db.query(TABLE_PROCEDURES, null, COL_GOAL_INTENT + "=?", new String[]{clean}, null, null, null);
            if (c != null && c.moveToFirst()) {
                return parseProcedureCursor(c);
            }
            if (c != null) c.close();

            // Check 3: Match se la query contiene l'intent_key memorizzato (es. "metti italia 2" contiene "italia 2" o "italia2")
            String cleanNoSpace = clean.replaceAll("\\s+", "");
            Cursor allProcs = db.query(TABLE_PROCEDURES, null, null, null, null, null, COL_SUCCESS_COUNT + " DESC");
            if (allProcs != null && allProcs.moveToFirst()) {
                do {
                    String ik = allProcs.getString(allProcs.getColumnIndex(COL_INTENT_KEY));
                    String gi = allProcs.getString(allProcs.getColumnIndex(COL_GOAL_INTENT));
                    if (ik != null) {
                        String ikClean = ik.toLowerCase(Locale.ITALIAN).replaceAll("[_\\s]+", " ").trim();
                        String ikNoSpace = ik.toLowerCase(Locale.ITALIAN).replaceAll("[_\\s]+", "");
                        if (clean.contains(ikClean) || (!ikNoSpace.isEmpty() && cleanNoSpace.contains(ikNoSpace))) {
                            JSONObject res = parseProcedureCursor(allProcs);
                            allProcs.close();
                            return res;
                        }
                    }
                    if (gi != null) {
                        String giClean = gi.toLowerCase(Locale.ITALIAN).replaceAll("[_\\s]+", " ").trim();
                        String giNoSpace = gi.toLowerCase(Locale.ITALIAN).replaceAll("[_\\s]+", "");
                        if (clean.contains(giClean) || giClean.contains(clean) || (!giNoSpace.isEmpty() && cleanNoSpace.contains(giNoSpace))) {
                            JSONObject res = parseProcedureCursor(allProcs);
                            allProcs.close();
                            return res;
                        }
                    }
                } while (allProcs.moveToNext());
                allProcs.close();
            }
        } catch (Exception e) {
            Log.e(TAG, "Error in findProcedureByGoal: " + e.getMessage());
        } finally {
            if (c != null) c.close();
        }
        return null;
    }

    public synchronized JSONObject getProcedure(String intentKey) {
        if (intentKey == null) return null;
        SQLiteDatabase db = getReadableDatabase();
        Cursor c = null;
        try {
            c = db.query(TABLE_PROCEDURES, null, COL_INTENT_KEY + "=?", new String[]{intentKey}, null, null, null);
            if (c != null && c.moveToFirst()) {
                return parseProcedureCursor(c);
            }
        } catch (Exception e) {
            Log.e(TAG, "Error fetching procedure " + intentKey + ": " + e.getMessage());
        } finally {
            if (c != null) c.close();
        }
        return null;
    }

    private JSONObject parseProcedureCursor(Cursor c) throws Exception {
        JSONObject obj = new JSONObject();
        obj.put("id", c.getInt(c.getColumnIndex(COL_ID)));
        obj.put("intent_key", c.getString(c.getColumnIndex(COL_INTENT_KEY)));
        obj.put("goal_intent", c.getString(c.getColumnIndex(COL_GOAL_INTENT)));
        obj.put("description", c.getString(c.getColumnIndex(COL_DESCRIPTION)));
        obj.put("app_package", c.getString(c.getColumnIndex(COL_APP_PACKAGE)));
        obj.put("initial_state", c.getString(c.getColumnIndex(COL_INITIAL_STATE)));
        obj.put("action_sequence", new JSONArray(c.getString(c.getColumnIndex(COL_ACTION_SEQUENCE))));
        obj.put("success_condition", c.getString(c.getColumnIndex(COL_SUCCESS_CONDITION)));
        obj.put("app_version", c.getString(c.getColumnIndex(COL_APP_VERSION)));
        obj.put("success_count", c.getInt(c.getColumnIndex(COL_SUCCESS_COUNT)));
        obj.put("failure_count", c.getInt(c.getColumnIndex(COL_FAILURE_COUNT)));
        obj.put("last_used", c.getLong(c.getColumnIndex(COL_LAST_USED)));
        obj.put("last_verified_at", c.getLong(c.getColumnIndex(COL_LAST_VERIFIED)));
        obj.put("fallback_strategy", c.getString(c.getColumnIndex(COL_FALLBACK_STRATEGY)));
        return obj;
    }

    public synchronized void recordProcedureSuccess(String intentKey) {
        if (intentKey == null) return;
        SQLiteDatabase db = getWritableDatabase();
        try {
            db.execSQL("UPDATE " + TABLE_PROCEDURES + " SET " +
                    COL_SUCCESS_COUNT + " = " + COL_SUCCESS_COUNT + " + 1, " +
                    COL_LAST_USED + " = ?, " +
                    COL_LAST_VERIFIED + " = ? WHERE " + COL_INTENT_KEY + " = ?",
                    new Object[]{System.currentTimeMillis(), System.currentTimeMillis(), intentKey});
            incrementStat("local_executions_zero_token", 1);
        } catch (Exception e) {
            Log.e(TAG, "Error recording procedure success: " + e.getMessage());
        }
    }

    public synchronized void recordProcedureFailure(String intentKey) {
        if (intentKey == null) return;
        SQLiteDatabase db = getWritableDatabase();
        try {
            db.execSQL("UPDATE " + TABLE_PROCEDURES + " SET " +
                    COL_FAILURE_COUNT + " = " + COL_FAILURE_COUNT + " + 1 WHERE " + COL_INTENT_KEY + " = ?",
                    new Object[]{intentKey});
        } catch (Exception e) {
            Log.e(TAG, "Error recording procedure failure: " + e.getMessage());
        }
    }

    public synchronized boolean saveVerifiedProcedure(String intentKey, String goalIntent, String description,
                                                       String appPackage, String initialState, JSONArray actions,
                                                       String successCondition, String appVersion) {
        if (intentKey == null || actions == null || actions.length() == 0) return false;
        SQLiteDatabase db = getWritableDatabase();
        long now = System.currentTimeMillis();
        try {
            ContentValues cv = new ContentValues();
            cv.put(COL_INTENT_KEY, intentKey);
            cv.put(COL_GOAL_INTENT, goalIntent != null ? goalIntent.toLowerCase().trim() : intentKey);
            cv.put(COL_DESCRIPTION, description != null ? description : intentKey);
            cv.put(COL_APP_PACKAGE, appPackage);
            cv.put(COL_INITIAL_STATE, initialState != null ? initialState : "{\"pkg\":\"any\"}");
            cv.put(COL_ACTION_SEQUENCE, actions.toString());
            cv.put(COL_SUCCESS_CONDITION, successCondition != null ? successCondition : "{\"type\":\"text_exists\"}");
            cv.put(COL_APP_VERSION, appVersion != null ? appVersion : "1.0");
            cv.put(COL_SUCCESS_COUNT, 1);
            cv.put(COL_FAILURE_COUNT, 0);
            cv.put(COL_LAST_USED, now);
            cv.put(COL_LAST_VERIFIED, now);
            cv.put(COL_CREATED_AT, now);

            long row = db.insertWithOnConflict(TABLE_PROCEDURES, null, cv, SQLiteDatabase.CONFLICT_REPLACE);
            Log.i(TAG, "New procedure saved to SQLite: " + intentKey + " (row=" + row + ")");
            return row != -1;
        } catch (Exception e) {
            Log.e(TAG, "Error saving verified procedure " + intentKey + ": " + e.getMessage());
            return false;
        }
    }

    public synchronized JSONArray getAllProcedures() {
        JSONArray list = new JSONArray();
        SQLiteDatabase db = getReadableDatabase();
        Cursor c = null;
        try {
            c = db.query(TABLE_PROCEDURES, null, null, null, null, null, COL_LAST_USED + " DESC");
            if (c != null && c.moveToFirst()) {
                do {
                    list.put(parseProcedureCursor(c));
                } while (c.moveToNext());
            }
        } catch (Exception e) {
            Log.e(TAG, "Error listing procedures: " + e.getMessage());
        } finally {
            if (c != null) c.close();
        }
        return list;
    }

    public synchronized boolean deleteProcedure(String intentKey) {
        if (intentKey == null) return false;
        SQLiteDatabase db = getWritableDatabase();
        try {
            int rows = db.delete(TABLE_PROCEDURES, COL_INTENT_KEY + "=?", new String[]{intentKey});
            return rows > 0;
        } catch (Exception e) {
            Log.e(TAG, "Error deleting procedure " + intentKey + ": " + e.getMessage());
            return false;
        }
    }

    public synchronized void resetProcedures() {
        SQLiteDatabase db = getWritableDatabase();
        try {
            db.delete(TABLE_PROCEDURES, null, null);
            seedProceduralTemplates(db, System.currentTimeMillis());
            Log.i(TAG, "Procedural memory reset to default templates. Preferences and statistics preserved.");
        } catch (Exception e) {
            Log.e(TAG, "Error resetting procedures: " + e.getMessage());
        }
    }

    // =========================================================================
    // MEMORIA ABITUDINI & PREFERENZE (GUEST MODE & SEPARAZIONE PERSONALE)
    // =========================================================================

    public synchronized boolean isGuestMode() {
        String val = getPreference("guest_mode", "false");
        return "true".equalsIgnoreCase(val);
    }

    public synchronized void setGuestMode(boolean enabled) {
        setPreference("guest_mode", enabled ? "true" : "false", "settings", 0);
    }

    public synchronized JSONObject getAllPreferences() {
        JSONObject obj = new JSONObject();
        if (isGuestMode()) {
            return obj; // In modalità ospite, nessuna preferenza personale è esposta
        }

        SQLiteDatabase db = getReadableDatabase();
        Cursor c = null;
        try {
            c = db.query(TABLE_PREFERENCES, null, COL_ENABLED + "=1", null, null, null, null);
            if (c != null && c.moveToFirst()) {
                do {
                    String key = c.getString(c.getColumnIndex(COL_PREF_KEY));
                    String val = c.getString(c.getColumnIndex(COL_PREF_VAL));
                    obj.put(key, val);
                } while (c.moveToNext());
            }
        } catch (Exception e) {
            Log.e(TAG, "Error reading preferences: " + e.getMessage());
        } finally {
            if (c != null) c.close();
        }
        return obj;
    }

    public synchronized String getPreference(String key, String defaultValue) {
        if (key == null) return defaultValue;
        SQLiteDatabase db = getReadableDatabase();
        Cursor c = null;
        try {
            c = db.query(TABLE_PREFERENCES, new String[]{COL_PREF_VAL}, COL_PREF_KEY + "=?", new String[]{key}, null, null, null);
            if (c != null && c.moveToFirst()) {
                return c.getString(0);
            }
        } catch (Exception e) {
            Log.e(TAG, "Error getting pref " + key + ": " + e.getMessage());
        } finally {
            if (c != null) c.close();
        }
        return defaultValue;
    }

    public synchronized boolean setPreference(String key, String value, String category, int isPersonal) {
        if (key == null || value == null) return false;
        if (isPersonal == 1 && isGuestMode()) {
            Log.i(TAG, "Guest mode active: personal preference not persisted: " + key);
            return false;
        }

        SQLiteDatabase db = getWritableDatabase();
        try {
            ContentValues cv = new ContentValues();
            cv.put(COL_PREF_KEY, key);
            cv.put(COL_PREF_VAL, value);
            cv.put(COL_CATEGORY, category != null ? category : "custom");
            cv.put(COL_IS_PERSONAL, isPersonal);
            cv.put(COL_ENABLED, 1);
            cv.put(COL_UPDATED_AT, System.currentTimeMillis());
            long row = db.insertWithOnConflict(TABLE_PREFERENCES, null, cv, SQLiteDatabase.CONFLICT_REPLACE);
            return row != -1;
        } catch (Exception e) {
            Log.e(TAG, "Error setting pref " + key + ": " + e.getMessage());
            return false;
        }
    }

    public synchronized boolean deletePreference(String key) {
        if (key == null) return false;
        SQLiteDatabase db = getWritableDatabase();
        try {
            int rows = db.delete(TABLE_PREFERENCES, COL_PREF_KEY + "=?", new String[]{key});
            return rows > 0;
        } catch (Exception e) {
            Log.e(TAG, "Error deleting pref " + key + ": " + e.getMessage());
            return false;
        }
    }

    public synchronized void clearPersonalPreferencesOnly() {
        SQLiteDatabase db = getWritableDatabase();
        try {
            // Elimina i record contrassegnati come personali E l'intera cronologia conversazioni
            int delPrefs = db.delete(TABLE_PREFERENCES, COL_IS_PERSONAL + "=1", null);
            int delConv = db.delete(TABLE_CONVERSATIONS, null, null);
            Log.i(TAG, "Cleared " + delPrefs + " personal preferences and " + delConv + " conversation exchanges. Technical settings preserved.");
        } catch (Exception e) {
            Log.e(TAG, "Error clearing personal data: " + e.getMessage());
        }
    }

    // =========================================================================
    // METODI MEMORIA CONVERSAZIONALE & GESTIONE BUDGET 15 MB (FASE 15)
    // =========================================================================

    public static final long MAX_STORAGE_BYTES = 15 * 1024 * 1024L; // 15 Megabytes

    public synchronized void saveConversationExchange(String query, String reply, String status, String intentKey, int tokens, double costEur) {
        if (query == null || reply == null) return;
        if (isGuestMode()) {
            Log.d(TAG, "Guest mode active: exchange not recorded in memory.");
            return;
        }
        SQLiteDatabase db = getWritableDatabase();
        try {
            ContentValues cv = new ContentValues();
            cv.put(COL_CONV_TIMESTAMP, System.currentTimeMillis());
            cv.put(COL_CONV_QUERY, query);
            cv.put(COL_CONV_REPLY, reply);
            cv.put(COL_CONV_STATUS, status != null ? status : "UNKNOWN");
            cv.put(COL_CONV_INTENT, intentKey != null ? intentKey : "");
            cv.put(COL_CONV_TOKENS, tokens);
            cv.put(COL_CONV_COST, costEur);
            db.insert(TABLE_CONVERSATIONS, null, cv);

            // Mantieni rigorosamente al massimo gli ultimi 20 turni di conversazione
            db.execSQL("DELETE FROM " + TABLE_CONVERSATIONS + " WHERE " + COL_CONV_ID + " NOT IN (" +
                    "SELECT " + COL_CONV_ID + " FROM " + TABLE_CONVERSATIONS + " ORDER BY " + COL_CONV_TIMESTAMP + " DESC LIMIT 20);");

            // Controllo del limite di archiviazione 15 MB
            checkAndEnforceStorageBudget(db);
        } catch (Exception e) {
            Log.e(TAG, "Error saving conversation exchange: " + e.getMessage());
        }
    }

    public synchronized JSONArray getRecentConversations(int limit) {
        JSONArray arr = new JSONArray();
        if (isGuestMode()) {
            return arr; // Privacy: in Guest Mode nessuna cronologia precedente o personale è esposta
        }
        int max = (limit > 0 && limit <= 20) ? limit : 20;
        SQLiteDatabase db = getReadableDatabase();
        Cursor c = null;
        try {
            // Seleziona gli ultimi 'max' scambi in ordine cronologico (dal più vecchio al più recente)
            String sql = "SELECT * FROM (SELECT * FROM " + TABLE_CONVERSATIONS + " ORDER BY " + COL_CONV_TIMESTAMP + " DESC LIMIT " + max + ") ORDER BY " + COL_CONV_TIMESTAMP + " ASC";
            c = db.rawQuery(sql, null);
            if (c != null && c.moveToFirst()) {
                do {
                    JSONObject item = new JSONObject();
                    item.put("id", c.getLong(c.getColumnIndex(COL_CONV_ID)));
                    item.put("timestamp", c.getLong(c.getColumnIndex(COL_CONV_TIMESTAMP)));
                    item.put("user_query", c.getString(c.getColumnIndex(COL_CONV_QUERY)));
                    item.put("assistant_reply", c.getString(c.getColumnIndex(COL_CONV_REPLY)));
                    item.put("status", c.getString(c.getColumnIndex(COL_CONV_STATUS)));
                    item.put("intent_key", c.getString(c.getColumnIndex(COL_CONV_INTENT)));
                    item.put("tokens", c.getInt(c.getColumnIndex(COL_CONV_TOKENS)));
                    item.put("cost_eur", c.getDouble(c.getColumnIndex(COL_CONV_COST)));
                    arr.put(item);
                } while (c.moveToNext());
            }
        } catch (Exception e) {
            Log.e(TAG, "Error fetching recent conversations: " + e.getMessage());
        } finally {
            if (c != null) c.close();
        }
        return arr;
    }

    public synchronized long getDatabaseSizeBytes() {
        SQLiteDatabase db = getReadableDatabase();
        Cursor c = null;
        try {
            long pageCount = 0;
            long pageSize = 0;
            c = db.rawQuery("PRAGMA page_count;", null);
            if (c != null && c.moveToFirst()) {
                pageCount = c.getLong(0);
            }
            if (c != null) c.close();

            c = db.rawQuery("PRAGMA page_size;", null);
            if (c != null && c.moveToFirst()) {
                pageSize = c.getLong(0);
            }
            return pageCount * pageSize;
        } catch (Exception e) {
            Log.e(TAG, "Error calculating DB size: " + e.getMessage());
            return 0;
        } finally {
            if (c != null) c.close();
        }
    }

    private void checkAndEnforceStorageBudget(SQLiteDatabase db) {
        try {
            long size = getDatabaseSizeBytes();
            if (size > MAX_STORAGE_BYTES) {
                Log.w(TAG, "Storage budget exceeded (" + size + " > " + MAX_STORAGE_BYTES + " bytes). Pruning older data and running VACUUM...");
                // Elimina conversazioni più vecchie di 5 elementi se superato il limite
                db.execSQL("DELETE FROM " + TABLE_CONVERSATIONS + " WHERE " + COL_CONV_ID + " NOT IN (" +
                        "SELECT " + COL_CONV_ID + " FROM " + TABLE_CONVERSATIONS + " ORDER BY " + COL_CONV_TIMESTAMP + " DESC LIMIT 5);");
                db.execSQL("VACUUM;");
                Log.i(TAG, "VACUUM completed. New DB size: " + getDatabaseSizeBytes() + " bytes.");
            }
        } catch (Exception e) {
            Log.e(TAG, "Error enforcing storage budget: " + e.getMessage());
        }
    }

    // =========================================================================
    // METODI AI STATS
    // =========================================================================

    public synchronized void incrementStat(String metric, int amount) {
        if (metric == null || amount <= 0) return;
        SQLiteDatabase db = getWritableDatabase();
        try {
            db.execSQL("INSERT OR IGNORE INTO " + TABLE_STATS + " (" + COL_METRIC_KEY + ", " + COL_METRIC_VAL + ") VALUES (?, 0);", new Object[]{metric});
            db.execSQL("UPDATE " + TABLE_STATS + " SET " + COL_METRIC_VAL + " = " + COL_METRIC_VAL + " + ? WHERE " + COL_METRIC_KEY + " = ?;", new Object[]{amount, metric});
        } catch (Exception e) {
            Log.e(TAG, "Error incrementing stat " + metric + ": " + e.getMessage());
        }
    }

    public synchronized JSONObject getAllStats() {
        JSONObject obj = new JSONObject();
        SQLiteDatabase db = getReadableDatabase();
        Cursor c = null;
        try {
            c = db.query(TABLE_STATS, null, null, null, null, null, null);
            if (c != null && c.moveToFirst()) {
                do {
                    String key = c.getString(c.getColumnIndex(COL_METRIC_KEY));
                    int val = c.getInt(c.getColumnIndex(COL_METRIC_VAL));
                    obj.put(key, val);
                } while (c.moveToNext());
            }
        } catch (Exception e) {
            Log.e(TAG, "Error reading stats: " + e.getMessage());
        } finally {
            if (c != null) c.close();
        }
        return obj;
    }
}
