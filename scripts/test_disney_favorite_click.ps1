$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Host "1. Pressing HOME to ensure Custom Home is active..."
& $adb -s 192.168.1.8:5555 shell input keyevent 3 # HOME
Start-Sleep -Seconds 1

Write-Host "2. Navigating to Disney+ card in App Preferite (Card #5)..."
# In App Preferite, tile 5 is at X ~ 1250, Y ~ 310.
& $adb -s 192.168.1.8:5555 shell input tap 1250 310
Start-Sleep -Seconds 4

Write-Host "3. Verifying top activity..."
$focus = & $adb -s 192.168.1.8:5555 shell "dumpsys window windows | grep -E 'mCurrentFocus|mFocusedApp'"
Write-Host "Focus: $focus"
