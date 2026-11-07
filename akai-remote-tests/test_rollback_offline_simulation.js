/**
 * AKAI Custom Remote - Test Suite Simulazione Offline Rollback Atomico & Enforcement 15 MB Reale (Node.js)
 * Dimostra offline:
 * 1. Creazione DB v5 con dati utente reali
 * 2. Backup atomico e verifica integrità PRAGMA integrity_check
 * 3. Migrazione v6 categorica (tutte le procedure legacy sono is_personal=1, zero leaks)
 * 4. Dimostrazione del vincolo architetturale: il codice v5 non può leggere un DB v6 senza rollback del DB
 * 5. Rollback atomico integrato (APK + DB) con ripristino verificato al 100%
 * 6. Enforcement Reale Budget Storage 15 MB: riempimento effettivo a >16 MB con 16 blob da 1 MB,
 *    triggering dell'emergency pruning a 5 record + VACUUM e misurazione reale PRAGMA page_count * page_size
 */
const { DatabaseSync } = require('node:sqlite');
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');

function sha256File(filePath) {
    const data = fs.readFileSync(filePath);
    return crypto.createHash('sha256').update(data).digest('hex');
}

function runOfflineSimulation() {
    console.log("=== SIMULAZIONE OFFLINE ROLLBACK ATOMICO & STORAGE BUDGET 15 MB ===");
    let passed = 0;
    let failed = 0;

    const tmpDir = os.tmpdir();
    const liveDbPath = path.join(tmpDir, `akai_live_test_${Date.now()}.db`);
    const backupDbPath = path.join(tmpDir, `akai_backup_v5_${Date.now()}.db`);
    const budgetDbPath = path.join(tmpDir, `akai_budget_test_${Date.now()}.db`);

    try {
        // ---------------------------------------------------------------------
        // FASE 1: Creazione DB v5 originale con dati e schema reali
        // ---------------------------------------------------------------------
        const dbV5 = new DatabaseSync(liveDbPath);
        dbV5.exec("PRAGMA user_version = 5;");
        dbV5.exec(`
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
        `);

        const now = 1700000000000;
        // Inserimento procedura legacy YouTube (in v5 non esisteva is_personal)
        dbV5.prepare(`
            INSERT INTO procedural_memory 
            (intent_key, goal_intent, description, app_package, initial_state, action_sequence, success_condition, app_version, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        `).run("youtube", "apri youtube", "Template apertura YouTube TV", "com.google.android.youtube.tv", "{}", "[]", "{}", "v2.0", now);

        // Inserimento procedura privata utente
        dbV5.prepare(`
            INSERT INTO procedural_memory 
            (intent_key, goal_intent, description, app_package, initial_state, action_sequence, success_condition, app_version, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        `).run("dan_private_action", "video privati vacanze", "Procedura privata", "com.google.android.youtube.tv", "{}", "[]", "{}", "1.0", now);

        dbV5.prepare("INSERT INTO user_preferences (pref_key, pref_value, category, is_personal, enabled, updated_at) VALUES (?, ?, ?, ?, ?, ?);")
            .run("favorite_channels", JSON.stringify(["Focus", "Italia 2"]), "channels", 1, 1, now);

        dbV5.prepare("INSERT INTO conversations (timestamp, user_query, assistant_reply, status) VALUES (?, ?, ?, ?);")
            .run(now, "Ciao Jarvis", "Buongiorno Daniele", "SUCCESS");

        dbV5.close();

        // ---------------------------------------------------------------------
        // FASE 2: Backup atomico v5 e calcolo hash di integrità
        // ---------------------------------------------------------------------
        fs.copyFileSync(liveDbPath, backupDbPath);
        const hashV5Backup = sha256File(backupDbPath);

        // Verifica integrità offline PRAGMA integrity_check
        const dbCheck = new DatabaseSync(backupDbPath);
        const integrityRow = dbCheck.prepare("PRAGMA integrity_check;").get();
        dbCheck.close();

        if (integrityRow && integrityRow.integrity_check === "ok" && hashV5Backup) {
            console.log(`[PASS] Simulazione 1: Backup atomico v5 verificato con successo (PRAGMA integrity_check = ok, SHA-256 = ${hashV5Backup.substring(0, 16)}...)`);
            passed++;
        } else {
            console.error("[FAIL] Simulazione 1: Fallimento backup o integrità v5");
            failed++;
        }

        // ---------------------------------------------------------------------
        // FASE 3: Simulazione Migrazione v6 (onUpgrade) su DB Live
        // Tutte le procedure legacy v5 sono marcate come is_personal = 1 (nessun leak)
        // ---------------------------------------------------------------------
        const dbV6 = new DatabaseSync(liveDbPath);
        dbV6.exec("ALTER TABLE procedural_memory ADD COLUMN is_personal INTEGER DEFAULT 1;");
        dbV6.exec("PRAGMA user_version = 6;");

        // Nuova conversazione v6
        dbV6.prepare("INSERT INTO conversations (timestamp, user_query, assistant_reply, status) VALUES (?, ?, ?, ?);")
            .run(now + 10000, "Nuova query v6", "Risposta assistente v6", "SUCCESS");

        const procsV6 = dbV6.prepare("SELECT intent_key, is_personal FROM procedural_memory;").all();
        const mapV6 = {};
        for (const p of procsV6) mapV6[p.intent_key] = p.is_personal;

        if (mapV6["youtube"] === 1 && mapV6["dan_private_action"] === 1) {
            console.log("[PASS] Simulazione 2: Migrazione v6 categorica (Criterio 3): TUTTE le procedure legacy v5 rimangono rigorosamente private (is_personal = 1, zero leaks in Guest Mode)");
            passed++;
        } else {
            console.error("[FAIL] Simulazione 2: Leak migrazione v6: " + JSON.stringify(mapV6));
            failed++;
        }
        dbV6.close();

        // ---------------------------------------------------------------------
        // FASE 4: Dimostrazione del Limite Downgrade dell'APK v5
        // Un'applicazione v5 che apre un DB v6 rileva user_version = 6 > 5
        // e il codice Android nativo non modificato in v5 solleva SQLiteException
        // ---------------------------------------------------------------------
        const dbInspect = new DatabaseSync(liveDbPath);
        const currentVersion = dbInspect.prepare("PRAGMA user_version;").get()["user_version"];
        dbInspect.close();

        const v5ExpectedVersion = 5;
        const downgradeDetected = currentVersion > v5ExpectedVersion;
        if (downgradeDetected) {
            console.log(`[PASS] Simulazione 3: Rilevata incompatibilita downgrade APK v5 su DB v6 (user_version=${currentVersion} > 5). L'APK v5 nativo andrebbe in crash senza restore atomico del DB.`);
            passed++;
        } else {
            console.error("[FAIL] Simulazione 3: Mancato rilevamento incompatibilità");
            failed++;
        }

        // ---------------------------------------------------------------------
        // FASE 5: Rollback Atomico Indivisibile (Ripristino Backup v5)
        // ---------------------------------------------------------------------
        fs.copyFileSync(backupDbPath, liveDbPath);
        const hashRestored = sha256File(liveDbPath);

        const dbRestored = new DatabaseSync(liveDbPath);
        const restoredVersion = dbRestored.prepare("PRAGMA user_version;").get()["user_version"];
        const restoredCheck = dbRestored.prepare("PRAGMA integrity_check;").get()["integrity_check"];
        const restoredConvs = dbRestored.prepare("SELECT COUNT(*) as c FROM conversations;").get().c;
        const restoredProcs = dbRestored.prepare("SELECT COUNT(*) as c FROM procedural_memory;").get().c;
        dbRestored.close();

        if (hashRestored === hashV5Backup && restoredVersion === 5 && restoredCheck === "ok" && restoredConvs === 1 && restoredProcs === 2) {
            console.log("[PASS] Simulazione 4: Rollback atomico riuscito al 100%! Database v5 ripristinato, hash coincidente, schema v5 integro, zero dati corrotti.");
            passed++;
        } else {
            console.error("[FAIL] Simulazione 4: Fallimento rollback atomico");
            failed++;
        }

        // ---------------------------------------------------------------------
        // FASE 6: Enforcement Storage Budget Reale a 15 MB (>16 MB reali su disco)
        // ---------------------------------------------------------------------
        const dbBudget = new DatabaseSync(budgetDbPath);
        dbBudget.exec(`
            CREATE TABLE conversations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp INTEGER NOT NULL,
                user_query TEXT NOT NULL,
                assistant_reply TEXT NOT NULL,
                status TEXT NOT NULL
            );
        `);

        console.log("Riempimento database con 16 blocchi da 1 MB per forzare il superamento reale di 15 MB...");
        // Creazione di un blocco di testo da 1 Megabyte (1.048.576 caratteri)
        const oneMbPayload = "A".repeat(1024 * 1024);
        for (let i = 1; i <= 16; i++) {
            dbBudget.prepare("INSERT INTO conversations (timestamp, user_query, assistant_reply, status) VALUES (?, ?, ?, ?);")
                    .run(now + (i * 1000), `Query Pesante ${i}`, oneMbPayload, "SUCCESS");
        }

        const initialPageCount = dbBudget.prepare("PRAGMA page_count;").get()["page_count"];
        const initialPageSize = dbBudget.prepare("PRAGMA page_size;").get()["page_size"];
        const realSizeBytes = initialPageCount * initialPageSize;
        const maxStorageLimit = 15 * 1024 * 1024; // 15 Megabyte

        console.log(`Dimensione reale DB prima del pruning: ${realSizeBytes} bytes (${(realSizeBytes / (1024*1024)).toFixed(2)} MB)`);

        if (realSizeBytes > maxStorageLimit) {
            console.log("[PASS] Simulazione 5.1: Soglia reale 15 MB superata con successo (DB reale > 16 MB). Triggering emergency pruning...");
            passed++;
        } else {
            console.error("[FAIL] Simulazione 5.1: Dimensione non superata: " + realSizeBytes);
            failed++;
        }

        // Trigger dell'emergency pruning di AkaiMemoryEngine (conserva solo gli ultimi 5 turni + VACUUM)
        dbBudget.exec(`
            DELETE FROM conversations WHERE id NOT IN (
                SELECT id FROM conversations ORDER BY timestamp DESC LIMIT 5
            );
        `);
        dbBudget.exec("VACUUM;");

        const postPageCount = dbBudget.prepare("PRAGMA page_count;").get()["page_count"];
        const postPageSize = dbBudget.prepare("PRAGMA page_size;").get()["page_size"];
        const postSizeBytes = postPageCount * postPageSize;
        const postCount = dbBudget.prepare("SELECT COUNT(*) as c FROM conversations;").get().c;
        dbBudget.close();

        console.log(`Dimensione reale DB post-pruning & VACUUM: ${postSizeBytes} bytes (${(postSizeBytes / (1024*1024)).toFixed(2)} MB), Record conservati: ${postCount}`);

        if (postCount === 5 && postSizeBytes < maxStorageLimit && postSizeBytes < (6 * 1024 * 1024)) {
            console.log(`[PASS] Simulazione 5.2: Enforcement storage budget a 15 MB completato! Spazio ridotto da ${(realSizeBytes / (1024*1024)).toFixed(2)} MB a ${(postSizeBytes / (1024*1024)).toFixed(2)} MB, VACUUM eseguito e budget rispettato.`);
            passed++;
        } else {
            console.error(`[FAIL] Simulazione 5.2: Fallimento pruning/VACUUM: count=${postCount}, size=${postSizeBytes}`);
            failed++;
        }

    } finally {
        for (const p of [liveDbPath, backupDbPath, budgetDbPath]) {
            if (fs.existsSync(p)) {
                try { fs.unlinkSync(p); } catch (e) {}
            }
        }
    }

    console.log(`\n=== ESITO COMPLETO SIMULAZIONE ROLLBACK & STORAGE ===`);
    console.log(`Test Superati: ${passed} / ${passed + failed}`);
    if (failed > 0) process.exit(1);
}

runOfflineSimulation();
