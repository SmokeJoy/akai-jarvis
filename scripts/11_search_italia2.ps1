$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Output "=== FOCUSING SEARCH BAR AND TYPING ITALIA 2 ==="
# Press DPAD_UP to select "Cerca"
& $adb -s 192.168.1.8:5555 shell "input keyevent 19"
Start-Sleep -Milliseconds 400
# Press DPAD_CENTER to activate input
& $adb -s 192.168.1.8:5555 shell "input keyevent 23"
Start-Sleep -Milliseconds 600
# Type italia 2
& $adb -s 192.168.1.8:5555 shell "input text 'italia%s2'"
Start-Sleep -Milliseconds 500
& $adb -s 192.168.1.8:5555 shell "input keyevent 66"
Start-Sleep -Seconds 2

& $adb -s 192.168.1.8:5555 shell "screencap -p /sdcard/screen_search_italia2.png"
& $adb -s 192.168.1.8:5555 pull /sdcard/screen_search_italia2.png "C:\Users\danie\.gemini\antigravity\brain\301a5daf-4835-45b9-b7d1-86d5907a0c37\screen_search_italia2.png"
