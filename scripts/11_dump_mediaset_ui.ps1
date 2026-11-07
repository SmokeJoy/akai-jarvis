$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Output "=== DUMPING UI HIERARCHY ==="
& $adb -s 192.168.1.8:5555 shell "uiautomator dump /sdcard/ui_mediaset_live.xml"
& $adb -s 192.168.1.8:5555 pull /sdcard/ui_mediaset_live.xml "C:\Users\danie\.gemini\antigravity\brain\301a5daf-4835-45b9-b7d1-86d5907a0c37\ui_mediaset_live.xml"

Write-Output "`n=== RECENT LOGCAT FROM MEDIASET ==="
& $adb -s 192.168.1.8:5555 logcat -d -t 100 | Select-String -Pattern "chromium|mediaset|WebGL|Error" | Select-Object -First 30
