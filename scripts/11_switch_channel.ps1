$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Output "=== PRESSING BACK IN MEDIASET INFINITY ==="
& $adb -s 192.168.1.8:5555 shell "input keyevent 4"
Start-Sleep -Seconds 2

& $adb -s 192.168.1.8:5555 shell "screencap -p /sdcard/screen_mediaset_back.png"
& $adb -s 192.168.1.8:5555 pull /sdcard/screen_mediaset_back.png "C:\Users\danie\.gemini\antigravity\brain\301a5daf-4835-45b9-b7d1-86d5907a0c37\screen_mediaset_back.png"
