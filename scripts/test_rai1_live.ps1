$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Host "1. Pressing BACK to exit current on-demand video..."
& $adb -s 192.168.1.8:5555 shell input keyevent 4 # KEYCODE_BACK
Start-Sleep -Seconds 2

Write-Host "2. Navigating to In Diretta -> Rai 1..."
# From hero, pressing DPAD_DOWN goes to "Da Non Perdere", another DPAD_DOWN goes to "In Diretta"
& $adb -s 192.168.1.8:5555 shell input keyevent 20 # DPAD_DOWN (Da Non Perdere)
Start-Sleep -Milliseconds 600
& $adb -s 192.168.1.8:5555 shell input keyevent 20 # DPAD_DOWN (In Diretta)
Start-Sleep -Milliseconds 600

Write-Host "3. Taking screenshot of In Diretta row selection..."
& $adb -s 192.168.1.8:5555 shell screencap -p /sdcard/screen_rai1_selection.png
& $adb -s 192.168.1.8:5555 pull /sdcard/screen_rai1_selection.png scratch/screen_rai1_selection.png

Write-Host "4. Pressing ENTER to start Rai 1 Live streaming..."
& $adb -s 192.168.1.8:5555 shell input keyevent 23 # DPAD_CENTER / ENTER
Start-Sleep -Seconds 6

Write-Host "5. Taking screenshot of Rai 1 Live playback..."
& $adb -s 192.168.1.8:5555 shell screencap -p /sdcard/screen_rai1_live_v4.png
& $adb -s 192.168.1.8:5555 pull /sdcard/screen_rai1_live_v4.png scratch/screen_rai1_live_v4.png
Copy-Item scratch/screen_rai1_live_v4.png "C:\Users\danie\.gemini\antigravity\brain\301a5daf-4835-45b9-b7d1-86d5907a0c37\screen_rai1_live_v4.png"
