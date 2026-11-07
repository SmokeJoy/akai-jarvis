$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Host "1. Navigating from Mediaset Infinity to RaiPlay in App Preferite..."
& $adb -s 192.168.1.8:5555 shell input keyevent 19 # UP
Start-Sleep -Milliseconds 300
& $adb -s 192.168.1.8:5555 shell input keyevent 19 # UP
Start-Sleep -Milliseconds 300
& $adb -s 192.168.1.8:5555 shell input keyevent 19 # UP (focus on YouTube in App Preferite)
Start-Sleep -Milliseconds 300
& $adb -s 192.168.1.8:5555 shell input keyevent 22 # RIGHT (Live TV)
Start-Sleep -Milliseconds 300
& $adb -s 192.168.1.8:5555 shell input keyevent 22 # RIGHT (Play Store)
Start-Sleep -Milliseconds 300
& $adb -s 192.168.1.8:5555 shell input keyevent 22 # RIGHT (RaiPlay)
Start-Sleep -Milliseconds 300

Write-Host "2. Verifying RaiPlay card selection..."
& $adb -s 192.168.1.8:5555 shell screencap -p /sdcard/screen_home_raiplay_focused.png
& $adb -s 192.168.1.8:5555 pull /sdcard/screen_home_raiplay_focused.png scratch/screen_home_raiplay_focused.png

Write-Host "3. Pressing ENTER to launch RaiPlay from Custom Home v7..."
& $adb -s 192.168.1.8:5555 shell input keyevent 23 # ENTER
Start-Sleep -Seconds 4

Write-Host "4. Checking resulting window focus..."
$focus = & $adb -s 192.168.1.8:5555 shell "dumpsys window windows | grep -E 'mCurrentFocus|mFocusedApp'"
Write-Host "Focus: $focus"
