$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Output "=== CLEARING LOGCAT & CLICKING RAI 1 LIVE ==="
& $adb -s 192.168.1.8:5555 logcat -c
# Right to RAI 1 card
& $adb -s 192.168.1.8:5555 shell "input keyevent 22"
Start-Sleep -Milliseconds 400
# Center to start live stream
& $adb -s 192.168.1.8:5555 shell "input keyevent 23"
Start-Sleep -Seconds 5

Write-Output "=== DUMPING LOGCAT FROM LIVE PLAYBACK ==="
& $adb -s 192.168.1.8:5555 logcat -d > "C:\Users\danie\.gemini\antigravity\brain\301a5daf-4835-45b9-b7d1-86d5907a0c37\rai1_live_raw.log"

Write-Output "=== CAPTURING SCREENSHOT ==="
& $adb -s 192.168.1.8:5555 shell "screencap -p /sdcard/screen_rai1_test.png"
& $adb -s 192.168.1.8:5555 pull /sdcard/screen_rai1_test.png "C:\Users\danie\.gemini\antigravity\brain\301a5daf-4835-45b9-b7d1-86d5907a0c37\screen_rai1_test.png"
