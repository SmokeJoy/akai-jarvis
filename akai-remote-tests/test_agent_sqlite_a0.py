#!/usr/bin/env python3
"""A0 host SQLite contract tests. Runs a real SQLite engine, NOT Android Cursor instrumentation."""
import sqlite3
import tempfile
from pathlib import Path
import hashlib


def replay_allowed(successes: int, failures: int) -> bool:
    return failures < 3 or failures <= 2 * max(1, successes)


def lookup(conn, goal, guest=False):
    """Mirrors the three-stage query and quarantine ordering in AkaiMemoryEngine."""
    clean = " ".join(goal.lower().split())
    restrict = " AND is_personal=0" if guest else ""
    for col in ("intent_key", "goal_intent"):
        with conn:
            cursor = conn.execute(
                f"SELECT * FROM procedural_memory WHERE {col}=?{restrict}", (clean,))
            row = cursor.fetchone()
            cursor.close()
            if row is not None and replay_allowed(row["success_count"], row["failure_count"]):
                return row["intent_key"]
    cursor = conn.execute(
        "SELECT * FROM procedural_memory " + ("WHERE is_personal=0 " if guest else "")
        + "ORDER BY success_count DESC")
    try:
        for row in cursor:
            key = row["intent_key"].replace("_", " ")
            described = row["goal_intent"]
            if (key in clean or (described and described in clean)) and replay_allowed(
                    row["success_count"], row["failure_count"]):
                return row["intent_key"]
    finally:
        cursor.close()
    return None


def run():
    with tempfile.TemporaryDirectory() as directory:
        file = Path(directory, "akai_agent_test.db")
        db = sqlite3.connect(str(file))
        db.row_factory = sqlite3.Row
        db.executescript("""
            CREATE TABLE procedural_memory(
                intent_key TEXT PRIMARY KEY, goal_intent TEXT,
                success_count INTEGER, failure_count INTEGER,
                is_personal INTEGER DEFAULT 1
            );
            CREATE TABLE user_preferences(
                pref_key TEXT PRIMARY KEY, pref_value TEXT NOT NULL,
                category TEXT, is_personal INTEGER, enabled INTEGER
            );
        """)
        db.executemany(
            "INSERT INTO procedural_memory VALUES (?, ?, ?, ?, ?)",
            [
                ("broken_skill", "apri musica", 0, 4, 1),
                ("valid_music", "apri musica", 8, 0, 1),
                ("public_tv", "apri tv", 0, 0, 0),
            ],
        )
        for _ in range(60):
            assert lookup(db, "broken_skill") is None
            assert lookup(db, "apri musica") == "valid_music"
            assert lookup(db, "apri tv", guest=True) == "public_tv"
            assert lookup(db, "apri musica", guest=True) is None
        print("[PASS] real SQLite: quarantined exact/goal lookups + fallback + guest, repeated 60x")

        fact = "Preferisco la voce italiana"
        key = "agent_fact_" + hashlib.sha256(fact.lower().encode()).hexdigest()[:24]
        db.execute("INSERT INTO user_preferences VALUES (?, ?, ?, ?, ?)",
                   (key, fact, "agent_fact", 1, 1))
        db.commit()
        db.close()

        db = sqlite3.connect(str(file))
        row = db.execute(
            "SELECT pref_value FROM user_preferences WHERE pref_key=? AND is_personal=1", (key,)
        ).fetchone()
        assert row and row[0] == fact
        print("[PASS] real SQLite: explicit personal fact survives close/reopen")

        db.execute("DELETE FROM user_preferences WHERE pref_key=?", (key,))
        db.commit()
        assert db.execute("SELECT COUNT(*) FROM user_preferences WHERE pref_key=?", (key,)
                          ).fetchone()[0] == 0
        assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
        db.close()
        print("[PASS] real SQLite: selective fact forget and integrity")


if __name__ == "__main__":
    run()
