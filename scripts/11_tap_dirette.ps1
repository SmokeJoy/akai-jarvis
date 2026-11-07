$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Output "=== TAPPING DIRECTLY ON DIRETTE ICON (X=40, Y=536) ==="
& $adb -s 192.168.1.8:5555 shell "input tap 40 536"
Start-Sleep -Seconds 3

Write-Output "=== CAPTURING SCREENSHOT ==="
& $adb -s 192.168.1.8:5555 shell "screencap -p /sdcard/screen_dirette_tap.png"
& $adb -s 192.168.1.8:5555 pull /sdcard/screen_dirette_tap.png "C:\Users\danie\.gemini\antigravity\brain\301a5daf-4835-45b9-b7d1-86d5907a0c37\screen_dirette_tap.png"
