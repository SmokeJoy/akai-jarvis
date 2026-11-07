$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Output "=== SELECTING 5TH ICON (DIRETTE) ==="
& $adb -s 192.168.1.8:5555 shell "input keyevent 21"
Start-Sleep -Milliseconds 400
& $adb -s 192.168.1.8:5555 shell "input keyevent 20"
Start-Sleep -Milliseconds 400
& $adb -s 192.168.1.8:5555 shell "input keyevent 23"
Start-Sleep -Seconds 3

& $adb -s 192.168.1.8:5555 shell "screencap -p /sdcard/screen_tv_icon.png"
& $adb -s 192.168.1.8:5555 pull /sdcard/screen_tv_icon.png "C:\Users\danie\.gemini\antigravity\brain\301a5daf-4835-45b9-b7d1-86d5907a0c37\screen_tv_icon.png"
