$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null
Start-Sleep -Milliseconds 300

Write-Output "=== CLEARING LOGCAT & CLICKING RIPRODUCI ==="
& $adb -s 192.168.1.8:5555 logcat -c
& $adb -s 192.168.1.8:5555 shell "input keyevent 23"

Start-Sleep -Seconds 5

Write-Output "=== DUMPING RAW LOGCAT FROM REPRODUCTION ATTEMPT ==="
& $adb -s 192.168.1.8:5555 logcat -d > "C:\Users\danie\.gemini\antigravity\brain\301a5daf-4835-45b9-b7d1-86d5907a0c37\raiplay_playback_raw.log"

Write-Output "=== CAPTURING SCREENSHOT ==="
& $adb -s 192.168.1.8:5555 shell "screencap -p /sdcard/screen_raiplay_test1.png"
& $adb -s 192.168.1.8:5555 pull /sdcard/screen_raiplay_test1.png "C:\Users\danie\.gemini\antigravity\brain\301a5daf-4835-45b9-b7d1-86d5907a0c37\screen_raiplay_test1.png"
