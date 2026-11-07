$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Output "=== RETURNING TO HOME IN MEDIASET ==="
# Press Back to close menu, or Left -> Up to Home
& $adb -s 192.168.1.8:5555 shell "input keyevent 4"
Start-Sleep -Milliseconds 500
& $adb -s 192.168.1.8:5555 shell "input keyevent 21"
Start-Sleep -Milliseconds 300
& $adb -s 192.168.1.8:5555 shell "input keyevent 19"
Start-Sleep -Milliseconds 300
& $adb -s 192.168.1.8:5555 shell "input keyevent 19"
Start-Sleep -Milliseconds 300
& $adb -s 192.168.1.8:5555 shell "input keyevent 19"
Start-Sleep -Milliseconds 300
& $adb -s 192.168.1.8:5555 shell "input keyevent 23"
Start-Sleep -Seconds 2

Write-Output "=== SCROLLING DOWN TO CHANNELS ==="
& $adb -s 192.168.1.8:5555 shell "input keyevent 20"
Start-Sleep -Milliseconds 300
& $adb -s 192.168.1.8:5555 shell "input keyevent 20"
Start-Sleep -Milliseconds 500

& $adb -s 192.168.1.8:5555 shell "screencap -p /sdcard/screen_mediaset_home_down.png"
& $adb -s 192.168.1.8:5555 pull /sdcard/screen_mediaset_home_down.png "C:\Users\danie\.gemini\antigravity\brain\301a5daf-4835-45b9-b7d1-86d5907a0c37\screen_mediaset_home_down.png"
