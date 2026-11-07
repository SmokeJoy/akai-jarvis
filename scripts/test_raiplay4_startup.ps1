$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Host "1. Clearing logcat..."
& $adb -s 192.168.1.8:5555 logcat -c

Write-Host "2. Starting RaiPlay 4.2.11 (MainLeanbackActivity)..."
$startRes = & $adb -s 192.168.1.8:5555 shell "am start -n it.rainet.androidtv/.ui.MainLeanbackActivity"
Write-Host "Start output: $startRes"

Write-Host "3. Waiting 6 seconds for app startup..."
Start-Sleep -Seconds 6

Write-Host "4. Capturing top activity and window focus..."
$focus = & $adb -s 192.168.1.8:5555 shell "dumpsys window windows | grep -E 'mCurrentFocus|mFocusedApp'"
Write-Host "Focus: $focus"

Write-Host "5. Capturing screenshot..."
& $adb -s 192.168.1.8:5555 shell screencap -p /sdcard/screen_raiplay4_start.png
& $adb -s 192.168.1.8:5555 pull /sdcard/screen_raiplay4_start.png scratch/screen_raiplay4_start.png

Write-Host "6. Checking meminfo for it.rainet.androidtv..."
$mem = & $adb -s 192.168.1.8:5555 shell "dumpsys meminfo it.rainet.androidtv | grep -E 'TOTAL PSS:|Native Heap|Dalvik Heap'"
Write-Host "Meminfo: $mem"

Write-Host "7. Dumping initial logcat for RaiPlay..."
& $adb -s 192.168.1.8:5555 logcat -d -t 150 > scratch/raiplay4_startup.log
Write-Host "Log saved to scratch/raiplay4_startup.log"
