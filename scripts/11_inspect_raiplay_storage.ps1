$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Output "=== 1. STRINGS IN 000013.LOG (LEVELDB WRITE AHEAD LOG) ==="
& $adb -s 192.168.1.8:5555 shell "su 0 strings '/data/data/it.rainet.androidtv/app_webview/Local Storage/leveldb/000013.log' | grep -E 'http|json|error|Error|fail|stream|video|m3u8|mpd|dash' | head -n 40"

Write-Output "`n=== 2. STRINGS IN VIDEODECODESTATS ==="
& $adb -s 192.168.1.8:5555 shell "su 0 strings /data/data/it.rainet.androidtv/app_webview/VideoDecodeStats/000003.log"
