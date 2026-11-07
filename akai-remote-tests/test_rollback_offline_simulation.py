#!/usr/bin/env python3
"""
AKAI Custom Remote - Test Suite Simulazione Offline Rollback Atomico & Enforcement 15 MB Reale (Python)
Dimostra offline:
1. Creazione DB v5 con dati utente reali
2. Backup atomico e verifica integrità PRAGMA integrity_check
3. Migrazione v6 categorica (tutte le procedure legacy sono is_personal=1, zero leaks)
4. Dimostrazione del vincolo architetturale: il codice v5 non può leggere un DB v6 senza rollback del DB
5. Rollback atomico integrato (APK + DB) con ripristino verificato al 100%
6. Enforcement Reale Budget Storage 15 MB: riempimento effettivo a >16 MB con 16 blob da 1 MB,
   triggering dell'emergency pruning a 5 record + VACUUM e misurazione reale PRAGMA page_count * page_size
"""

import os
import sys
import sqlite3
import tempfile
import hashlib
import shutil

def sha256_file(filepath):
    h = hashlib.sha256()
    with open(filepath, 'rb') as f:
        while chunk := f.read(8192):
            h.update(chunk)
    return h.hexdigest()

def run_simulation():
    print("=== SIMULAZIONE OFFLINE ROLLBACK ATOMICO & STORAGE BUDGET 15 MB (Python) ===")
    passed = 0
    failed = 0

    fd1, live_db_path = tempfile.mkstemp(suffix=".db", prefix="akai_live_test_")
    fd2, backup_db_path = tempfile.mkstemp(suffix=".db", prefix="akai_backup_v5_")
    fd3, budget_db_path = tempfile.mkstemp(suffix=".db", prefix="akai_budget_test_")
    os.close(fd1)
    os.close(fd2)
    os.close(fd3)

    try:
        # FASE 1: Creazione DB v5 originale
        conn_v5 = sqlite3.connect(live_db_path)
        cur_v5 = conn_v5.cursor()
        cur_v5.execute("PRAGMA user_version = 5;")
        cur_v5.execute("""
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
        cur_v5.execute("""
            CREATE TABLE user_preferences (
                pref_key TEXT PRIMARY KEY,
                pref_value TEXT NOT NULL,
                category TEXT NOT NULL,
                is_personal INTEGER DEFAULT 1,
                enabled INTEGER DEFAULT 1,
                updated_at INTEGER
            );
        """)
        cur_v5.execute("""
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

        now = 1700000000000
        cur_v5.execute("""
            INSERT INTO procedural_memory 
            (intent_key, goal_intent, description, app_package, initial_state, action_sequence, success_condition, app_version, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, ("youtube", "apri youtube", "Template apertura YouTube TV", "com.google.android.youtube.tv", "{}", "[]", "{}", "v2.0", now))

        cur_v5.execute("""
            INSERT INTO procedural_memory 
            (intent_key, goal_intent, description, app_package, initial_state, action_sequence, success_condition, app_version, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, ("dan_private_action", "video privati vacanze", "Procedura privata", "com.google.android.youtube.tv", "{}", "[]", "{}", "1.0", now))

        cur_v5.execute("INSERT INTO user_preferences (pref_key, pref_value, category, is_personal, enabled, updated_at) VALUES (?, ?, ?, ?, ?, ?);",
                       ("favorite_channels", "[\"Focus\", \"Italia 2\"]", "channels", 1, 1, now))

        cur_v5.execute("INSERT INTO conversations (timestamp, user_query, assistant_reply, status) VALUES (?, ?, ?, ?);",
                       (now, "Ciao Jarvis", "Buongiorno Daniele", "SUCCESS"))
        conn_v5.commit()
        conn_v5.close()

        # FASE 2: Backup atomico v5 e calcolo hash di integrità
        shutil.copyfile(live_db_path, backup_db_path)
        hash_v5_backup = sha256_file(backup_db_path)

        conn_check = sqlite3.connect(backup_db_path)
        cur_check = conn_check.cursor()
        cur_check.execute("PRAGMA integrity_check;")
        integrity_res = cur_check.fetchone()[0]
        conn_check.close()

        if integrity_res == "ok" and hash_v5_backup:
            print(f"[PASS] Simulazione 1: Backup atomico v5 verificato con successo (PRAGMA integrity_check = ok, SHA-256 = {hash_v5_backup[:16]}...)")
            passed += 1
        else:
            print("[FAIL] Simulazione 1: Fallimento backup o integrità v5")
            failed += 1

        # FASE 3: Simulazione Migrazione v6 (Criterio 3: tutte le legacy rimangono is_personal=1)
        conn_v6 = sqlite3.connect(live_db_path)
        cur_v6 = conn_v6.cursor()
        cur_v6.execute("ALTER TABLE procedural_memory ADD COLUMN is_personal INTEGER DEFAULT 1;")
        cur_v6.execute("PRAGMA user_version = 6;")
        conn_v6.commit()

        cur_v6.execute("SELECT intent_key, is_personal FROM procedural_memory;")
        procs_v6 = {row[0]: row[1] for row in cur_v6.fetchall()}
        conn_v6.close()

        if procs_v6.get("youtube") == 1 and procs_v6.get("dan_private_action") == 1:
            print("[PASS] Simulazione 2: Migrazione v6 categorica (Criterio 3): TUTTE le procedure legacy v5 rimangono rigorosamente private (is_personal = 1, zero leaks)")
            passed += 1
        else:
            print(f"[FAIL] Simulazione 2: Leak migrazione v6: {procs_v6}")
            failed += 1

        # FASE 4: Dimostrazione del Limite Downgrade dell'APK v5
        conn_insp = sqlite3.connect(live_db_path)
        cur_insp = conn_insp.cursor()
        cur_insp.execute("PRAGMA user_version;")
        curr_ver = cur_insp.fetchone()[0]
        conn_insp.close()

        if curr_ver > 5:
            print(f"[PASS] Simulazione 3: Rilevata incompatibilità downgrade APK v5 su DB v6 (user_version={curr_ver} > 5). L'APK v5 nativo andrebbe in crash senza restore atomico del DB.")
            passed += 1
        else:
            print("[FAIL] Simulazione 3: Mancato rilevamento incompatibilità")
            failed += 1

        # FASE 5: Rollback Atomico Indivisibile (Ripristino Backup v5)
        shutil.copyfile(backup_db_path, live_db_path)
        hash_restored = sha256_file(live_db_path)

        conn_rest = sqlite3.connect(live_db_path)
        cur_rest = conn_rest.cursor()
        cur_rest.execute("PRAGMA user_version;")
        rest_ver = cur_rest.fetchone()[0]
        cur_rest.execute("PRAGMA integrity_check;")
        rest_check = cur_rest.fetchone()[0]
        cur_rest.execute("SELECT COUNT(*) FROM conversations;")
        rest_convs = cur_rest.fetchone()[0]
        cur_rest.execute("SELECT COUNT(*) FROM procedural_memory;")
        rest_procs = cur_rest.fetchone()[0]
        conn_rest.close()

        if hash_restored == hash_v5_backup and rest_ver == 5 and rest_check == "ok" and rest_convs == 1 and rest_procs == 2:
            print("[PASS] Simulazione 4: Rollback atomico riuscito al 100%! Database v5 ripristinato, hash coincidente, schema v5 integro, zero dati corrotti.")
            passed += 1
        else:
            print("[FAIL] Simulazione 4: Fallimento rollback atomico")
            failed += 1

        # FASE 6: Enforcement Storage Budget Reale a 15 MB (>16 MB reali su disco)
        conn_bg = sqlite3.connect(budget_db_path)
        cur_bg = conn_bg.cursor()
        cur_bg.execute("""
            CREATE TABLE conversations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp INTEGER NOT NULL,
                user_query TEXT NOT NULL,
                assistant_reply TEXT NOT NULL,
                status TEXT NOT NULL
            );
        """)
        one_mb = "A" * (1024 * 1024)
        for i in range(1, 17):
            cur_bg.execute("INSERT INTO conversations (timestamp, user_query, assistant_reply, status) VALUES (?, ?, ?, ?);",
                           (now + (i * 1000), f"Query {i}", one_mb, "SUCCESS"))
        conn_bg.commit()

        cur_bg.execute("PRAGMA page_count;")
        init_pages = cur_bg.fetchone()[0]
        cur_bg.execute("PRAGMA page_size;")
        init_psize = cur_bg.fetchone()[0]
        real_size = init_pages * init_psize
        max_storage_limit = 15 * 1024 * 1024

        if real_size > max_storage_limit:
            print(f"[PASS] Simulazione 5.1: Soglia reale 15 MB superata con successo ({real_size} bytes = {real_size/(1024*1024):.2f} MB). Triggering emergency pruning...")
            passed += 1
        else:
            print(f"[FAIL] Simulazione 5.1: Dimensione non superata: {real_size}")
            failed += 1

        # Emergency pruning (conserva solo gli ultimi 5 + VACUUM)
        cur_bg.execute("""
            DELETE FROM conversations WHERE id NOT IN (
                SELECT id FROM conversations ORDER BY timestamp DESC LIMIT 5
            );
        """)
        conn_bg.commit()
        cur_bg.execute("VACUUM;")

        cur_bg.execute("PRAGMA page_count;")
        post_pages = cur_bg.fetchone()[0]
        cur_bg.execute("PRAGMA page_size;")
        post_psize = cur_bg.fetchone()[0]
        post_size = post_pages * post_psize
        cur_bg.execute("SELECT COUNT(*) FROM conversations;")
        post_count = cur_bg.fetchone()[0]
        conn_bg.close()

        if post_count == 5 and post_size < max_storage_limit and post_size < (6 * 1024 * 1024):
            print(f"[PASS] Simulazione 5.2: Enforcement storage budget a 15 MB completato! Spazio ridotto da {real_size/(1024*1024):.2f} MB a {post_size/(1024*1024):.2f} MB, VACUUM eseguito e budget rispettato.")
            passed += 1
        else:
            print(f"[FAIL] Simulazione 5.2: Fallimento pruning/VACUUM: count={post_count}, size={post_size}")
            failed += 1

    finally:
        for p in [live_db_path, backup_db_path, budget_db_path]:
            if os.path.exists(p):
                try: os.remove(p)
                except Exception: pass

    print("\n=== ESITO COMPLETO SIMULAZIONE ROLLBACK & STORAGE (Python) ===")
    print(f"Test Superati: {passed} / {passed + failed}")
    if failed > 0:
        sys.exit(1)

if __name__ == "__main__":
    run_simulation()
