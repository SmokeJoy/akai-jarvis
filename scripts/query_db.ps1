$sql = "SELECT intent_key, action_sequence, success_condition FROM procedural_memory WHERE intent_key='italia2';"
powershell -ExecutionPolicy Bypass -File .\scripts\tv.ps1 shell "sqlite3 /data/user/0/it.akai.customremote/databases/akai_memory.db `"$sql`""
