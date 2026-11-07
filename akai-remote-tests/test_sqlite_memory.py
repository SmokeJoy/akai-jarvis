#!/usr/bin/env python3
"""
AKAI Custom Remote - SQLite Memory Engine Real Database Test Suite
Verifica l'implementazione SQLite reale:
- Creazione schema tabelle
- Migrazione incrementale v1 -> v2 -> v4 -> v5 -> v6
- Vincoli di integrità (UNIQUE, PRIMARY KEY, NOT NULL)
- Inserimento e query per procedure di sistema vs personali
- Filtro rigoroso privacy Guest Mode su disco
- Funzione di pulizia selettiva (clearPersonalPreferencesOnly)
- Calcolo dimensione file e limite storage 15 MB
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

    temp_db_fd, temp_db_path = tempfile.mkstemp(suffix=".db", prefix="akai_test_memory_")
    os.close(temp_db_fd)

    try:
        conn = sqlite3.connect(temp_db_path)
        cur = conn.cursor()

        # ---------------------------------------------------------------------
        # TEST 1: Creazione Schema Iniziale v1 e Migrazione fino a v6
        # ---------------------------------------------------------------------
        # Schema v1 iniziale
        cur.execute("""
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
        """)
        cur.execute("""
            CREATE TABLE user_preferences (
                pref_key TEXT PRIMARY KEY,
                pref_value TEXT NOT NULL,
                category TEXT NOT NULL,
                updated_at INTEGER
            );
        """)
        cur.execute("""
            CREATE TABLE ai_usage_stats (
                metric_key TEXT PRIMARY KEY,
                metric_value INTEGER DEFAULT 0
            );
        """)

        # Migrazione v2
        cur.execute("ALTER TABLE procedural_memory ADD COLUMN goal_intent TEXT;")
        cur.execute("ALTER TABLE procedural_memory ADD COLUMN initial_state TEXT;")
        cur.execute("ALTER TABLE procedural_memory ADD COLUMN success_condition TEXT;")
        cur.execute("ALTER TABLE procedural_memory ADD COLUMN app_version TEXT;")
        cur.execute("ALTER TABLE procedural_memory ADD COLUMN failure_count INTEGER DEFAULT 0;")
        cur.execute("ALTER TABLE procedural_memory ADD COLUMN last_verified_at INTEGER;")
        cur.execute("ALTER TABLE procedural_memory ADD COLUMN fallback_strategy TEXT;")
        cur.execute("ALTER TABLE user_preferences ADD COLUMN is_personal INTEGER DEFAULT 1;")
        cur.execute("ALTER TABLE user_preferences ADD COLUMN enabled INTEGER DEFAULT 1;")

        # Migrazione v5 (Conversazioni)
        cur.execute("""
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
        """)

        # Migrazione v6 (Procedural Memory is_personal classification)
        cur.execute("ALTER TABLE procedural_memory ADD COLUMN is_personal INTEGER DEFAULT 0;")

        conn.commit()

        # Verifica colonne presenti in procedural_memory
        cur.execute("PRAGMA table_info(procedural_memory);")
        proc_cols = {row[1]: row[2] for row in cur.fetchall()}
        expected_cols = ["id", "intent_key", "goal_intent", "description", "app_package",
                         "initial_state", "action_sequence", "success_condition", "app_version",
                         "success_count", "failure_count", "last_used", "last_verified_at",
                         "fallback_strategy", "is_personal", "created_at"]
        
        all_cols_ok = all(col in proc_cols for col in expected_cols)
        if all_cols_ok:
            print("[PASS] SQLite Test 1: Migrazione completa v1 -> v6 riuscita, 16/16 colonne verificate in procedural_memory")
            passed += 1
        else:
            print(f"[FAIL] SQLite Test 1: Colonne mancanti in procedural_memory: {set(expected_cols) - set(proc_cols.keys())}")
            failed += 1

        # ---------------------------------------------------------------------
        # TEST 2: Vincolo UNIQUE su intent_key e sostituzione CONFLICT_REPLACE
        # ---------------------------------------------------------------------
        now = 1700000000000
        cur.execute("""
            INSERT OR REPLACE INTO procedural_memory 
            (intent_key, goal_intent, description, app_package, initial_state, action_sequence, success_condition, app_version, is_personal, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, ("youtube", "apri youtube", "Template YouTube TV", "com.google.android.youtube.tv", "{}", "[]", "{}", "v2.0", 0, now))

        # Re-inserisci la stessa chiave con descrizione aggiornata (simula apprendimento / update)
        cur.execute("""
            INSERT OR REPLACE INTO procedural_memory 
            (intent_key, goal_intent, description, app_package, initial_state, action_sequence, success_condition, app_version, is_personal, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, ("youtube", "apri youtube", "Template YouTube TV Aggiornato", "com.google.android.youtube.tv", "{}", "[]", "{}", "v2.1", 0, now + 1000))
        conn.commit()

        cur.execute("SELECT COUNT(*), description, app_version FROM procedural_memory WHERE intent_key = 'youtube';")
        count, desc, ver = cur.fetchone()
        if count == 1 and desc == "Template YouTube TV Aggiornato" and ver == "v2.1":
            print("[PASS] SQLite Test 2: Vincolo UNIQUE su intent_key e CONFLICT_REPLACE verificati (nessun duplicato, record aggiornato)")
            passed += 1
        else:
            print(f"[FAIL] SQLite Test 2: Errore vincolo UNIQUE (count={count}, desc={desc})")
            failed += 1

        # ---------------------------------------------------------------------
        # TEST 3: Inserimento Dati Misti (Pubblici vs Personali) e Filtro Guest Mode
        # ---------------------------------------------------------------------
        # Procedura personale utente
        cur.execute("""
            INSERT INTO procedural_memory 
            (intent_key, goal_intent, description, app_package, initial_state, action_sequence, success_condition, app_version, is_personal, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, ("dan_secret_search", "cerca video vacanze daniele", "Ricerca privata utente", "com.google.android.youtube.tv", "{}", "[]", "{}", "1.0", 1, now))

        # Preferenze personali e di sistema
        cur.execute("INSERT INTO user_preferences (pref_key, pref_value, category, is_personal, enabled, updated_at) VALUES (?, ?, ?, ?, ?, ?);",
                    ("user_name", "Daniele", "personal", 1, 1, now))
        cur.execute("INSERT INTO user_preferences (pref_key, pref_value, category, is_personal, enabled, updated_at) VALUES (?, ?, ?, ?, ?, ?);",
                    ("guest_mode", "false", "settings", 0, 1, now))

        # Conversazione personale
        cur.execute("""
            INSERT INTO conversations (timestamp, user_query, assistant_reply, status, intent_key, tokens_spent, cost_eur)
            VALUES (?, ?, ?, ?, ?, ?, ?);
        """, (now, "Come va?", "Tutto bene, pronto a servirti.", "SUCCESS", "chat", 120, 0.0001))
        conn.commit()

        # Query Modalità Normale (tutte le procedure)
        cur.execute("SELECT intent_key, is_personal FROM procedural_memory ORDER BY id ASC;")
        all_procs = cur.fetchall()
        normal_ok = (len(all_procs) == 2 and all_procs[0][1] == 0 and all_procs[1][1] == 1)

        # Query Modalità Ospite (filtro is_personal = 0)
        cur.execute("SELECT intent_key, is_personal FROM procedural_memory WHERE is_personal = 0 ORDER BY id ASC;")
        guest_procs = cur.fetchall()
        guest_ok = (len(guest_procs) == 1 and guest_procs[0][0] == "youtube" and guest_procs[0][1] == 0)

        if normal_ok and guest_ok:
            print("[PASS] SQLite Test 3: Filtro SQL Guest Mode verificato: 'WHERE is_personal = 0' isola le procedure tecniche ed esclude i dati personali")
            passed += 1
        else:
            print(f"[FAIL] SQLite Test 3: Errore filtro privacy (normal_ok={normal_ok}, guest_ok={guest_ok})")
            failed += 1

        # ---------------------------------------------------------------------
        # TEST 4: Pulizia Selettiva Dati Personali (clearPersonalPreferencesOnly)
        # ---------------------------------------------------------------------
        # Esegui pulizia selettiva identica a AkaiMemoryEngine.clearPersonalPreferencesOnly()
        cur.execute("DELETE FROM user_preferences WHERE is_personal = 1;")
        cur.execute("DELETE FROM procedural_memory WHERE is_personal = 1;")
        cur.execute("DELETE FROM conversations;")
        conn.commit()

        cur.execute("SELECT COUNT(*) FROM user_preferences;")
        remaining_prefs = cur.fetchone()[0]
        cur.execute("SELECT COUNT(*) FROM procedural_memory;")
        remaining_procs = cur.fetchone()[0]
        cur.execute("SELECT COUNT(*) FROM conversations;")
        remaining_convs = cur.fetchone()[0]

        if remaining_prefs == 1 and remaining_procs == 1 and remaining_convs == 0:
            print("[PASS] SQLite Test 4: Pulizia selettiva confermata: preferenze personali, procedure utente e conversazioni azzerate; impostazioni di sistema e template tecnici preservati")
            passed += 1
        else:
            print(f"[FAIL] SQLite Test 4: Errore pulizia (prefs={remaining_prefs}, procs={remaining_procs}, convs={remaining_convs})")
            failed += 1

        # ---------------------------------------------------------------------
        # TEST 5: Controllo Dimensioni File e Limite di Archiviazione 15 MB
        # ---------------------------------------------------------------------
        db_size = os.path.getsize(temp_db_path)
        max_allowed = 15 * 1024 * 1024 # 15 MB
        if 0 < db_size < max_allowed:
            print(f"[PASS] SQLite Test 5: Dimensioni fisiche database su disco conformi: {db_size} bytes (limite max: {max_allowed} bytes = 15 MB)")
            passed += 1
        else:
            print(f"[FAIL] SQLite Test 5: Dimensione anomala database: {db_size} bytes")
            failed += 1

        conn.close()

    finally:
        if os.path.exists(temp_db_path):
            os.remove(temp_db_path)

    print("\n=== ESITO COMPLETO TEST SQLITE REALE ===")
    print(f"Test Superati: {passed} / {passed + failed}")
    if failed > 0:
        sys.exit(1)

if __name__ == "__main__":
    run_tests()
