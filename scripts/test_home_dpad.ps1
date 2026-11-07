$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Host "1. Pressing HOME to return to Custom Home v7..."
& $adb -s 192.168.1.8:5555 shell input keyevent 3 # HOME
Start-Sleep -Seconds 2

Write-Host "2. Clicking directly on RaiPlay via coordinate tap or D-pad..."
# In Custom Home v7, the RaiPlay card in App Preferite is at:
# Row "APP PREFERITE", 4th tile (YouTube, Live TV, Play Store, RaiPlay)
# Screen resolution is 1920x1080.
# App Preferite tiles are roughly at Y ~ 310.
# Let's verify coordinate or navigate precisely.
# Let's first take a screenshot of Custom Home to see where default focus is.
& $adb -s 192.168.1.8:5555 shell screencap -p /sdcard/screen_home_focus_test.png
& $adb -s 192.168.1.8:5555 pull /sdcard/screen_home_focus_test.png scratch/screen_home_focus_test.png
