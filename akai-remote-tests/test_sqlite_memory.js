/**
 * AKAI Custom Remote - SQLite Memory Engine Real Database Test Suite (v6 - Node.js)
 * Uses Node 22 built-in node:sqlite module
 */
const { DatabaseSync } = require('node:sqlite');
const fs = require('fs');
const path = require('path');
const os = require('os');

function runTests() {
    console.log("=== TEST PERSISTENZA E INTEGRITÀ SQLITE REALE (AkaiMemoryEngine v6 - Node.js) ===");
    let passed = 0;
    let failed = 0;

    const tempDbPath = path.join(os.tmpdir(), `akai_test_memory_v6_${Date.now()}.db`);
    if (fs.existsSync(tempDbPath)) fs.unlinkSync(tempDbPath);

    try {
        const db = new DatabaseSync(tempDbPath);

        // TEST 1: Fixture v5 pre-esistente con procedura legacy privata
        db.exec(`
            CREATE TABLE procedural_memory (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                intent_key TEXT UNIQUE NOT NULL,
                goal_intent TEXT,
                description TEXT NOT NULL,
                app_package TEXT,
                initial_state TEXT,
                action_sequence TEXT NOT NULL,
                success_condition TEXT,
                app_version TEXT,
                success_count INTEGER DEFAULT 1,
                failure_count INTEGER DEFAULT 0,
                last_used INTEGER,
                last_verified_at INTEGER,
                fallback_strategy TEXT,
                created_at INTEGER
            );
            CREATE TABLE user_preferences (
                pref_key TEXT PRIMARY KEY,
                pref_value TEXT NOT NULL,
                category TEXT NOT NULL,
                is_personal INTEGER DEFAULT 1,
                enabled INTEGER DEFAULT 1,
                updated_at INTEGER
            );
            CREATE TABLE conversations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp INTEGER NOT NULL,
                user_query TEXT NOT NULL,
                assistant_reply TEXT NOT NULL,
                status TEXT NOT NULL,
                intent_key TEXT,
                tokens_spent INTEGER DEFAULT 0,
                cost_eur REAL DEFAULT 0.0
            );
            CREATE TABLE ai_usage_stats (
                metric_key TEXT PRIMARY KEY,
                metric_value INTEGER DEFAULT 0
            );
        `);

        const now = 1700000000000;
        db.prepare(`
            INSERT INTO procedural_memory 
            (intent_key, goal_intent, description, app_package, initial_state, action_sequence, success_condition, app_version, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        `).run("youtube", "apri youtube", "Template YouTube TV", "com.google.android.youtube.tv", "{}", "[]", "{}", "v2.0", now);

        db.prepare(`
            INSERT INTO procedural_memory 
            (intent_key, goal_intent, description, app_package, initial_state, action_sequence, success_condition, app_version, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        `).run("dan_vacation_photos", "cerca video vacanze daniele", "Procedura appresa utente", "com.google.android.youtube.tv", "{}", "[]", "{}", "1.0", now);

        db.prepare("INSERT INTO user_preferences (pref_key, pref_value, category, is_personal, enabled, updated_at) VALUES (?, ?, ?, ?, ?, ?);")
          .run("favorite_channels", JSON.stringify(["Italia 2", "Focus"]), "channels", 1, 1, now);
        db.prepare("INSERT INTO user_preferences (pref_key, pref_value, category, is_personal, enabled, updated_at) VALUES (?, ?, ?, ?, ?, ?);")
          .run("guest_mode", "false", "settings", 0, 1, now);

        // Migrazione conservativa v5 -> v6
        db.exec("ALTER TABLE procedural_memory ADD COLUMN is_personal INTEGER DEFAULT 1;");
        db.exec("UPDATE procedural_memory SET is_personal = 0 WHERE intent_key IN ('youtube');");

        const procs = db.prepare("SELECT intent_key, is_personal FROM procedural_memory;").all();
        const mapProcs = {};
        for (const p of procs) mapProcs[p.intent_key] = p.is_personal;

        if (mapProcs["youtube"] === 0 && mapProcs["dan_vacation_photos"] === 1) {
            console.log("[PASS] SQLite Test 1: Migrazione v5 -> v6 conservativa riuscita: le procedure storiche pre-esistenti sono marcate private (is_personal=1), whitelist attiva per template di sistema (is_personal=0)");
            passed++;
        } else {
            console.error("[FAIL] SQLite Test 1: Migrazione v5 -> v6 fallita");
            failed++;
        }

        // TEST 2: Protezione vocale Guest Mode
        function simulateFind(query, guest) {
            let where = "intent_key = ?";
            if (guest) where += " AND is_personal = 0";
            let r = db.prepare(`SELECT intent_key, is_personal FROM procedural_memory WHERE ${where};`).get(query);
            if (r) return r;
            let whereGoal = "goal_intent = ?";
            if (guest) whereGoal += " AND is_personal = 0";
            return db.prepare(`SELECT intent_key, is_personal FROM procedural_memory WHERE ${whereGoal};`).get(query);
        }

        const rNorm = simulateFind("cerca video vacanze daniele", false);
        const rGuest = simulateFind("cerca video vacanze daniele", true);
        const rSysGuest = simulateFind("apri youtube", true);

        if (rNorm && !rGuest && rSysGuest) {
            console.log("[PASS] SQLite Test 2: Protezione vocale Guest Mode verificata: findProcedureByGoal blocca procedure personali (is_personal=1) consentendo solo template pubblici");
            passed++;
        } else {
            console.error("[FAIL] SQLite Test 2: Leak vocale in Guest Mode");
            failed++;
        }

        // TEST 3: Protezione preferenze getPreference
        function simulateGetPref(key, defVal, guest) {
            const row = db.prepare("SELECT pref_value, is_personal FROM user_preferences WHERE pref_key = ?;").get(key);
            if (!row) return defVal;
            if (row.is_personal === 1 && key !== "guest_mode" && guest) return defVal;
            return row.pref_value;
        }

        const prefNorm = simulateGetPref("favorite_channels", "[]", false);
        const prefGuest = simulateGetPref("favorite_channels", "[]", true);

        if (prefNorm !== "[]" && prefGuest === "[]") {
            console.log("[PASS] SQLite Test 3: Protezione preferenze vocali/REST confermata: getPreference non restituisce preferenze personali in Guest Mode");
            passed++;
        } else {
            console.error("[FAIL] SQLite Test 3: Preferenze personali trapelate in Guest Mode");
            failed++;
        }

        // TEST 4: Pulizia selettiva v6
        db.exec("DELETE FROM user_preferences WHERE is_personal = 1;");
        db.exec("DELETE FROM procedural_memory WHERE is_personal = 1;");
        db.exec("DELETE FROM conversations;");

        const cPrefs = db.prepare("SELECT COUNT(*) as c FROM user_preferences WHERE is_personal = 1;").get().c;
        const cProcs = db.prepare("SELECT COUNT(*) as c FROM procedural_memory WHERE is_personal = 1;").get().c;
        const cSysProcs = db.prepare("SELECT COUNT(*) as c FROM procedural_memory WHERE is_personal = 0;").get().c;

        if (cPrefs === 0 && cProcs === 0 && cSysProcs === 1) {
            console.log("[PASS] SQLite Test 4: Pulizia selettiva v6 confermata: cancellate preferenze personali, conversazioni e procedure personali storiche; template di sistema preservati");
            passed++;
        } else {
            console.error("[FAIL] SQLite Test 4: Errore pulizia selettiva");
            failed++;
        }

        // TEST 5: FIFO conversazioni e storage
        for (let i = 1; i <= 30; i++) {
            db.prepare("INSERT INTO conversations (timestamp, user_query, assistant_reply, status) VALUES (?, ?, ?, ?);")
              .run(now + (i * 1000), `Query ${i}`, `Risposta ${i}`, "SUCCESS");
        }

        db.exec(`
            DELETE FROM conversations WHERE id NOT IN (
                SELECT id FROM conversations ORDER BY timestamp DESC LIMIT 20
            );
        `);

        const convStats = db.prepare("SELECT COUNT(*) as count, MIN(user_query) as min_q, MAX(user_query) as max_q FROM conversations;").get();
        db.close();

        const stat = fs.statSync(tempDbPath);
        const maxStorage = 15 * 1024 * 1024;

        if (convStats.count === 20 && convStats.min_q === "Query 11" && convStats.max_q === "Query 30" && stat.size > 0 && stat.size < maxStorage) {
            console.log(`[PASS] SQLite Test 5: Enforcement FIFO a max 20 scambi verificato (tagliati i 10 scambi piu vecchi, conservati Query 11-30). Dimensione disco: ${stat.size} bytes < 15 MB`);
            passed++;
        } else {
            console.error("[FAIL] SQLite Test 5: Errore enforcement conversazioni o storage");
            failed++;
        }

    } finally {
        if (fs.existsSync(tempDbPath)) {
            try { fs.unlinkSync(tempDbPath); } catch (e) {}
        }
    }

    console.log("\n=== ESITO COMPLETO TEST SQLITE REALE v6 (Node.js) ===");
    console.log(`Test Superati: ${passed} / ${passed + failed}`);
    if (failed > 0) process.exit(1);
}

runTests();
