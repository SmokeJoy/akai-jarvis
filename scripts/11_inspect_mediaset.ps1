$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null
Start-Sleep -Milliseconds 300

Write-Output "=== MEDIASET INFINITY PACKAGE INFO ==="
& $adb -s 192.168.1.8:5555 shell "dumpsys package it.mediaset.infinitytv | grep -E 'versionName|versionCode|firstInstallTime|lastUpdateTime|dataDir' | head -n 10"

Write-Output "`n=== MEDIASET ACTIVITIES ==="
& $adb -s 192.168.1.8:5555 shell "cmd package resolve-activity --brief it.mediaset.infinitytv"

Write-Output "`n=== APP DATA USAGE / DIRECTORY ==="
& $adb -s 192.168.1.8:5555 shell "su 0 du -sh /data/data/it.mediaset.infinitytv/ 2>/dev/null"
& $adb -s 192.168.1.8:5555 shell "su 0 ls -la /data/data/it.mediaset.infinitytv/ 2>/dev/null"
