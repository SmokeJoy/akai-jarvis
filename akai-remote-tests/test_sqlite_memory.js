/**
 * AKAI Custom Remote - SQLite Memory Engine Real Database Test Suite (Node.js)
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

    const tempDbPath = path.join(os.tmpdir(), `akai_test_memory_${Date.now()}.db`);
    if (fs.existsSync(tempDbPath)) fs.unlinkSync(tempDbPath);

    try {
        const db = new DatabaseSync(tempDbPath);

        // TEST 1: Schema e migrazione v1 -> v6
        db.exec(`
            CREATE TABLE procedural_memory (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                intent_key TEXT UNIQUE NOT NULL,
                description TEXT NOT NULL,
                app_package TEXT,
                action_sequence TEXT NOT NULL,
                success_count INTEGER DEFAULT 1,
                last_used INTEGER,
                created_at INTEGER
            );
            CREATE TABLE user_preferences (
                pref_key TEXT PRIMARY KEY,
                pref_value TEXT NOT NULL,
                category TEXT NOT NULL,
                updated_at INTEGER
            );
            CREATE TABLE ai_usage_stats (
                metric_key TEXT PRIMARY KEY,
                metric_value INTEGER DEFAULT 0
            );
        `);

        // Migrazione v2
        db.exec("ALTER TABLE procedural_memory ADD COLUMN goal_intent TEXT;");
        db.exec("ALTER TABLE procedural_memory ADD COLUMN initial_state TEXT;");
        db.exec("ALTER TABLE procedural_memory ADD COLUMN success_condition TEXT;");
        db.exec("ALTER TABLE procedural_memory ADD COLUMN app_version TEXT;");
        db.exec("ALTER TABLE procedural_memory ADD COLUMN failure_count INTEGER DEFAULT 0;");
        db.exec("ALTER TABLE procedural_memory ADD COLUMN last_verified_at INTEGER;");
        db.exec("ALTER TABLE procedural_memory ADD COLUMN fallback_strategy TEXT;");
        db.exec("ALTER TABLE user_preferences ADD COLUMN is_personal INTEGER DEFAULT 1;");
        db.exec("ALTER TABLE user_preferences ADD COLUMN enabled INTEGER DEFAULT 1;");

        // Migrazione v5 (Conversazioni)
        db.exec(`
            CREATE TABLE IF NOT EXISTS conversations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp INTEGER NOT NULL,
                user_query TEXT NOT NULL,
                assistant_reply TEXT NOT NULL,
                status TEXT NOT NULL,
                intent_key TEXT,
                tokens_spent INTEGER DEFAULT 0,
                cost_eur REAL DEFAULT 0.0
            );
        `);

        // Migrazione v6 (Procedural Memory is_personal classification)
        db.exec("ALTER TABLE procedural_memory ADD COLUMN is_personal INTEGER DEFAULT 0;");

        const cols = db.prepare("PRAGMA table_info(procedural_memory);").all();
        const colNames = new Set(cols.map(c => c.name));
        const expectedCols = ["id", "intent_key", "goal_intent", "description", "app_package",
                              "initial_state", "action_sequence", "success_condition", "app_version",
                              "success_count", "failure_count", "last_used", "last_verified_at",
                              "fallback_strategy", "is_personal", "created_at"];
        const allColsOk = expectedCols.every(c => colNames.has(c));
        if (allColsOk) {
            console.log("[PASS] SQLite Test 1: Migrazione completa v1 -> v6 riuscita, 16/16 colonne verificate in procedural_memory");
            passed++;
        } else {
            console.error("[FAIL] SQLite Test 1: Colonne mancanti in procedural_memory");
            failed++;
        }

        // TEST 2: Vincolo UNIQUE e CONFLICT_REPLACE
        const now = 1700000000000;
        db.prepare(`
            INSERT OR REPLACE INTO procedural_memory 
            (intent_key, goal_intent, description, app_package, initial_state, action_sequence, success_condition, app_version, is_personal, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        `).run("youtube", "apri youtube", "Template YouTube TV", "com.google.android.youtube.tv", "{}", "[]", "{}", "v2.0", 0, now);

        db.prepare(`
            INSERT OR REPLACE INTO procedural_memory 
            (intent_key, goal_intent, description, app_package, initial_state, action_sequence, success_condition, app_version, is_personal, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        `).run("youtube", "apri youtube", "Template YouTube TV Aggiornato", "com.google.android.youtube.tv", "{}", "[]", "{}", "v2.1", 0, now + 1000);

        const rowYt = db.prepare("SELECT COUNT(*) as count, description, app_version FROM procedural_memory WHERE intent_key = 'youtube';").get();
        if (rowYt.count === 1 && rowYt.description === "Template YouTube TV Aggiornato" && rowYt.app_version === "v2.1") {
            console.log("[PASS] SQLite Test 2: Vincolo UNIQUE su intent_key e CONFLICT_REPLACE verificati (nessun duplicato, record aggiornato)");
            passed++;
        } else {
            console.error("[FAIL] SQLite Test 2: Errore vincolo UNIQUE");
            failed++;
        }

        // TEST 3: Inserimento Pubblici vs Personali e Filtro Guest Mode
        db.prepare(`
            INSERT INTO procedural_memory 
            (intent_key, goal_intent, description, app_package, initial_state, action_sequence, success_condition, app_version, is_personal, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        `).run("dan_secret_search", "cerca video vacanze daniele", "Ricerca privata utente", "com.google.android.youtube.tv", "{}", "[]", "{}", "1.0", 1, now);

        db.prepare("INSERT INTO user_preferences (pref_key, pref_value, category, is_personal, enabled, updated_at) VALUES (?, ?, ?, ?, ?, ?);")
          .run("user_name", "Daniele", "personal", 1, 1, now);
        db.prepare("INSERT INTO user_preferences (pref_key, pref_value, category, is_personal, enabled, updated_at) VALUES (?, ?, ?, ?, ?, ?);")
          .run("guest_mode", "false", "settings", 0, 1, now);

        db.prepare(`
            INSERT INTO conversations (timestamp, user_query, assistant_reply, status, intent_key, tokens_spent, cost_eur)
            VALUES (?, ?, ?, ?, ?, ?, ?);
        `).run(now, "Come va?", "Tutto bene, pronto a servirti.", "SUCCESS", "chat", 120, 0.0001);

        const allProcs = db.prepare("SELECT intent_key, is_personal FROM procedural_memory ORDER BY id ASC;").all();
        const normalOk = (allProcs.length === 2 && allProcs[0].is_personal === 0 && allProcs[1].is_personal === 1);

        const guestProcs = db.prepare("SELECT intent_key, is_personal FROM procedural_memory WHERE is_personal = 0 ORDER BY id ASC;").all();
        const guestOk = (guestProcs.length === 1 && guestProcs[0].intent_key === "youtube" && guestProcs[0].is_personal === 0);

        if (normalOk && guestOk) {
            console.log("[PASS] SQLite Test 3: Filtro SQL Guest Mode verificato: 'WHERE is_personal = 0' isola le procedure tecniche ed esclude i dati personali");
            passed++;
        } else {
            console.error("[FAIL] SQLite Test 3: Errore filtro privacy");
            failed++;
        }

        // TEST 4: Pulizia Selettiva Dati Personali
        db.exec("DELETE FROM user_preferences WHERE is_personal = 1;");
        db.exec("DELETE FROM procedural_memory WHERE is_personal = 1;");
        db.exec("DELETE FROM conversations;");

        const remPrefs = db.prepare("SELECT COUNT(*) as c FROM user_preferences;").get().c;
        const remProcs = db.prepare("SELECT COUNT(*) as c FROM procedural_memory;").get().c;
        const remConvs = db.prepare("SELECT COUNT(*) as c FROM conversations;").get().c;

        if (remPrefs === 1 && remProcs === 1 && remConvs === 0) {
            console.log("[PASS] SQLite Test 4: Pulizia selettiva confermata: preferenze personali, procedure utente e conversazioni azzerate; impostazioni di sistema e template tecnici preservati");
            passed++;
        } else {
            console.error("[FAIL] SQLite Test 4: Errore pulizia");
            failed++;
        }

        // TEST 5: Controllo Dimensioni File
        db.close();
        const stat = fs.statSync(tempDbPath);
        const maxAllowed = 15 * 1024 * 1024;
        if (stat.size > 0 && stat.size < maxAllowed) {
            console.log(`[PASS] SQLite Test 5: Dimensioni fisiche database su disco conformi: ${stat.size} bytes (limite max: ${maxAllowed} bytes = 15 MB)`);
            passed++;
        } else {
            console.error(`[FAIL] SQLite Test 5: Dimensione anomala database: ${stat.size} bytes`);
            failed++;
        }

    } finally {
        if (fs.existsSync(tempDbPath)) {
            try { fs.unlinkSync(tempDbPath); } catch (e) {}
        }
    }

    console.log("\n=== ESITO COMPLETO TEST SQLITE REALE (Node.js) ===");
    console.log(`Test Superati: ${passed} / ${passed + failed}`);
    if (failed > 0) process.exit(1);
}

runTests();
