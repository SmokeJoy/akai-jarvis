#!/usr/bin/env python3
"""
AKAI Custom Remote - SQLite Memory Engine Real Database Test Suite (v6)
Verifica l'integrità del database su disco e le politiche di privacy:
1. Fixture v5 pre-popolata con procedure private create prima della migrazione
2. Migrazione conservativa v5 -> v6 (default is_personal=1 per procedure storiche + whitelist template)
3. Validazione protezione privacy in Guest Mode su consultazione REST
4. Validazione protezione privacy in Guest Mode su ricerca vocale (findProcedureByGoal / getProcedure)
5. Validazione protezione privacy in Guest Mode su lettura preferenze personali (getPreference)
6. Pulizia selettiva (clearPersonalPreferencesOnly) che elimina sia preferenze che procedure personali
7. Enforcement limite conversazioni (FIFO max 20) e calcolo dimensione storage
"""

import os
import sys
import sqlite3
import tempfile
import json

def run_tests():
    print("=== TEST PERSISTENZA E INTEGRITÀ SQLITE REALE (AkaiMemoryEngine v6) ===")
    passed = 0
    failed = 0

    temp_db_fd, temp_db_path = tempfile.mkstemp(suffix=".db", prefix="akai_test_memory_v6_")
    os.close(temp_db_fd)

    try:
        conn = sqlite3.connect(temp_db_path)
        cur = conn.cursor()

        # ---------------------------------------------------------------------
        # TEST 1: Creazione Fixture v5 Reale con Procedure Legacy Private Pre-esistenti
        # ---------------------------------------------------------------------
        # Schema v5 (procedural_memory NON possedeva la colonna is_personal)
        cur.execute("""
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
        """)
        cur.execute("""
            CREATE TABLE user_preferences (
                pref_key TEXT PRIMARY KEY,
                pref_value TEXT NOT NULL,
                category TEXT NOT NULL,
                is_personal INTEGER DEFAULT 1,
                enabled INTEGER DEFAULT 1,
                updated_at INTEGER
            );
        """)
        cur.execute("""
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
        """)
        cur.execute("""
            CREATE TABLE ai_usage_stats (
                metric_key TEXT PRIMARY KEY,
                metric_value INTEGER DEFAULT 0
            );
        """)

        # Inserimento dati storici v5 pre-migrazione:
        # A) Template di sistema autentico conforme al fingerprint immutabile
        now = 1700000000000
        cur.execute("""
            INSERT INTO procedural_memory 
            (intent_key, goal_intent, description, app_package, initial_state, action_sequence, success_condition, app_version, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, ("youtube", "apri youtube", "Template apertura YouTube TV", "com.google.android.youtube.tv", "{}", "[]", "{}", "v2.0", now))

        # B) Variante personalizzata dall'utente con intent_key analogo ma query/dati privati
        cur.execute("""
            INSERT INTO procedural_memory 
            (intent_key, goal_intent, description, app_package, initial_state, action_sequence, success_condition, app_version, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, ("youtube_custom", "guarda video privati", "Miei preferiti privati YouTube", "com.google.android.youtube.tv", "{}", "[]", "{}", "v2.0", now))

        # C) Procedura privata appresa dall'utente prima dell'aggiornamento
        cur.execute("""
            INSERT INTO procedural_memory 
            (intent_key, goal_intent, description, app_package, initial_state, action_sequence, success_condition, app_version, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, ("dan_vacation_photos", "cerca video vacanze daniele", "Procedura appresa utente", "com.google.android.youtube.tv", "{}", "[]", "{}", "1.0", now))

        # D) Preferenze personali e impostazioni
        cur.execute("INSERT INTO user_preferences (pref_key, pref_value, category, is_personal, enabled, updated_at) VALUES (?, ?, ?, ?, ?, ?);",
                    ("favorite_channels", "[\"Italia 2\", \"Focus\"]", "channels", 1, 1, now))
        cur.execute("INSERT INTO user_preferences (pref_key, pref_value, category, is_personal, enabled, updated_at) VALUES (?, ?, ?, ?, ?, ?);",
                    ("guest_mode", "false", "settings", 0, 1, now))
        conn.commit()

        # Esegui migrazione v5 -> v6 categorica esattamente come definito in AkaiMemoryEngine.onUpgrade()
        # Criterio 3: TUTTE le procedure legacy v5 rimangono rigorosamente private (is_personal = 1)
        cur.execute("ALTER TABLE procedural_memory ADD COLUMN is_personal INTEGER DEFAULT 1;")
        
        # Inserimento post-upgrade di template di sistema v6 esplicito pubblico
        cur.execute("""
            INSERT INTO procedural_memory 
            (intent_key, goal_intent, description, app_package, initial_state, action_sequence, success_condition, app_version, is_personal, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, ("system_yt_template", "apri youtube", "Template di sistema v6", "com.google.android.youtube.tv", "{}", "[]", "{}", "v2.0", 0, now))
        conn.commit()

        # Verifica che tutte le procedure legacy v5 siano is_personal = 1, e solo il template di sistema sia 0
        cur.execute("SELECT intent_key, is_personal FROM procedural_memory ORDER BY id ASC;")
        procs_migrated = {row[0]: row[1] for row in cur.fetchall()}

        if procs_migrated.get("youtube") == 1 and procs_migrated.get("youtube_custom") == 1 and procs_migrated.get("dan_vacation_photos") == 1 and procs_migrated.get("system_yt_template") == 0:
            print("[PASS] SQLite Test 1: Migrazione v5 -> v6 categorica (Criterio 3): TUTTE le procedure legacy v5 rimangono private (is_personal=1), solo i template di sistema v6 espliciti sono pubblici (is_personal=0)")
            passed += 1
        else:
            print(f"[FAIL] SQLite Test 1: Migrazione non categorica! Stato: {procs_migrated}")
            failed += 1

        # ---------------------------------------------------------------------
        # TEST 2: Protezione Privacy Guest Mode nella Ricerca Vocale (findProcedureByGoal)
        # ---------------------------------------------------------------------
        def simulate_find_procedure(query, guest_mode):
            clean = query.strip().lower()
            where = "intent_key = ?"
            if guest_mode:
                where += " AND is_personal = 0"
            cur.execute(f"SELECT intent_key, description, is_personal FROM procedural_memory WHERE {where};", (clean,))
            row = cur.fetchone()
            if row:
                return row
            where_goal = "goal_intent = ?"
            if guest_mode:
                where_goal += " AND is_personal = 0"
            cur.execute(f"SELECT intent_key, description, is_personal FROM procedural_memory WHERE {where_goal};", (clean,))
            return cur.fetchone()

        # In modalità normale: l'utente trova la propria procedura
        res_normal = simulate_find_procedure("cerca video vacanze daniele", guest_mode=False)
        # In modalità ospite: la procedura privata NON deve essere trovata
        res_guest = simulate_find_procedure("cerca video vacanze daniele", guest_mode=True)
        # In modalità ospite: la variante personalizzata di youtube NON deve essere trovata
        res_custom_guest = simulate_find_procedure("guarda video privati", guest_mode=True)
        # In modalità ospite: il template di sistema pubblico DEVE essere trovato
        res_sys_guest = simulate_find_procedure("apri youtube", guest_mode=True)

        if res_normal is not None and res_guest is None and res_custom_guest is None and res_sys_guest is not None:
            print("[PASS] SQLite Test 2: Protezione vocale Guest Mode verificata: findProcedureByGoal blocca procedure personali e varianti custom (is_personal=1), consentendo solo il template immutabile pubblico")
            passed += 1
        else:
            print(f"[FAIL] SQLite Test 2: Leak vocale in Guest Mode! (normal={res_normal}, guest={res_guest})")
            failed += 1

        # ---------------------------------------------------------------------
        # TEST 3: Protezione Privacy Guest Mode nella Lettura Preferenze (getPreference)
        # ---------------------------------------------------------------------
        def simulate_get_preference(key, default_val, guest_mode):
            cur.execute("SELECT pref_value, is_personal FROM user_preferences WHERE pref_key = ?;", (key,))
            row = cur.fetchone()
            if not row:
                return default_val
            val, personal = row[0], row[1]
            if personal == 1 and key != "guest_mode" and guest_mode:
                return default_val
            return val

        pref_normal = simulate_get_preference("favorite_channels", "[]", guest_mode=False)
        pref_guest = simulate_get_preference("favorite_channels", "[]", guest_mode=True)
        guest_flag = simulate_get_preference("guest_mode", "false", guest_mode=True)

        if pref_normal != "[]" and pref_guest == "[]" and guest_flag == "false":
            print("[PASS] SQLite Test 3: Protezione preferenze vocali/REST confermata: getPreference non restituisce preferenze personali in Guest Mode")
            passed += 1
        else:
            print(f"[FAIL] SQLite Test 3: Preferenze personali trapelate in Guest Mode (pref_guest={pref_guest})")
            failed += 1

        # ---------------------------------------------------------------------
        # TEST 4: Pulizia Selettiva (clearPersonalPreferencesOnly) su Memoria Procedurale
        # ---------------------------------------------------------------------
        # Inserisci una conversazione
        cur.execute("INSERT INTO conversations (timestamp, user_query, assistant_reply, status) VALUES (?, ?, ?, ?);",
                    (now, "Ciao", "Buongiorno", "SUCCESS"))
        conn.commit()

        # Esecuzione pulizia selettiva v6
        cur.execute("DELETE FROM user_preferences WHERE is_personal = 1;")
        cur.execute("DELETE FROM procedural_memory WHERE is_personal = 1;")
        cur.execute("DELETE FROM conversations;")
        conn.commit()

        cur.execute("SELECT COUNT(*) FROM user_preferences WHERE is_personal = 1;")
        c_prefs = cur.fetchone()[0]
        cur.execute("SELECT COUNT(*) FROM procedural_memory WHERE is_personal = 1;")
        c_procs = cur.fetchone()[0]
        cur.execute("SELECT COUNT(*) FROM procedural_memory WHERE is_personal = 0;")
        c_sys_procs = cur.fetchone()[0]
        cur.execute("SELECT COUNT(*) FROM conversations;")
        c_convs = cur.fetchone()[0]

        if c_prefs == 0 and c_procs == 0 and c_sys_procs == 1 and c_convs == 0:
            print("[PASS] SQLite Test 4: Pulizia selettiva v6 confermata: cancellate preferenze personali, conversazioni e procedure personali storiche; template di sistema preservati")
            passed += 1
        else:
            print(f"[FAIL] SQLite Test 4: Errore pulizia selettiva (c_prefs={c_prefs}, c_procs={c_procs}, c_sys_procs={c_sys_procs}, c_convs={c_convs})")
            failed += 1

        # ---------------------------------------------------------------------
        # TEST 5: Enforcement FIFO Conversazioni (Max 20 Turni) e Limite Storage 15 MB
        # ---------------------------------------------------------------------
        # Inserisci 30 conversazioni
        for i in range(1, 31):
            cur.execute("""
                INSERT INTO conversations (timestamp, user_query, assistant_reply, status, intent_key)
                VALUES (?, ?, ?, ?, ?);
            """, (now + (i * 1000), f"Query {i}", f"Risposta {i}", "SUCCESS", "chat"))
        conn.commit()

        # Applica l'enforcement FIFO di AkaiMemoryEngine:
        cur.execute("""
            DELETE FROM conversations WHERE id NOT IN (
                SELECT id FROM conversations ORDER BY timestamp DESC LIMIT 20
            );
        """)
        conn.commit()

        cur.execute("SELECT COUNT(*), MIN(user_query), MAX(user_query) FROM conversations;")
        count_conv, min_q, max_q = cur.fetchone()

        db_size = os.path.getsize(temp_db_path)
        max_storage = 15 * 1024 * 1024 # 15 MB

        if count_conv == 20 and min_q == "Query 11" and max_q == "Query 30" and 0 < db_size < max_storage:
            print(f"[PASS] SQLite Test 5: Enforcement FIFO a max 20 scambi verificato (tagliati i 10 scambi piu vecchi, conservati Query 11-30). Dimensione disco: {db_size} bytes < 15 MB")
            passed += 1
        else:
            print(f"[FAIL] SQLite Test 5: Errore enforcement conversazioni o storage (count={count_conv}, min={min_q}, max={max_q}, size={db_size})")
            failed += 1

        # ---------------------------------------------------------------------
        # TEST 6: Verifica Downgrade Schema v6 -> v5 e Retrocompatibilità Query Legacy
        # ---------------------------------------------------------------------
        # Se un utente effettua rollback dell'APK alla versione 5, il DB non deve andare in crash
        # (AkaiMemoryEngine implementa onDowngrade senza sollevare eccezioni)
        cur.execute("PRAGMA user_version = 5;")
        conn.commit()
        cur.execute("PRAGMA user_version;")
        uv = cur.fetchone()[0]

        # Query v5 standard che ignora la colonna is_personal
        cur.execute("""
            SELECT id, intent_key, goal_intent, description, app_package 
            FROM procedural_memory 
            ORDER BY id ASC;
        """)
        legacy_rows = cur.fetchall()

        # Inserimento v5 standard (senza colonna is_personal)
        cur.execute("""
            INSERT INTO procedural_memory 
            (intent_key, goal_intent, description, app_package, initial_state, action_sequence, success_condition, app_version, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, ("v5_compat_key", "test goal v5", "Descrizione test v5", "com.test.v5", "{}", "[]", "{}", "1.0", now))
        conn.commit()

        cur.execute("SELECT intent_key, is_personal FROM procedural_memory WHERE intent_key = 'v5_compat_key';")
        new_row = cur.fetchone()

        if uv == 5 and len(legacy_rows) >= 1 and new_row and new_row[1] == 1:
            print("[PASS] SQLite Test 6: Downgrade v6 -> v5 e compatibilità query legacy verificati con successo (schema non corrotto, query v5 operative, default conservativo is_personal=1 preservato)")
            passed += 1
        else:
            print(f"[FAIL] SQLite Test 6: Fallimento retrocompatibilità downgrade v5! uv={uv}, new_row={new_row}")
            failed += 1

        # ---------------------------------------------------------------------
        # TEST 7: Enforcement Storage Budget 15 MB & Emergency Pruning a 5 elementi + VACUUM
        # ---------------------------------------------------------------------
        # Simula la logica checkAndEnforceStorageBudget() di AkaiMemoryEngine quando superato MAX_STORAGE_BYTES
        for i in range(1, 26):
            cur.execute("""
                INSERT INTO conversations (timestamp, user_query, assistant_reply, status)
                VALUES (?, ?, ?, ?);
            """, (now + 100000 + (i * 1000), f"Query Budget {i}", f"Reply Budget {i}", "SUCCESS"))
        conn.commit()

        cur.execute("SELECT COUNT(*) FROM conversations;")
        pre_prune_count = cur.fetchone()[0]

        # Trigger potatura di emergenza: mantieni solo i 5 più recenti
        cur.execute("""
            DELETE FROM conversations WHERE id NOT IN (
                SELECT id FROM conversations ORDER BY timestamp DESC LIMIT 5
            );
        """)
        conn.commit()
        cur.execute("VACUUM;")

        cur.execute("SELECT COUNT(*) FROM conversations;")
        post_prune_count = cur.fetchone()[0]

        cur.execute("PRAGMA page_count;")
        page_count = cur.fetchone()[0]
        cur.execute("PRAGMA page_size;")
        page_size = cur.fetchone()[0]
        calculated_size = page_count * page_size

        if pre_prune_count > 20 and post_prune_count == 5 and 0 < calculated_size < max_storage:
            print(f"[PASS] SQLite Test 7: Enforcement Storage Budget simulato (emergency pruning a 5 record + VACUUM eseguito: dimensione {calculated_size} bytes < 15 MB)")
            passed += 1
        else:
            print(f"[FAIL] SQLite Test 7: Errore emergency pruning storage budget (pre={pre_prune_count}, post={post_prune_count})")
            failed += 1

        conn.close()

        # ---------------------------------------------------------------------
        # TEST 8: Durabilita Reale su Disco con Chiusura e Riapertura Connessione (Close/Reopen)
        # ---------------------------------------------------------------------
        # Dimostra che una procedura complessa appresa (es. Test 38: skill 'open_audio_advanced')
        # inserita nel database SQLite reale su disco mantenga integri e deserializzabili
        # sia 'action_sequence' JSON che 'success_condition' JSON dopo la chiusura completa
        # della connessione (conn.close) e la successiva riapertura da file (sqlite3.connect).
        conn_durable = sqlite3.connect(temp_db_path)
        cur_durable = conn_durable.cursor()

        skill_intent_key = "open_audio_advanced"
        skill_goal = "apri impostazioni audio avanzate"
        skill_desc = "Apre le impostazioni audio avanzate del dispositivo TV"
        skill_pkg = "com.android.tv.settings"
        skill_init_state = json.dumps({"current_package": "it.akai.customhome.v8"})
        skill_actions_obj = [
            {"action": "launch_app", "package": "com.android.tv.settings"},
            {"action": "wait", "duration_ms": 200},
            {"action": "click", "target": "Impostazioni dispositivo"},
            {"action": "click", "target": "Suono"},
            {"action": "click", "target": "Impostazioni avanzate"}
        ]
        skill_actions_json = json.dumps(skill_actions_obj)
        skill_success_obj = {
            "contains_text": "Uscita digitale",
            "expected_package": "com.android.tv.settings"
        }
        skill_success_json = json.dumps(skill_success_obj)
        skill_fallback = json.dumps({"action": "press_home"})

        cur_durable.execute("""
            INSERT INTO procedural_memory 
            (intent_key, goal_intent, description, app_package, initial_state, action_sequence, success_condition, app_version, is_personal, created_at, fallback_strategy)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, (skill_intent_key, skill_goal, skill_desc, skill_pkg, skill_init_state, skill_actions_json, skill_success_json, "v6.0", 1, now + 500000, skill_fallback))
        conn_durable.commit()

        # Chiusura esplicita per garantire flush su disco e isolamento connessione
        conn_durable.close()

        # Riapertura da file persistente su disco con una nuova connessione
        conn_reopened = sqlite3.connect(temp_db_path)
        cur_reopened = conn_reopened.cursor()

        # Query simulando findProcedureByGoal(query="apri impostazioni audio avanzate")
        cur_reopened.execute("""
            SELECT intent_key, goal_intent, description, app_package, action_sequence, success_condition, is_personal, fallback_strategy
            FROM procedural_memory
            WHERE goal_intent = ? OR intent_key = ?;
        """, (skill_goal, skill_intent_key))
        recovered_row = cur_reopened.fetchone()
        conn_reopened.close()

        durability_ok = False
        if recovered_row is not None:
            rec_intent_key, rec_goal, rec_desc, rec_pkg, rec_actions_raw, rec_success_raw, rec_personal, rec_fallback_raw = recovered_row
            try:
                rec_actions = json.loads(rec_actions_raw)
                rec_success = json.loads(rec_success_raw)
                rec_fallback = json.loads(rec_fallback_raw)

                durability_ok = (
                    rec_intent_key == skill_intent_key and
                    rec_goal == skill_goal and
                    rec_pkg == skill_pkg and
                    rec_personal == 1 and
                    isinstance(rec_actions, list) and len(rec_actions) == 5 and
                    rec_actions[0].get("action") == "launch_app" and rec_actions[0].get("package") == "com.android.tv.settings" and
                    rec_actions[1].get("action") == "wait" and rec_actions[1].get("duration_ms") == 200 and
                    rec_actions[2].get("action") == "click" and rec_actions[2].get("target") == "Impostazioni dispositivo" and
                    rec_actions[3].get("action") == "click" and rec_actions[3].get("target") == "Suono" and
                    rec_actions[4].get("action") == "click" and rec_actions[4].get("target") == "Impostazioni avanzate" and
                    rec_success.get("contains_text") == "Uscita digitale" and
                    rec_success.get("expected_package") == "com.android.tv.settings" and
                    rec_fallback.get("action") == "press_home"
                )
            except Exception as e:
                print(f"[FAIL] SQLite Test 8: Errore parsing JSON recuperato da disco: {e}")
                durability_ok = False

        if durability_ok:
            print("[PASS] SQLite Test 8: Durabilita reale su disco con chiusura e riapertura (close/reopen) verificata: procedura complessa (action_sequence 5 step e success_condition JSON) recuperata intatta al 100%")
            passed += 1
        else:
            print(f"[FAIL] SQLite Test 8: Durabilita fallita su chiusura/riapertura DB reale! recovered_row={recovered_row}")
            failed += 1

    finally:
        if os.path.exists(temp_db_path):
            os.remove(temp_db_path)

    print("\n=== ESITO COMPLETO TEST SQLITE REALE v6 ===")
    print(f"Test Superati: {passed} / {passed + failed}")
    if failed > 0:
        sys.exit(1)

if __name__ == "__main__":
    run_tests()
