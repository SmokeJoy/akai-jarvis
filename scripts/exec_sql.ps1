$adb = "C:\Users\danie\AppData\Local\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb -s 192.168.1.8:5555 shell "echo `"SELECT action_sequence FROM procedural_memory WHERE intent_key='italia2';`" | sqlite3 /data/user/0/it.akai.customremote/databases/akai_memory.db"
